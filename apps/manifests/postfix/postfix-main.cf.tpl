# Postfix main configuration for multi-tenant inbound mail routing
# This Postfix instance receives mail from the internet (via NodeBalancer:25)
# and routes it to the correct tenant Stalwart by recipient domain.
# Outbound submission + DKIM signing are delegated to tenant Stalwart → AWS SES
# (SES Easy DKIM), so this pod no longer signs or relays outbound since PR-4.
#
# See /usr/share/postfix/main.cf.dist for a commented, more complete version

# Basic settings
compatibility_level = 3.6
biff = no
append_dot_mydomain = no
readme_directory = no

# Network and hostname settings
myhostname = ${SMTP_HOSTNAME}
mydomain = ${SMTP_DOMAIN}
myorigin = ${SMTP_DOMAIN}
mydestination = $myhostname, localhost, localhost.localdomain
mynetworks = ${POSTFIX_MYNETWORKS}

# =============================================================================
# Inbound Mail Routing (Multi-Tenant)
# =============================================================================
# relay_domains: list of domains we accept mail for (routed to tenant Stalwarts)
# transport_maps: routes recipient domains to the correct tenant's Stalwart
# These files are managed by deploy-stalwart.sh when each tenant is deployed

# Domains we accept mail for and relay to tenant Stalwarts
# Format: domain OK
relay_domains = hash:/etc/postfix/relay_domains

# Transport map - routes by recipient domain to tenant Stalwart backends
# Format: domain smtp:[stalwart.tn-tenant-mail.svc.cluster.local]:25
transport_maps = hash:/etc/postfix/transport

# Disable local delivery - we route everything via transport_maps
local_transport = error:Local delivery disabled
local_recipient_maps =

# Interface settings
inet_interfaces = all
inet_protocols = all

# SMTP banner
smtpd_banner = $myhostname ESMTP $mail_name

# Message size limits (25MB)
message_size_limit = 26214400
mailbox_size_limit = 0

# Alias settings
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases

# Queue settings
queue_directory = /var/spool/postfix
maximal_queue_lifetime = 1d
bounce_queue_lifetime = 1d
default_process_limit = 100

# SMTP client settings — only used for relaying accepted inbound mail onward
# to the per-tenant Stalwart via transport_maps (plaintext over the K8s pod
# network). Tenant-outbound traffic no longer transits this pod.
smtp_helo_timeout = 60s
smtp_connect_timeout = 30s

# TLS/SSL configuration for outbound connections
smtp_tls_security_level = may
smtp_tls_note_starttls_offer = yes
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_session_cache_database = btree:$data_directory/smtp_scache

# SMTP server settings - allow mynetworks and relay_domains
# permit_mynetworks: allow internal cluster traffic (tenant Stalwarts sending outbound)
# reject_unauth_destination: reject mail we don't handle
# Note: relay_domains are implicitly permitted by Postfix before reject_unauth_destination
smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination
smtpd_client_restrictions = permit
smtpd_helo_restrictions = permit
smtpd_sender_restrictions = permit
# Recipient restrictions for port 25 (inbound mail).
# master.cf overrides this to add reject_unverified_recipient (backscatter
# prevention) on the port-25 smtpd service.
smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination

# Disable SASL authentication (inbound MX dispatch is unauthenticated)
smtpd_sasl_auth_enable = no

# Logging
maillog_file = /dev/stdout

# Disable unnecessary features for send-only server
home_mailbox =
mailbox_command =
virtual_alias_maps =
virtual_mailbox_maps =
virtual_mailbox_domains =

# Prevent backscatter
bounce_notice_recipient = postmaster
error_notice_recipient = postmaster
delay_notice_recipient = postmaster

# Security settings
disable_vrfy_command = yes
smtpd_helo_required = yes

# Rate limiting to prevent abuse
smtpd_client_connection_count_limit = 50
smtpd_client_connection_rate_limit = 100
smtpd_client_message_rate_limit = 100
