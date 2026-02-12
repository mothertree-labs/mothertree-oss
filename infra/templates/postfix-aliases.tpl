# Mail aliases for send-only Postfix server
# See aliases(5) for format

# System aliases
postmaster: root
MAILER-DAEMON: root
abuse: root
security: root
hostmaster: root
webmaster: root

# Bounce handling - send to a monitoring address
root: monitoring@${domain}

# No-reply handling (for noreply@mail.example.com)
noreply: /dev/null
no-reply: /dev/null
donotreply: /dev/null 