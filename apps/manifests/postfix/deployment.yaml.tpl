apiVersion: apps/v1
kind: Deployment
metadata:
  name: postfix
  namespace: ${NS_MAIL}
  labels:
    app: postfix
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postfix
  template:
    metadata:
      labels:
        app: postfix
      annotations:
        # Trigger redeployment when config changes
        checksum/postfix-config: "${CHECKSUM_POSTFIX_CONFIG}"
        checksum/postfix-init-scripts: "${CHECKSUM_INIT_SCRIPTS}"
    spec:
      serviceAccountName: postfix
      containers:
        # Postfix main container — inbound MX dispatch on port 25 only.
        # Outbound DKIM signing is delegated to AWS SES Easy DKIM at tenant
        # Stalwarts; this pod no longer signs or accepts submission.
        - name: postfix
          # boky/postfix:v5.1.0 - SMTP relay image
          # Source: https://github.com/bokysan/docker-postfix
          # v5.1.0 released Jan 2025, supports /docker-init.d/ scripts
          image: boky/postfix:v5.1.0
          ports:
            - containerPort: 25
              name: smtp
          # Mount init script for port-specific master.cf configuration
          # Scripts in /docker-init.d/ run after config generation but before Postfix starts
          volumeMounts:
            - name: postfix-init-scripts
              mountPath: /docker-init.d
              readOnly: true
            - name: postfix-tables
              mountPath: /etc/postfix/tables
          env:
            - name: ALLOWED_SENDER_DOMAINS
              value: "${SMTP_ALLOWED_SENDER_DOMAINS}"
            - name: HOSTNAME
              value: "${SMTP_HOSTNAME}"
            - name: DKIM_AUTOGENERATE
              value: "false"
            - name: POSTFIX_myhostname
              value: "${SMTP_HOSTNAME}"
            - name: POSTFIX_mydomain
              value: "${SMTP_DOMAIN}"
            - name: POSTFIX_myorigin
              value: "${SMTP_DOMAIN}"
            - name: POSTFIX_mynetworks
              value: "${POSTFIX_MYNETWORKS}"
            # Inbound mail routing - transport_maps and relay_domains
            # These files are managed by configure-mail-routing for each tenant
            # Init container copies them to /etc/postfix/tables/ and runs postmap
            - name: POSTFIX_relay_domains
              value: "hash:/etc/postfix/tables/relay_domains"
            - name: POSTFIX_transport_maps
              value: "hash:/etc/postfix/tables/transport"
            # Override boky/postfix image's default SMTP restrictions
            # The image defaults are designed for send-only, not for relay
            # Allow connections from anyone (we filter at recipient level)
            - name: POSTFIX_smtpd_client_restrictions
              value: permit
            # Relay restrictions: allow mynetworks, reject unauthorized destinations
            - name: POSTFIX_smtpd_relay_restrictions
              value: "permit_mynetworks, reject_unauth_destination"
            # Port-25 recipient restrictions (overridden in master.cf to add
            # reject_unverified_recipient for backscatter prevention).
            - name: POSTFIX_smtpd_recipient_restrictions
              value: "reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination"
            # Address verification settings - probe downstream to verify recipients exist
            - name: POSTFIX_address_verify_poll_count
              value: "3"
            - name: POSTFIX_address_verify_poll_delay
              value: 3s
            - name: POSTFIX_address_verify_map
              value: "btree:/var/lib/postfix/verify"
            # Reject permanently (550) for invalid addresses - don't use temp failure (450)
            - name: POSTFIX_unverified_recipient_reject_code
              value: "550"
            - name: POSTFIX_unverified_recipient_reject_reason
              value: "Recipient address rejected: undeliverable address"
            # Sender restrictions: permit all senders (needed for inbound mail from external domains)
            # The Docker image generates restrictive rules from ALLOWED_SENDER_DOMAINS - override them
            # Relay control is handled by smtpd_relay_restrictions, not sender restrictions
            - name: POSTFIX_smtpd_sender_restrictions
              value: permit
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              memory: 256Mi
          # Graceful shutdown: let K8s endpoint removal propagate before SIGTERM
          # so in-flight mail delivery completes without new connections arriving.
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 5"]
          # Liveness probe - check SMTP port
          livenessProbe:
            tcpSocket:
              port: 25
            initialDelaySeconds: 30
            periodSeconds: 30
          # Readiness probe
          readinessProbe:
            tcpSocket:
              port: 25
            initialDelaySeconds: 10
            periodSeconds: 10

      # Init container: copy routing files from the read-only postfix-routing
      # ConfigMap into a writable emptyDir, then postmap to generate hash .db
      # files Postfix reads at runtime.
      initContainers:
        - name: prepare-routing
          image: boky/postfix:v5.1.0
          command:
            - /bin/sh
            - -c
            - |
              set -e
              mkdir -p /etc/postfix/tables
              # Copy routing files if they exist (ConfigMap is optional)
              if [ -f /etc/postfix/routing/transport ]; then
                cp /etc/postfix/routing/transport /etc/postfix/tables/transport
                postmap /etc/postfix/tables/transport
                echo "Generated transport.db"
              else
                # Create empty files if ConfigMap doesn't exist yet
                touch /etc/postfix/tables/transport
                postmap /etc/postfix/tables/transport
                echo "Created empty transport.db"
              fi

              if [ -f /etc/postfix/routing/relay_domains ]; then
                cp /etc/postfix/routing/relay_domains /etc/postfix/tables/relay_domains
                postmap /etc/postfix/tables/relay_domains
                echo "Generated relay_domains.db"
              else
                touch /etc/postfix/tables/relay_domains
                postmap /etc/postfix/tables/relay_domains
                echo "Created empty relay_domains.db"
              fi

              ls -la /etc/postfix/tables/
          volumeMounts:
            - name: postfix-routing
              mountPath: /etc/postfix/routing
              readOnly: true
            - name: postfix-tables
              mountPath: /etc/postfix/tables
      volumes:
        - name: postfix-config
          configMap:
            name: postfix-config
        # Routing ConfigMap for multi-tenant inbound mail
        # Managed by configure-mail-routing (not this script).
        # Contains transport and relay_domains files mapping domains to tenant Stalwarts.
        - name: postfix-routing
          configMap:
            name: postfix-routing
            optional: true
        # Writable volume for postmap-generated .db files
        # Init container copies routing files here and generates hash databases
        - name: postfix-tables
          emptyDir: {}
        # Init scripts for port-specific master.cf configuration
        # Scripts run via boky/postfix's /docker-init.d/ mechanism
        - name: postfix-init-scripts
          configMap:
            name: postfix-init-scripts
            defaultMode: 0755
      # Budget: preStop (5s) + graceful shutdown (up to 40s).
      terminationGracePeriodSeconds: 45
