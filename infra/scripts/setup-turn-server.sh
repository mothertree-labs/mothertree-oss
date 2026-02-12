#!/bin/bash
set -e

# Setup script for TURN server
# This script installs and configures Coturn on Ubuntu

echo "Starting TURN server setup..."

# Update system
apt-get update
apt-get upgrade -y

# Install Coturn
apt-get install -y coturn

# Enable Coturn service
systemctl enable coturn

# Create turnserver configuration directory
mkdir -p /etc/turnserver

# Set permissions
chown turnserver:turnserver /etc/turnserver
chmod 755 /etc/turnserver

# Create log directory
mkdir -p /var/log/turnserver
chown turnserver:turnserver /var/log/turnserver

# Generate self-signed certificate for TLS (optional)
# Honor MT_ENV and BASE_DOMAIN for hostname; defaults keep prod behavior
MT_ENV=${MT_ENV:-prod}
BASE_DOMAIN=${BASE_DOMAIN:-example.com}
TURN_HOST=${TURN_HOST:-"turn.${MT_ENV}.${BASE_DOMAIN}"}
if [ ! -f /etc/ssl/certs/turnserver.crt ]; then
    openssl req -x509 -newkey rsa:4096 -keyout /etc/ssl/private/turnserver.key -out /etc/ssl/certs/turnserver.crt -days 365 -nodes -subj "/C=US/ST=State/L=City/O=Organization/CN=${TURN_HOST}"
    chmod 600 /etc/ssl/private/turnserver.key
    chmod 644 /etc/ssl/certs/turnserver.crt
fi

# Configure systemd service
cat > /etc/systemd/system/turnserver.service << 'EOF'
[Unit]
Description=TURN Server
After=network.target

[Service]
Type=simple
User=turnserver
Group=turnserver
ExecStart=/usr/bin/turnserver -c /etc/turnserver/turnserver.conf
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
systemctl daemon-reload

echo "TURN server setup completed successfully!"
