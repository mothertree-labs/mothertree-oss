# OpenDKIM configuration for domain ${SMTP_DOMAIN}

# Basic settings
Domain                  ${SMTP_DOMAIN}
Selector                ${DKIM_SELECTOR}
KeyFile                 /etc/opendkim/keys/dkim.private

# Network settings
Socket                  inet:8891@127.0.0.1
PidFile                 /var/run/opendkim/opendkim.pid
UserID                  opendkim:opendkim

# Logging
Syslog                  yes
SyslogSuccess           yes

# Verification settings
Mode                    sv
SubDomains              no
Canonicalization        relaxed/simple
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable

# Security settings
SendReports             yes
ReportAddress           postmaster@${SMTP_DOMAIN}
TemporaryDirectory      /tmp
# RequireSafeKeys is disabled because Kubernetes volume mounts have relaxed permissions
# The DKIM key is stored in a Kubernetes Secret, which provides the actual security
RequireSafeKeys         false

# Performance settings
DNSTimeout              5
SignatureAlgorithm      rsa-sha256
MinimumKeyBits          1024
