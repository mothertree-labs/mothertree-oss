# Allow Mail Ingress
# Applied to tn-<tenant>-mail namespace only.
# Permits:
#   - Postfix (infra-mail) to deliver inbound email to Stalwart on port 25
#   - Roundcube (tn-<tenant>-webmail) to connect to Stalwart for IMAP/SMTP/Sieve
#   - NGINX ingress (infra-ingress) to proxy external mail client connections (IMAP/SMTPS/Submission)
#   - Admin/Account portals (tn-<tenant>-admin) to reach Stalwart HTTP API (user provisioning, quotas)
#   - Email probe (same namespace) to connect to Stalwart for SMTP/IMAP on app-password ports
#   - Prometheus (infra-monitoring) to scrape email-probe metrics on port 9090
#
# Required environment variables:
#   NAMESPACE   - Target namespace (e.g., tn-example-mail)
#   TENANT_NAME - Tenant name (e.g., example)
#
# Applied to mail namespace only by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-mail-ingress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-mail-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    # Postfix (infra-mail) delivering inbound email to Stalwart
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-mail
      ports:
        - protocol: TCP
          port: 25
    # Roundcube (webmail) connecting to Stalwart for IMAP, SMTP submission, Sieve
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-webmail
      ports:
        - protocol: TCP
          port: 993
        - protocol: TCP
          port: 587
        - protocol: TCP
          port: 4190
    # NGINX ingress controller (TCP passthrough for external mail clients)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-ingress
      ports:
        - protocol: TCP
          port: 465
        - protocol: TCP
          port: 587
        - protocol: TCP
          port: 588
        - protocol: TCP
          port: 993
        - protocol: TCP
          port: 994
    # Admin/Account portals (admin namespace) accessing Stalwart HTTP API
    # for user provisioning and quota management
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tn-${TENANT_NAME}-admin
      ports:
        - protocol: TCP
          port: 8080
    # Calendar automation (same namespace) connecting to Stalwart for IMAP and admin API
    - from:
        - podSelector:
            matchLabels:
              app: calendar-automation
      ports:
        - protocol: TCP
          port: 994
        - protocol: TCP
          port: 443
    # Email probe (same namespace) connecting to Stalwart for SMTP submission and IMAP
    - from:
        - podSelector:
            matchLabels:
              app: email-probe
      ports:
        - protocol: TCP
          port: 588
        - protocol: TCP
          port: 994
    # Prometheus (infra-monitoring) scraping email-probe metrics
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: infra-monitoring
      ports:
        - protocol: TCP
          port: 9090
