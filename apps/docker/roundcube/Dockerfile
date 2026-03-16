# Custom Roundcube Docker image with Mailvelope, calendar redirect, and custom plugins
# Installs dependencies via Composer and copies plugin files from submodules.
#
# Build from repo root: docker buildx build -f apps/docker/roundcube/Dockerfile -t ghcr.io/myorg/mothertree-roundcube:latest .

FROM roundcube/roundcubemail:1.6.13-apache

ENV COMPOSER_ALLOW_SUPERUSER=1

# The Roundcube source is in /usr/src/roundcubemail and gets copied to /var/www/html at runtime
WORKDIR /usr/src/roundcubemail

# Install dependencies (net_sieve is needed by managesieve plugin)
RUN composer require --no-plugins --no-scripts \
    pear/net_sieve:~1.4.0

# Install keyboard shortcuts plugin via Composer (uses Roundcube plugin-installer)
RUN composer require joachimneu/keyboard_shortcuts:dev-master#0a83950ce3fd5082d1a4df65c83071d6e0589ba2

# Copy Mailvelope client plugin from submodule
COPY submodules/mailvelope_client /usr/src/roundcubemail/plugins/mailvelope_client

# Custom plugins
COPY apps/docker/roundcube/plugins/oauth_name /usr/src/roundcubemail/plugins/oauth_name
COPY apps/docker/roundcube/plugins/nextcloud_calendar /usr/src/roundcubemail/plugins/nextcloud_calendar

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

# mothertree custom skin (child of elastic)
COPY apps/docker/roundcube/skins/mothertree /usr/src/roundcubemail/skins/mothertree
COPY apps/admin-portal/public/fonts/figtree-*.woff2 /usr/src/roundcubemail/skins/mothertree/fonts/

WORKDIR /var/www/html
