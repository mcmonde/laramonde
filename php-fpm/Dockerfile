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
    && rm -rf /tmp/pear /var/cache/apt /var/lib/apt/lists/*

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
