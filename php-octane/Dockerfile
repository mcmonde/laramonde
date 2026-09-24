# syntax=docker/dockerfile:1.7
# PHP CLI + Swoole for Laravel Octane. Not FPM — Octane speaks HTTP.
ARG PHP_VERSION=8.4

FROM php:${PHP_VERSION}-cli-bookworm

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
        swoole \
    && rm -rf /tmp/pear /var/cache/apt /var/lib/apt/lists/*

# PDF signature sidecar (apps/*/python/pdf_signature) — invoked by Octane via Process
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
        tesseract-ocr \
        tesseract-ocr-eng \
        libjpeg62-turbo \
        zlib1g \
        libffi8 \
    && rm -rf /var/lib/apt/lists/*

COPY conf/php.ini /usr/local/etc/php/conf.d/99-hardening.ini
COPY conf/opcache.ini /usr/local/etc/php/conf.d/10-opcache.ini

RUN groupmod -o -g "${APP_GID}" www-data \
    && usermod -o -u "${APP_UID}" -g www-data www-data \
    && mkdir -p /var/www/html /var/www/apps \
    && chown -R www-data:www-data /var/www/html /var/www/apps

WORKDIR /var/www/html

USER www-data

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
    CMD php -r 'exit(@fsockopen("127.0.0.1", 8000) ? 0 : 1);'
