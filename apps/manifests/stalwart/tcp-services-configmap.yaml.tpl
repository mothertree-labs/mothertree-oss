# TCP Services ConfigMap for nginx-ingress mail port routing
# This ConfigMap configures the nginx-ingress controller to proxy TCP traffic
# for mail protocols (SMTP, IMAP) to per-tenant Stalwart mail servers.
#
# Multi-tenant: Each tenant has unique external ports that map to standard
# internal ports on its Stalwart ClusterIP service. deploy-stalwart.sh
# patches this ConfigMap to add/update entries per tenant.
#
# Port 30025 (SMTP inbound) is also added to this ConfigMap by deploy_infra,
# mapping to infra-mail/postfix:25 for VPN Postfix inbound mail routing.
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   NS_INGRESS - Ingress namespace (e.g., infra-ingress)
#   STALWART_SMTPS_PORT - External SMTPS port (maps to internal 465)
#   STALWART_SUBMISSION_PORT - External submission port (maps to internal 587)
#   STALWART_IMAPS_PORT - External IMAPS port (maps to internal 993)
#   STALWART_IMAPS_APP_PORT - External IMAPS app password port (maps to internal 994)
#   STALWART_SUBMISSION_APP_PORT - External submission app password port (maps to internal 588)

apiVersion: v1
kind: ConfigMap
metadata:
  name: tcp-services
  namespace: ${NS_INGRESS}
data:
  # SMTPS - SMTP with implicit TLS (OAUTHBEARER)
  "${STALWART_SMTPS_PORT}": "${NS_MAIL}/stalwart:465:PROXY:"
  # Submission - SMTP with STARTTLS (OAUTHBEARER)
  "${STALWART_SUBMISSION_PORT}": "${NS_MAIL}/stalwart:587:PROXY:"
  # IMAPS - IMAP with implicit TLS (OAUTHBEARER, used by Roundcube)
  "${STALWART_IMAPS_PORT}": "${NS_MAIL}/stalwart:993:PROXY:"
  # IMAPS App - IMAP with implicit TLS (PLAIN/LOGIN via app passwords)
  "${STALWART_IMAPS_APP_PORT}": "${NS_MAIL}/stalwart:994:PROXY:"
  # Submission App - SMTP with STARTTLS (PLAIN/LOGIN via app passwords)
  "${STALWART_SUBMISSION_APP_PORT}": "${NS_MAIL}/stalwart:588:PROXY:"
