#!/usr/bin/env python3
"""Analyse a Laravel repo for ./dock new-app (called by scripts/scan-app.sh)."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PHP_VERSIONS = ["8.1", "8.2", "8.3", "8.4", "8.5"]

# Extensions compiled into the official php:*-bookworm images.
BUILTIN_EXTS = {
    "core", "ctype", "curl", "date", "dom", "fileinfo", "filter", "hash", "iconv", "json",
    "libxml", "mbstring", "mysqlnd", "openssl", "pcre", "pdo", "pdo_sqlite", "phar", "posix",
    "random", "readline", "reflection", "session", "simplexml", "sodium", "spl", "sqlite3",
    "standard", "tokenizer", "xml", "xmlreader", "xmlwriter", "zlib",
}

# Packages that need more than composer can install. ns = namespaces used to detect real usage.
KNOWN = {
    "spatie/pdf-to-image": dict(ext=["imagick"], apt=["ghostscript"], ns=["Spatie\\PdfToImage"],
                                note="PDF -> image (imagick + Ghostscript; PDF policy is relaxed automatically)"),
    "spatie/pdf-to-text": dict(apt=["poppler-utils"], ns=["Spatie\\PdfToText"], note="needs pdftotext"),
    "spatie/browsershot": dict(apt=["chromium", "nodejs", "npm"], ns=["Spatie\\Browsershot"],
                               note="headless Chrome + puppeteer (heavy: ~400 MB)"),
    "spatie/laravel-pdf": dict(apt=["chromium", "nodejs", "npm"], ns=["Spatie\\LaravelPdf"],
                               note="Browsershot driver needs headless Chrome (heavy)"),
    "spatie/image-optimizer": dict(apt=["jpegoptim", "optipng", "pngquant", "gifsicle", "webp"],
                                   ns=["Spatie\\ImageOptimizer"], note="image optimizer binaries"),
    "spatie/laravel-image-optimizer": dict(apt=["jpegoptim", "optipng", "pngquant", "gifsicle", "webp"],
                                           ns=["Spatie\\LaravelImageOptimizer", "ImageOptimizer"],
                                           note="image optimizer binaries"),
    "barryvdh/laravel-snappy": dict(wkhtml=True, ns=["Barryvdh\\Snappy", "SnappyPdf", "PDF::"],
                                    note="wkhtmltopdf (runtime libs are in the php-fpm image)"),
    "knplabs/knp-snappy": dict(wkhtml=True, ns=["Knp\\Snappy"], note="wkhtmltopdf"),
    "h4cc/wkhtmltopdf-amd64": dict(wkhtml=True, ns=[], note="wkhtmltopdf binary"),
    "h4cc/wkhtmltoimage-amd64": dict(wkhtml=True, ns=[], note="wkhtmltoimage binary"),
    "thiagoalessio/tesseract_ocr": dict(apt=["tesseract-ocr", "tesseract-ocr-eng"],
                                        ns=["thiagoalessio\\TesseractOCR"], note="OCR"),
    "php-ffmpeg/php-ffmpeg": dict(apt=["ffmpeg"], ns=["FFMpeg\\"], note="video/audio processing (heavy)"),
    "pbmo/laravel-ffmpeg": dict(apt=["ffmpeg"], ns=["ProtoneMedia\\LaravelFFMpeg"], note="video/audio (heavy)"),
    "mongodb/laravel-mongodb": dict(ext=["mongodb"], ns=["MongoDB\\"], note="stack has no MongoDB service"),
    "jenssegers/mongodb": dict(ext=["mongodb"], ns=["Jenssegers\\Mongodb"], note="stack has no MongoDB service"),
}

WKHTML_APT = ["libxrender1", "libxext6", "libx11-6", "libfontconfig1", "libfreetype6",
              "libjpeg62-turbo", "libpng16-16", "fontconfig", "fonts-dejavu-core", "xfonts-75dpi", "xfonts-base"]

CODE_DIRS = ["app", "routes", "config", "resources", "database", "bootstrap", "src", "Modules", "packages"]


def out(s=""):
    print(s)


def head(s):
    out()
    out(s)
    out("-" * len(s))


# ---- composer constraint evaluation (enough for php "^8.2", ">=8.1 <8.4", "~8.2.0", "^7.3|^8.0") ----

def vtuple(v):
    parts = [int(x) for x in re.findall(r"\d+", v)[:3]]
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)


def single_ok(c, v):
    c = c.strip().lstrip("v")
    if not c or c == "*":
        return True
    m = re.match(r"^(\^|~|>=|<=|>|<|!=|==|=)?\s*([0-9][0-9.*x]*)", c)
    if not m:
        return True
    op, ver = m.group(1) or "", m.group(2)
    if "*" in ver or ver.endswith(".x"):
        base = ver.replace(".*", "").replace(".x", "").replace("*", "")
        bt = [int(x) for x in base.split(".") if x != ""]
        return list(v[: len(bt)]) == bt
    t = vtuple(ver)
    n = len(re.findall(r"\d+", ver))
    if op == "^":
        upper = (t[0] + 1, 0, 0) if t[0] > 0 else (0, t[1] + 1, 0)
        return t <= v < upper
    if op == "~":
        upper = (t[0] + 1, 0, 0) if n <= 2 else (t[0], t[1] + 1, 0)
        return t <= v < upper
    if op == ">=":
        return v >= t
    if op == ">":
        return v > t
    if op == "<=":
        return v <= t if n >= 3 else v[:2] <= t[:2]
    if op == "<":
        return v < t
    if op == "!=":
        return v != t
    return v[:n] == t[:n]


def constraint_ok(constraint, version):
    v = vtuple(version + ".50")
    for alt in re.split(r"\|\|?", constraint):
        alt = re.sub(r"\s*-\s*", " - ", alt.strip())
        rng = re.match(r"^(\S+) - (\S+)$", alt)
        if rng:
            if vtuple(rng.group(1)) <= v <= vtuple(rng.group(2) + ".99"):
                return True
            continue
        parts = [p for p in re.split(r"[,\s]+", alt) if p]
        merged, i = [], 0
        while i < len(parts):
            if parts[i] in (">=", "<=", ">", "<", "^", "~", "=", "!=") and i + 1 < len(parts):
                merged.append(parts[i] + parts[i + 1]); i += 2
            else:
                merged.append(parts[i]); i += 1
        if all(single_ok(p, v) for p in merged):
            return True
    return False


# ---- repo reading ----

def load_json(p):
    try:
        return json.loads(Path(p).read_text())
    except Exception:
        return None


def read_env_example(src):
    env = {}
    for name in (".env.example", ".env.production.example", ".env.dist"):
        p = src / name
        if p.exists():
            for line in p.read_text(errors="ignore").splitlines():
                m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
                if m:
                    env.setdefault(m.group(1), m.group(2).strip().strip('"'))
    return env


def code_files(src):
    for d in CODE_DIRS:
        base = src / d
        if not base.is_dir():
            continue
        for root, dirs, files in os.walk(base):
            dirs[:] = [x for x in dirs if x not in ("vendor", "node_modules", ".git", "storage")]
            for f in files:
                if f.endswith(".php"):
                    yield Path(root) / f


def grep_code(src, needles):
    found = {n: False for n in needles}
    if not needles:
        return found
    for f in code_files(src):
        try:
            text = f.read_text(errors="ignore")
        except Exception:
            continue
        for n in needles:
            if not found[n] and n in text:
                found[n] = True
        if all(found.values()):
            break
    return found


def strip_comments(php):
    php = re.sub(r"/\*.*?\*/", "", php, flags=re.S)
    return "\n".join(l for l in php.splitlines() if not l.strip().startswith(("//", "#")))


# ---- docker helpers ----

def docker_ok():
    return shutil.which("docker") is not None and subprocess.run(
        ["docker", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def image_exists(img):
    return subprocess.run(["docker", "image", "inspect", img],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def image_exts(img):
    r = subprocess.run(["docker", "run", "--rm", "--entrypoint", "php", img, "-m"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return {l.strip().lower() for l in r.stdout.splitlines() if l.strip() and not l.startswith("[")}


def composer_missing(img, src, has_lock):
    """Ask composer inside the image which ext-* requirements fail. Returns (set, note)."""
    work = Path(tempfile.mkdtemp())
    try:
        shutil.copy(src / "composer.json", work / "composer.json")
        if has_lock:
            shutil.copy(src / "composer.lock", work / "composer.lock")
            cmd = "composer check-platform-reqs --lock --no-dev --format=json"
        else:
            cmd = ("composer update --dry-run --no-dev --no-scripts --no-plugins --no-interaction "
                   "--no-progress --no-audit 2>&1")
        os.chmod(work, 0o777)
        r = subprocess.run(
            ["docker", "run", "--rm", "-e", "COMPOSER_HOME=/tmp/composer", "-v", f"{work}:/scan",
             "-w", "/scan", "--entrypoint", "sh", img, "-c", cmd],
            capture_output=True, text=True, timeout=600)
        text = r.stdout + r.stderr
        missing = set()
        if has_lock:
            try:
                for row in json.loads(r.stdout):
                    name = row.get("name", "")
                    if name.startswith("ext-") and row.get("status") in ("missing", "failed"):
                        missing.add(name[4:].lower())
                return missing, None
            except Exception:
                pass
            for m in re.finditer(r"^(ext-[\w-]+)\s+.*\b(missing|failed)\s*$", text, flags=re.M):
                missing.add(m.group(1)[4:].lower())
            return missing, None
        for m in re.finditer(r"(ext-[\w-]+)\s+\S+\s+->\s+it is missing from your system", text):
            missing.add(m.group(1)[4:].lower())
        php_fail = re.search(r"requires php (\S+) -> your php version \(([\d.]+)\) does not satisfy", text)
        note = None
        if php_fail and not missing:
            note = f"composer: a package requires php {php_fail.group(1)} (image has {php_fail.group(2)})"
        elif r.returncode != 0 and not missing and "Nothing to modify" not in text:
            tail = [l for l in text.strip().splitlines() if l.strip()][-3:]
            note = "composer dry-run failed: " + " | ".join(tail)[:300]
        return missing, note
    except subprocess.TimeoutExpired:
        return set(), "composer check timed out"
    finally:
        shutil.rmtree(work, ignore_errors=True)


def dockerfile_exts(path):
    try:
        text = Path(path).read_text()
    except Exception:
        return set()
    exts = set()
    for block in re.findall(r"install-php-extensions((?:\s*\\?\n?\s*[a-z0-9_]+)+)", text):
        exts.update(x for x in re.findall(r"[a-z0-9_]+", block))
    return exts


# ---- main ----

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--root", required=True)
    ap.add_argument("--label", default="")
    ap.add_argument("--default-php", default="8.4")
    ap.add_argument("--php")
    ap.add_argument("--php-image", default="multiapp-php")
    ap.add_argument("--octane-image", default="multiapp-php-octane")
    ap.add_argument("--no-docker", action="store_true")
    a = ap.parse_args()

    src = Path(a.src)
    root = Path(a.root)
    cj = load_json(src / "composer.json")
    if not cj:
        out(f"No readable composer.json in {a.label or src} — is this a Laravel/PHP project?")
        return 1
    lock = load_json(src / "composer.lock")
    has_lock = lock is not None
    env = read_env_example(src)

    require = cj.get("require", {}) or {}
    lock_pkgs = {p["name"]: p for p in (lock or {}).get("packages", [])} if has_lock else {}
    all_pkgs = set(require) | set(lock_pkgs)

    out(f"Scan: {a.label or src}")
    out(f"composer.lock: {'yes' if has_lock else 'NO (versions resolve fresh on install; transitive needs checked via composer dry-run)'}")

    # Laravel / PHP
    head("Laravel & PHP")
    fw = lock_pkgs.get("laravel/framework", {}).get("version") or require.get("laravel/framework", "")
    fw_major = None
    m = re.search(r"(\d+)", str(fw))
    if m:
        fw_major = int(m.group(1))
    out(f"  laravel/framework : {fw or 'not found'}")

    php_constraints = []
    if require.get("php"):
        php_constraints.append(("composer.json", require["php"]))
    for name, p in lock_pkgs.items():
        c = (p.get("require") or {}).get("php")
        if c:
            php_constraints.append((name, c))
    allowed = [v for v in PHP_VERSIONS if all(constraint_ok(c, v) for _, c in php_constraints)]
    out(f"  php constraint    : {require.get('php', '<none>')}" + (f" (+{len(php_constraints) - 1} locked packages)" if has_lock and len(php_constraints) > 1 else ""))
    out(f"  usable PHP        : {', '.join(allowed) if allowed else 'NONE of ' + ', '.join(PHP_VERSIONS)}")
    if not allowed:
        blockers = [f"{n} ({c})" for n, c in php_constraints if not any(constraint_ok(c, v) for v in PHP_VERSIONS)]
        if blockers:
            out(f"  blocking          : {', '.join(blockers[:5])}")
    if a.php:
        php = a.php
    elif a.default_php in allowed:
        php = a.default_php
    elif allowed:
        php = allowed[-1]
    else:
        php = a.default_php
    out(f"  suggested --php   : {php}" + ("" if php in allowed or not allowed else "  (WARNING: outside the constraint)"))

    # Runtime / layout / services
    head("Runtime, layout & services")
    octane = "laravel/octane" in all_pkgs
    reverb = "laravel/reverb" in all_pkgs
    horizon = "laravel/horizon" in all_pkgs
    scout = "laravel/scout" in all_pkgs
    meili = "meilisearch/meilisearch-php" in all_pkgs
    out(f"  runtime           : {'octane (laravel/octane installed) -> --octane' if octane else 'fpm'}")

    frontend = next((d for d in ("frontend", "client", "spa") if (src / d / "package.json").exists()), None)
    web_prefixes = []
    web = src / "routes" / "web.php"
    if web.exists():
        verbs = r"(?:get|post|put|patch|delete|options|any|view|redirect|resource|apiResource|prefix)"
        for m in re.finditer(r"(?:Route::|->)" + verbs + r"\(\s*['\"]/?([^'\"/{]*)",
                             strip_comments(web.read_text(errors="ignore"))):
            seg = m.group(1).strip()
            if seg and seg not in web_prefixes:
                web_prefixes.append(seg)
    api_prefix = "api"
    bapp = src / "bootstrap" / "app.php"
    if bapp.exists():
        mm = re.search(r"apiPrefix:\s*['\"]([^'\"]*)['\"]", bapp.read_text(errors="ignore"))
        if mm:
            api_prefix = mm.group(1)
    if frontend:
        out(f"  layout            : spa ({frontend}/ has package.json) -> --spa")
    else:
        out("  layout            : standard (no frontend/ in repo; use --spa if a SPA will be deployed to apps/<app>/frontend/dist)")
    out(f"  api prefix        : /{api_prefix}")
    if web_prefixes:
        out(f"  web routes        : /{', /'.join(web_prefixes[:8])}" + (" …" if len(web_prefixes) > 8 else ""))
        extra = [p for p in web_prefixes if p not in ("", api_prefix, "sanctum", "up", "broadcasting")]
        if extra:
            out(f"  note              : with --spa, nginx must also send /{', /'.join(extra[:5])} to Laravel")
    if fw_major is not None and fw_major < 11:
        out(f"  note              : Laravel {fw_major} — remove the <app>-reverb service and use CACHE_DRIVER (template targets 11+)")
    out(f"  reverb            : {'yes (keep <app>-reverb)' if reverb else 'no -> remove <app>-reverb service + nginx /app location'}")
    if horizon:
        out("  queue             : laravel/horizon -> set APP_QUEUE_COMMAND=\"php artisan horizon\"")
    queued = grep_code(src, ["ShouldQueue"])["ShouldQueue"]
    out(f"  queue jobs        : {'yes (ShouldQueue found)' if queued else 'none found'}")
    sched = False
    for f in (src / "routes" / "console.php", src / "app" / "Console" / "Kernel.php"):
        if f.exists() and re.search(r"Schedule::|\$schedule->", strip_comments(f.read_text(errors="ignore"))):
            sched = True
    out(f"  scheduled tasks   : {'yes' if sched else 'none found (scheduler container optional)'}")
    if scout:
        drv = env.get("SCOUT_DRIVER", "")
        out(f"  search            : laravel/scout{' + meilisearch' if meili else ''} (SCOUT_DRIVER={drv or '?'})"
            + (" -> add 'search' to COMPOSE_PROFILES" if meili or drv == "meilisearch" else ""))
    db = env.get("DB_CONNECTION", "")
    if db and db != "pgsql":
        out(f"  WARNING           : .env.example DB_CONNECTION={db} — this stack provides PostgreSQL only")

    # Extensions
    head(f"PHP extensions (php {php}, {'octane' if octane else 'fpm'} image)")
    image = f"{a.octane_image if octane else a.php_image}:{php}"
    dfile = root / ("php-octane" if octane else "php-fpm") / "Dockerfile"
    use_docker = not a.no_docker and docker_ok() and image_exists(image)
    if use_docker:
        have = image_exts(image) or (BUILTIN_EXTS | dockerfile_exts(dfile))
        out(f"  image             : {image} (inspected)")
    else:
        have = BUILTIN_EXTS | dockerfile_exts(dfile)
        why = "--no-docker" if a.no_docker else ("docker unavailable" if not docker_ok() else f"{image} not built yet")
        out(f"  image             : from {dfile.relative_to(root)} ({why}; build it for an exact check)")

    need = {}
    for k in require:
        if k.startswith("ext-"):
            need.setdefault(k[4:].lower(), set()).add("composer.json")
    for name, p in lock_pkgs.items():
        for k in (p.get("require") or {}):
            if k.startswith("ext-"):
                need.setdefault(k[4:].lower(), set()).add(name)
    for name, info in KNOWN.items():
        if name in all_pkgs:
            for e in info.get("ext", []):
                need.setdefault(e, set()).add(name)

    missing = {e for e in need if e not in have and e.replace("-", "_") not in have}
    composer_note = None
    if use_docker:
        dyn, composer_note = composer_missing(image, src, has_lock)
        for e in dyn:
            need.setdefault(e, set()).add("composer resolve")
        missing |= {e for e in dyn if e not in have}
    if need:
        core_ok = 0
        for e in sorted(need):
            if e in BUILTIN_EXTS and e not in missing:
                core_ok += 1
                continue
            status = "MISSING" if e in missing else "ok"
            out(f"  {status:<7} ext-{e:<14} <- {', '.join(sorted(need[e]))[:90]}")
        if core_ok:
            out(f"  ok      {core_ok} more (PHP core: ctype, json, mbstring, xml, …)")
    else:
        out("  no ext-* requirements beyond the base image")
    if composer_note:
        out(f"  note              : {composer_note}")

    # System packages / heavy deps
    head("System packages & heavy dependencies")
    apt = []
    found_any = False
    usage = grep_code(src, sorted({n for name, i in KNOWN.items() if name in all_pkgs for n in i.get("ns", [])}))
    for name, info in KNOWN.items():
        if name not in all_pkgs:
            continue
        found_any = True
        direct = name in require
        used = any(usage.get(n) for n in info.get("ns", [])) if info.get("ns") else None
        flags = []
        if info.get("wkhtml"):
            if octane:
                apt += WKHTML_APT
                flags.append("needs wkhtmltopdf libs (NOT in the octane image)")
            else:
                flags.append("libs already in php-fpm image")
        for p in info.get("apt", []):
            apt.append(p)
        if info.get("apt"):
            flags.append("apt: " + " ".join(info["apt"]))
        if info.get("ext"):
            flags.append("ext: " + " ".join(info["ext"]))
        src_label = "direct" if direct else "transitive"
        usage_label = "" if used is None else (" | used in code" if used else " | NOT referenced in app code")
        out(f"  {name} ({src_label}{usage_label})")
        out(f"      {info['note']}; {'; '.join(flags)}")
        if used is False and direct:
            out(f"      -> consider: composer remove {name}  (then skip its extras)")
    if not found_any:
        out("  none detected")

    # Suggestion
    head("Suggested")
    ext_list = sorted(e for e in missing)
    apt_list = list(dict.fromkeys(apt))
    cmd = ["./dock new-app <name> <domain>"]
    if php != a.default_php:
        cmd.append(f"--php {php}")
    if octane:
        cmd.append("--octane")
    if frontend:
        cmd.append("--spa")
    if ext_list:
        cmd.append(f"--php-ext \"{' '.join(ext_list)}\"")
    if apt_list:
        cmd.append(f"--apt \"{' '.join(apt_list)}\"")
    out("  " + " ".join(cmd))
    if ext_list or apt_list:
        out("  (extras build an app-only image tag on top of the shared layers; other apps stay lean)")
    else:
        out("  (shared image is enough — no per-app extras)")
    if not reverb:
        out("  after new-app: remove <app>-reverb from sites/<app>/compose.yml and the reverb upstream + /app location from its nginx conf")
    return 0


if __name__ == "__main__":
    sys.exit(main())
