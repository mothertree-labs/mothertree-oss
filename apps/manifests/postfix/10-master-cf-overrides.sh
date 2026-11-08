#!/bin/sh
set -e
echo "Configuring port-specific master.cf overrides..."

# Port 25 (smtp): Strict recipient verification for inbound mail
# reject_unverified_recipient probes Stalwart to verify recipients exist
# reject_unauth_destination prevents open relay
postconf -P "smtp/inet/smtpd_recipient_restrictions=reject_unverified_recipient,reject_unauth_destination"
postconf -P "smtp/inet/smtpd_relay_restrictions=reject_unauth_destination"

# Port 10025: the same inbound MX service behind ingress-nginx, which sends a
# PROXY header carrying the real sender IP (tcp-services 25 ->
# infra-mail/postfix:10025:PROXY:PROXY). Identical restrictions to port 25.
# Port 25 itself stays plain for in-cluster clients and kubelet probes. The
# NetworkPolicy only lets ingress-nginx reach 10025, so nobody else can
# present a forged client IP. (postconf -M names a service by its port field.)
postconf -M "10025/inet=10025 inet n - n - - smtpd"
postconf -P "10025/inet/smtpd_upstream_proxy_protocol=haproxy"
postconf -P "10025/inet/smtpd_recipient_restrictions=reject_unverified_recipient,reject_unauth_destination"
postconf -P "10025/inet/smtpd_relay_restrictions=reject_unauth_destination"

echo "Port-specific master.cf configuration complete"
postconf -Mf | grep -E "^(smtp|10025)"
