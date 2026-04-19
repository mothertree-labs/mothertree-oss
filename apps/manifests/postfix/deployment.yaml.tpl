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
        checksum/opendkim-config: "${CHECKSUM_OPENDKIM_CONFIG}"
        checksum/postfix-init-scripts: "${CHECKSUM_INIT_SCRIPTS}"
    spec:
      serviceAccountName: postfix
      # OpenDKIM sidecar container
      containers:
        - name: opendkim
          # instrumentisto/opendkim:2.10 - verified Alpine-based OpenDKIM image
          image: instrumentisto/opendkim:2.10
          ports:
            - containerPort: 8891
              name: milter
          volumeMounts:
            - name: opendkim-config
              mountPath: /etc/opendkim
              readOnly: true
          # NOTE: Tenant DKIM keys are mounted at /etc/dkim-keys/<tenant>/ by create_env
          # No base mount needed here - each tenant gets their own volume mount
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
        # Postfix main container
        - name: postfix
          # boky/postfix:v5.1.0 - SMTP relay image with DKIM support
          # Source: https://github.com/bokysan/docker-postfix
          # v5.1.0 released Jan 2025, supports /docker-init.d/ scripts
          image: boky/postfix:v5.1.0
          ports:
            - containerPort: 25
              name: smtp
            - containerPort: 587
              name: submission
          # Mount init script for port-specific master.cf configuration
          # Scripts in /docker-init.d/ run after config generation but before Postfix starts
          volumeMounts:
            - name: postfix-init-scripts
              mountPath: /docker-init.d
              readOnly: true
            - name: postfix-tables
              mountPath: /etc/postfix/tables
            - name: ses-credentials
              mountPath: /etc/postfix/ses
              readOnly: true
          # SES outbound relay env vars (POSTFIX_relayhost + SASL/TLS settings) come from
          # the postfix-ses-env ConfigMap when present. Absent in envs without SES (dev
          # direct-send); optional: true lets the pod start cleanly in that case.
          envFrom:
            - configMapRef:
                name: postfix-ses-env
                optional: true
          env:
            - name: ALLOWED_SENDER_DOMAINS
              value: "${SMTP_ALLOWED_SENDER_DOMAINS}"
            - name: HOSTNAME
              value: "${SMTP_HOSTNAME}"
            # Use external OpenDKIM milter (sidecar)
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
            # Connect to OpenDKIM sidecar for DKIM signing
            - name: POSTFIX_smtpd_milters
              value: "inet:127.0.0.1:8891"
            - name: POSTFIX_non_smtpd_milters
              value: "inet:127.0.0.1:8891"
            - name: POSTFIX_milter_default_action
              value: accept
            - name: POSTFIX_milter_protocol
              value: "6"
            # Outbound relay: controlled by main.cf (relayhost appended by deploy-postfix.sh
            # when SES creds are present). In envs without SES, Postfix direct-delivers.
            # Inbound mail routing - transport_maps and relay_domains
            # These files are managed by deploy-stalwart.sh for each tenant
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
            # Recipient restrictions: use defaults, port-specific overrides are in master.cf
            # Port 25 (smtp): reject_unverified_recipient, reject_unauth_destination (in master.cf)
            # Port 587 (submission): permit_mynetworks, reject (in master.cf)
            # Note: main.cf restrictions serve as fallback if master.cf doesn't override
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

      # Init containers:
      # - prepare-routing: one-shot init that copies routing + SES SASL/TLS files
      #   from read-only ConfigMap/Secret mounts into a writable emptyDir, then runs
      #   postmap to generate the hash .db files Postfix reads at runtime.
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

              # SES SASL credentials and TLS policy (optional — only mounted when Secret exists).
              # Envs without SES (e.g. dev direct-send) skip this block cleanly.
              if [ -f /etc/postfix/ses/sasl_passwd ]; then
                cp /etc/postfix/ses/sasl_passwd /etc/postfix/tables/sasl_passwd
                chmod 600 /etc/postfix/tables/sasl_passwd
                postmap /etc/postfix/tables/sasl_passwd
                chmod 600 /etc/postfix/tables/sasl_passwd.db
                echo "Generated sasl_passwd.db"
              else
                echo "No SES sasl_passwd — direct-send mode"
              fi

              if [ -f /etc/postfix/ses/tls_policy ]; then
                cp /etc/postfix/ses/tls_policy /etc/postfix/tables/tls_policy
                postmap /etc/postfix/tables/tls_policy
                echo "Generated tls_policy.db"
              else
                echo "No SES tls_policy — direct-send mode"
              fi

              ls -la /etc/postfix/tables/
          volumeMounts:
            - name: postfix-routing
              mountPath: /etc/postfix/routing
              readOnly: true
            - name: postfix-tables
              mountPath: /etc/postfix/tables
            - name: ses-credentials
              mountPath: /etc/postfix/ses
              readOnly: true
      volumes:
        - name: postfix-config
          configMap:
            name: postfix-config
        - name: opendkim-config
          configMap:
            name: opendkim-config
        # Routing ConfigMap for multi-tenant inbound mail
        # This ConfigMap is created/managed by configure-mail-routing (not this script)
        # Contains transport and relay_domains files that map domains to tenant Stalwarts
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
        # AWS SES SMTP SASL credentials + TLS policy (optional — present only in envs with SES).
        # Secret is created by deploy-postfix.sh from SES_SMTP_* infra secrets. In envs without
        # SES (dev direct-send), the Secret does not exist and `optional: true` yields an empty
        # mount; the initContainer's `if [ -f ]` guards keep the startup path clean.
        - name: ses-credentials
          secret:
            secretName: ses-credentials
            defaultMode: 0400
            optional: true
        # NOTE: DKIM keys are mounted per-tenant by create_env at /etc/dkim-keys/<tenant>/
        # Each tenant's volume is added via kubectl patch when running create_env
      # Budget: Postfix preStop (5s) + graceful shutdown (up to 40s).
      terminationGracePeriodSeconds: 45
