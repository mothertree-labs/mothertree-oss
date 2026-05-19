#!/bin/sh
set -e
echo "Configuring port-specific master.cf overrides..."

# Port 25 (smtp): Strict recipient verification for inbound mail
# reject_unverified_recipient probes Stalwart to verify recipients exist
# reject_unauth_destination prevents open relay
postconf -P "smtp/inet/smtpd_recipient_restrictions=reject_unverified_recipient,reject_unauth_destination"
postconf -P "smtp/inet/smtpd_relay_restrictions=reject_unauth_destination"

echo "Port-specific master.cf configuration complete"
postconf -Mf | grep -E "^smtp"
