# Custom Roundcube Docker image with calendar and Mailvelope plugins
# Installs dependencies via Composer and copies plugin files from submodules.
#
# Build from repo root: docker buildx build -f apps/docker/roundcube/Dockerfile -t ghcr.io/myorg/mothertree-roundcube:latest .

FROM roundcube/roundcubemail:1.6.12-apache

ENV COMPOSER_ALLOW_SUPERUSER=1

# The Roundcube source is in /usr/src/roundcubemail and gets copied to /var/www/html at runtime
WORKDIR /usr/src/roundcubemail

# Install just the dependencies needed by Kolab plugins (without the plugins themselves)
# This avoids the Roundcube plugin installer which tries to run DB scripts
RUN composer require --no-plugins --no-scripts \
    sabre/vobject:^4.5 \
    sabre/xml:^4.0 \
    sabre/uri:^3.0 \
    pear/http_request2:^2.6 \
    pear/net_sieve:~1.4.0

# Copy Kolab plugins from submodules (pre-patched with bearer token support)
COPY submodules/roundcubemail-plugins-kolab/plugins/calendar /usr/src/roundcubemail/plugins/calendar
COPY submodules/roundcubemail-plugins-kolab/plugins/libcalendaring /usr/src/roundcubemail/plugins/libcalendaring
COPY submodules/roundcubemail-plugins-kolab/plugins/libkolab /usr/src/roundcubemail/plugins/libkolab

# Copy Mailvelope client plugin from submodule
COPY submodules/mailvelope_client /usr/src/roundcubemail/plugins/mailvelope_client

# Upgrade TinyMCE 5.10.9 → 8.3.2 for Safari performance
# TinyMCE 5.x has a known contenteditable perf issue in Safari/WebKit
# v7+ requires license_key: 'gpl' for open-source use (set in patched editor.js)
RUN rm -rf /usr/src/roundcubemail/program/js/tinymce \
    && curl -sL https://registry.npmjs.org/tinymce/-/tinymce-8.3.2.tgz -o /tmp/tinymce.tgz \
    && cd /tmp && tar xzf tinymce.tgz \
    && mv package /usr/src/roundcubemail/program/js/tinymce \
    && rm /tmp/tinymce.tgz

# Patched editor.js for TinyMCE 8 compatibility (renamed options, removed plugins, GPL key)
COPY apps/docker/roundcube/editor.js /usr/src/roundcubemail/program/js/editor.js
COPY apps/docker/roundcube/editor.js /usr/src/roundcubemail/program/js/editor.min.js

WORKDIR /var/www/html
