# syntax=docker/dockerfile:1.7
ARG PHP_VERSION=8.4
ARG NODE_VERSION=22

FROM node:${NODE_VERSION}-bookworm-slim AS node

FROM php:${PHP_VERSION}-cli-bookworm

ARG APP_UID=1000
ARG APP_GID=1000

COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && install-php-extensions \
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
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        unzip \
        bash \
        openssh-client \
        less \
    && rm -rf /var/lib/apt/lists/* /tmp/pear \
    && groupmod -o -g "${APP_GID}" www-data \
    && usermod -o -u "${APP_UID}" -g www-data -s /bin/bash www-data \
    && mkdir -p /var/www/apps /home/www-data \
    && chown -R www-data:www-data /var/www/apps /home/www-data

WORKDIR /var/www/apps

USER www-data

ENV COMPOSER_HOME=/home/www-data/.composer
ENV COMPOSER_MEMORY_LIMIT=-1
