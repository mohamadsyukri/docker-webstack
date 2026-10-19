# PHP-FPM for Laravel. One Dockerfile for every PHP version; compose.yaml passes the versions.
ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-fpm-trixie

ARG XDEBUG_VERSION=3.3.2
ARG REDIS_VERSION=6.0.2

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libzip-dev \
    zip \
    unzip \
    git \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# wkhtmltopdf for PDF generation (barryvdh/laravel-snappy, yajra DataTables pdf export).
# Debian dropped the package because upstream is archived, so use the official static build:
# it ships the patched Qt needed for headers/footers and page numbers, and installs to
# /usr/local/bin, which is where config/snappy.php looks. The bookworm build runs on trixie.
RUN curl -sSL -o /tmp/wkhtmltox.deb \
    https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
    && rm -f /tmp/wkhtmltox.deb \
    && rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
    pdo_mysql \
    mbstring \
    exif \
    pcntl \
    bcmath \
    gd \
    zip \
    opcache \
    mysqli

# Installed and enabled, but XDEBUG_MODE=off (compose.yaml) keeps it idle until asked for.
RUN pecl install "redis-${REDIS_VERSION}" "xdebug-${XDEBUG_VERSION}" \
    && docker-php-ext-enable redis xdebug

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

WORKDIR /var/www/projects

# www-data = UID/GID 1000, the usual first WSL/Linux user, so files PHP writes stay yours.
RUN usermod -u 1000 www-data && groupmod -g 1000 www-data \
    && mkdir -p /var/log/php /tmp/sessions /tmp/uploads \
    && chown -R www-data:www-data /var/log/php /tmp/sessions /tmp/uploads \
    && chmod 1777 /tmp/sessions /tmp/uploads

USER www-data

EXPOSE 9000
CMD ["php-fpm", "--nodaemonize"]
