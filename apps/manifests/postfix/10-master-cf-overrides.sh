#!/bin/sh
set -e
echo "Configuring port-specific master.cf overrides..."

# Port 25 (smtp): Strict recipient verification for inbound mail
# reject_unverified_recipient probes Stalwart to verify recipients exist
# reject_unauth_destination prevents open relay
postconf -P "smtp/inet/smtpd_recipient_restrictions=reject_unverified_recipient,reject_unauth_destination"
postconf -P "smtp/inet/smtpd_relay_restrictions=reject_unauth_destination"

# Port 587 (submission): Internal apps only (Keycloak, Alertmanager, Stalwart)
# permit_mynetworks allows cluster pods to send to any external address
# This port is only reachable via ClusterIP (not exposed externally)
postconf -P "submission/inet/smtpd_recipient_restrictions=permit_mynetworks,reject"
postconf -P "submission/inet/smtpd_relay_restrictions=permit_mynetworks,reject"
postconf -P "submission/inet/syslog_name=postfix/submission"

echo "Port-specific master.cf configuration complete"
postconf -Mf | grep -E "^(smtp|submission)"
