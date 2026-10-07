#!/bin/sh
# Installs per-app extras on top of the shared image (keep php-fpm/ and php-octane/ copies identical).
#   install-extras "<php extensions>" "<apt packages>"
# Both lists are space-separated and may be empty (then nothing is installed).
set -eu

PHP_EXTS="${1:-}"
APT_PKGS="${2:-}"

if [ -n "$APT_PKGS" ]; then
  apt-get update
  # shellcheck disable=SC2086
  apt-get install -y --no-install-recommends $APT_PKGS
  rm -rf /var/lib/apt/lists/*
fi

if [ -n "$PHP_EXTS" ]; then
  # shellcheck disable=SC2086
  install-php-extensions $PHP_EXTS
  rm -rf /tmp/pear /var/cache/apt /var/lib/apt/lists/*
fi

# Debian's ImageMagick policy blocks PDF/PS; spatie/pdf-to-image and similar need them (Ghostscript does the work).
for f in /etc/ImageMagick-*/policy.xml; do
  [ -f "$f" ] || continue
  sed -i -E 's#<policy domain="coder" rights="none" pattern="(PDF|PS|EPS)" />#<policy domain="coder" rights="read|write" pattern="\1" />#' "$f"
done
