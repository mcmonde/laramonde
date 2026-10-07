# syntax=docker/dockerfile:1.7
ARG PHP_VERSION=8.4

FROM php:${PHP_VERSION}-fpm-bookworm

ARG APP_UID=1000
ARG APP_GID=1000

COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

RUN install-php-extensions \
        pdo_pgsql \
        pgsql \
        zip \
        gd \
        intl \
        bcmath \
        opcache \
        pcntl \
        redis \
        exif \
        imagick \
    && rm -rf /tmp/pear /var/cache/apt /var/lib/apt/lists/*

# Ghostscript lets imagick rasterize PDFs (e.g. spatie/pdf-to-image); Debian's ImageMagick policy blocks PDF by default
RUN apt-get update \
    && apt-get install -y --no-install-recommends ghostscript \
    && rm -rf /var/lib/apt/lists/* \
    && for f in /etc/ImageMagick-*/policy.xml; do \
         [ -f "$f" ] && sed -i -E 's#<policy domain="coder" rights="none" pattern="(PDF|PS|EPS)" />#<policy domain="coder" rights="read|write" pattern="\1" />#' "$f"; \
       done; true

# Runtime libs + fonts for wkhtmltopdf/wkhtmltoimage (e.g. h4cc/wkhtmltopdf-amd64 via laravel-snappy)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libxrender1 \
        libxext6 \
        libx11-6 \
        libfontconfig1 \
        libfreetype6 \
        libjpeg62-turbo \
        libpng16-16 \
        fontconfig \
        fonts-dejavu-core \
        xfonts-75dpi \
        xfonts-base \
    && rm -rf /var/lib/apt/lists/*

COPY conf/php.ini /usr/local/etc/php/conf.d/99-hardening.ini
COPY conf/opcache.ini /usr/local/etc/php/conf.d/10-opcache.ini
COPY conf/www.conf /usr/local/etc/php-fpm.d/zz-www.conf

RUN groupmod -o -g "${APP_GID}" www-data \
    && usermod -o -u "${APP_UID}" -g www-data www-data \
    && mkdir -p /var/www/html /var/www/apps \
    && chown -R www-data:www-data /var/www/html /var/www/apps

WORKDIR /var/www/html

USER www-data

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD php -r 'exit(@fsockopen("127.0.0.1", 9000) ? 0 : 1);'
