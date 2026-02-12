# OpenDKIM configuration for domain ${domain}

# Basic settings
Domain                  ${domain}
Selector                ${selector}
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
ReportAddress           postmaster@${domain}
TemporaryDirectory      /tmp
# RequireSafeKeys is disabled because Kubernetes volume mounts have relaxed permissions
# The DKIM key is stored in a Kubernetes Secret, which provides the actual security
RequireSafeKeys         false

# Performance settings
DNSTimeout              5
SignatureAlgorithm      rsa-sha256
MinimumKeyBits          1024 