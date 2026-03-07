apiVersion: batch/v1
kind: Job
metadata:
  name: nextcloud-oidc-config
  namespace: files
  labels:
    app.kubernetes.io/name: nextcloud-oidc-config
    app.kubernetes.io/part-of: mother-tree
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nextcloud-oidc-config
        app.kubernetes.io/part-of: mother-tree
    spec:
      restartPolicy: Never
      containers:
        - name: oidc-config
          image: bitnami/kubectl:latest
          imagePullPolicy: IfNotPresent
          env:
            - name: FILES_HOST
              value: "${FILES_HOST}"
            - name: AUTH_HOST
              value: "${AUTH_HOST}"
            - name: DOCS_HOST
              value: "${DOCS_HOST}"
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: OIDC_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: nextcloud-oidc
                  key: oidc-client-id
            - name: OIDC_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: nextcloud-oidc
                  key: oidc-client-secret
            - name: CALENDAR_ENABLED
              value: "${CALENDAR_ENABLED}"
            - name: SMTP_DOMAIN
              value: "${SMTP_DOMAIN}"
            - name: JITSI_HOST
              value: "${JITSI_HOST}"
            - name: OFFICE_ENABLED
              value: "${OFFICE_ENABLED}"
            - name: OFFICE_HOST
              value: "${OFFICE_HOST}"
            - name: NS_OFFICE
              value: "${NS_OFFICE}"
            - name: GOOGLE_IMPORT_ENABLED
              value: "${GOOGLE_IMPORT_ENABLED}"
            - name: GOOGLE_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: nextcloud-google
                  key: google-client-id
                  optional: true
            - name: GOOGLE_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: nextcloud-google
                  key: google-client-secret
                  optional: true
          command:
            - /bin/bash
            - -c
            - |
              set -euo pipefail
              echo "=== Nextcloud OIDC Configuration ==="

              # Helper: resolve a Running, Ready Nextcloud pod (skips Terminating pods).
              # Called before each kubectl exec to tolerate HPA scale-down and rolling updates.
              # Prefers Ready pods to avoid exec into containers that are still starting up.
              get_nc_pod() {
                local pods
                pods=$(kubectl get pod -n "$POD_NAMESPACE" \
                  -l app.kubernetes.io/instance=nextcloud \
                  -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
                # Prefer Ready pods (no deletionTimestamp, Ready=True)
                local ready_pod
                ready_pod=$(echo "$pods" | grep '^|True|' | head -1 | cut -d'|' -f3)
                if [ -n "$ready_pod" ]; then
                  echo "$ready_pod"
                  return
                fi
                # Fall back to any non-terminating pod
                echo "$pods" | grep '^|' | head -1 | cut -d'|' -f3 || true
              }

              # Helper: kubectl exec against a freshly-resolved pod.
              nc_exec() {
                local pod
                pod=$(get_nc_pod)
                if [ -z "$pod" ]; then
                  echo "ERROR: No Running Nextcloud pod found"
                  return 1
                fi
                kubectl exec -n "$POD_NAMESPACE" "$pod" -- "$@"
              }

              # Wait for Nextcloud pod to be ready
              echo "Waiting for Nextcloud pod to be ready in namespace $POD_NAMESPACE..."
              if ! kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=nextcloud -n "$POD_NAMESPACE" --timeout=600s; then
                echo "ERROR: Nextcloud pod did not become ready within 600s"
                echo ""
                echo "Nextcloud pods:"
                kubectl get pods -n "$POD_NAMESPACE" -l app.kubernetes.io/instance=nextcloud -o wide || true
                NC_POD="$(get_nc_pod || true)"
                if [ -n "$NC_POD" ]; then
                  echo ""
                  echo "Describe Nextcloud pod $NC_POD:"
                  kubectl describe pod -n "$POD_NAMESPACE" "$NC_POD" || true
                fi
                echo ""
                echo "Recent events in $POD_NAMESPACE:"
                kubectl get events -n "$POD_NAMESPACE" --sort-by=.lastTimestamp | tail -n 80 || true
                exit 1
              fi

              NEXTCLOUD_POD=$(get_nc_pod)
              if [ -z "$NEXTCLOUD_POD" ]; then
                echo "ERROR: Could not find Running Nextcloud pod"
                exit 1
              fi
              echo "Found Nextcloud pod: $NEXTCLOUD_POD"

              # Wait for Nextcloud installation to complete
              echo "Waiting for Nextcloud installation to complete..."
              for i in $(seq 1 60); do
                NEXTCLOUD_POD=$(get_nc_pod)
                if [ -z "$NEXTCLOUD_POD" ]; then
                  echo "Waiting for a Running pod... (attempt $i/60)"
                  sleep 10
                  continue
                fi
                INSTALLED=$(kubectl exec -n "$POD_NAMESPACE" "$NEXTCLOUD_POD" -- cat /var/www/html/config/config.php 2>/dev/null | grep "'installed'" | grep "true" || true)
                if [ -n "$INSTALLED" ]; then
                  echo "Nextcloud installation confirmed on $NEXTCLOUD_POD"
                  break
                fi
                echo "Waiting for installation... (attempt $i/60)"
                sleep 10
              done
              
              # Install user_oidc app
              echo "Installing user_oidc app..."
              nc_exec su -s /bin/sh www-data -c "php occ app:install user_oidc" 2>/dev/null || true
              nc_exec su -s /bin/sh www-data -c "php occ app:enable user_oidc"
              
              # Enable login token storage for cross-app OIDC token access
              echo "Enabling login token storage..."
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set --value=1 user_oidc store_login_token"
              echo "user_oidc app enabled with token storage"

              # Disable other login methods (auto-redirect to OIDC)
              echo "Disabling other login methods (auto-redirect to OIDC)..."
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends"
              echo "Other login methods disabled - users will auto-redirect to OIDC"

              # Create or update OIDC provider (idempotent - same command creates or updates)
              # Using email as user ID for stable identification across deployments
              echo "Configuring OIDC provider 'Google' with email-based user identification..."
              nc_exec su -s /bin/sh www-data -c "php occ user_oidc:provider 'Google' \
                --clientid='$OIDC_CLIENT_ID' \
                --clientsecret='$OIDC_CLIENT_SECRET' \
                --discoveryuri='https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}/.well-known/openid-configuration' \
                --scope='openid email profile' \
                --unique-uid=0 \
                --mapping-uid=email \
                --mapping-display-name=name \
                --mapping-email=email \
                --check-bearer=1 \
                --send-id-token-hint=1"
              echo "OIDC provider configured with email as user ID and bearer token validation enabled"

              # Verify provider was created
              echo "Verifying OIDC provider..."
              nc_exec su -s /bin/sh www-data -c "php occ user_oidc:provider"
              
              # Install and enable Calendar app (if enabled)
              if [ "$CALENDAR_ENABLED" = "true" ]; then
                echo "Installing Calendar app..."
                nc_exec su -s /bin/sh www-data -c "php occ app:install calendar" 2>/dev/null || true
                nc_exec su -s /bin/sh www-data -c "php occ app:enable calendar"
                echo "Calendar app enabled"
              else
                echo "Calendar app: skipping (features.calendar_enabled is not true)"
              fi

              # Enable and configure Jitsi Calendar integration (if calendar + jitsi are enabled)
              if [ "$CALENDAR_ENABLED" = "true" ] && [ -n "$JITSI_HOST" ]; then
                echo "Enabling Jitsi Calendar integration..."
                nc_exec su -s /bin/sh www-data -c "php occ app:enable jitsi_calendar" 2>/dev/null || true
                nc_exec su -s /bin/sh www-data -c "php occ config:app:set jitsi_calendar jitsi_host --value='https://$JITSI_HOST'"
                echo "Jitsi Calendar integration enabled (host: https://$JITSI_HOST)"
              fi
              
              # Configure email/SMTP for calendar invitations and notifications
              echo "Configuring email settings for calendar invitations..."
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_smtpmode --value='smtp'"
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_smtphost --value='postfix-internal.infra-mail.svc.cluster.local'"
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_smtpport --value='587'"
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_smtpsecure --value=''"
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_smtpauth --value='0'"
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_from_address --value='calendar'"
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_domain --value='$SMTP_DOMAIN'"
              # Disable TLS certificate verification for internal cluster SMTP (Postfix uses self-signed/internal certs)
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_smtpstreamoptions ssl verify_peer --type=boolean --value=false"
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_smtpstreamoptions ssl verify_peer_name --type=boolean --value=false"
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set mail_smtpstreamoptions ssl allow_self_signed --type=boolean --value=true"
              echo "Email configured: calendar@$SMTP_DOMAIN via postfix-internal.infra-mail.svc.cluster.local:587"
              
              # Collabora Online (richdocuments) — enable or disable based on office feature flag
              if [ "$OFFICE_ENABLED" = "true" ]; then
                echo "Enabling Collabora Online (richdocuments)..."
                nc_exec su -s /bin/sh www-data -c "php occ app:install richdocuments" 2>/dev/null || true
                nc_exec su -s /bin/sh www-data -c "php occ app:enable richdocuments"
                nc_exec su -s /bin/sh www-data -c "php occ config:app:set richdocuments wopi_url --value='https://${OFFICE_HOST}'"
                # No wopi_allowlist — Collabora callbacks go through the external URL which may
                # traverse Cloudflare (prod) or hairpin through the LB (dev). The source IP varies
                # (Cloudflare edge, node IP, pod IP) making an IP allowlist fragile. WOPI security
                # relies on the per-request access_token instead.
                nc_exec su -s /bin/sh www-data -c "php occ config:app:set richdocuments wopi_allowlist --value=''"
                # Wait for Collabora discovery endpoint to be reachable before activating.
                # Try internal ClusterIP first (avoids NB hairpin on dev where PROXY protocol
                # isn't injected for in-cluster traffic). Fall back to external URL for prod
                # where NetworkPolicies may block cross-namespace port 9980.
                COLLABORA_INTERNAL="http://collabora-online.${NS_OFFICE}.svc.cluster.local:9980/hosting/discovery"
                COLLABORA_EXTERNAL="https://${OFFICE_HOST}/hosting/discovery"
                echo "Waiting for Collabora discovery endpoint..."
                for i in $(seq 1 30); do
                  if nc_exec su -s /bin/sh www-data -c \
                    "curl -sf -m 5 ${COLLABORA_INTERNAL} -o /dev/null" 2>/dev/null; then
                    echo "Collabora discovery endpoint reachable (internal)"
                    break
                  elif nc_exec su -s /bin/sh www-data -c \
                    "curl -sf -m 5 ${COLLABORA_EXTERNAL} -o /dev/null" 2>/dev/null; then
                    echo "Collabora discovery endpoint reachable (external)"
                    break
                  fi
                  echo "  Waiting for Collabora... (attempt $i/30)"
                  sleep 10
                done
                # activate-config pre-caches MIME type mappings by fetching the discovery
                # endpoint from wopi_url. This can fail on dev due to PROXY protocol hairpin
                # (in-cluster traffic to the external URL bypasses the NodeBalancer, so nginx
                # rejects the connection). Non-fatal: Nextcloud lazily discovers MIME types
                # when users open documents, and the internal endpoint was already verified above.
                nc_exec su -s /bin/sh www-data -c "php occ richdocuments:activate-config" || \
                  echo "WARNING: richdocuments:activate-config failed (MIME types will be discovered lazily)"
                echo "Collabora Online enabled (wopi_url: https://${OFFICE_HOST})"
              else
                echo "Disabling document editing apps..."
                nc_exec su -s /bin/sh www-data -c "php occ app:disable richdocuments" 2>/dev/null || true
              fi
              nc_exec su -s /bin/sh www-data -c "php occ app:disable onlyoffice" 2>/dev/null || true
              
              # Enable external links app for linking to La Suite Docs
              echo "Enabling external links app..."
              nc_exec su -s /bin/sh www-data -c "php occ app:install external" 2>/dev/null || true
              nc_exec su -s /bin/sh www-data -c "php occ app:enable external" 2>/dev/null || true

              # Configure External Sites with a "Documents" link to La Suite Docs
              echo "Configuring External Sites link to La Suite Docs..."
              # Derive DOCS_HOST from FILES_HOST (files.X.example.com -> docs.X.example.com)
              DOCS_HOST="${FILES_HOST/files./docs.}"
              echo "Derived DOCS_HOST: $DOCS_HOST"

              SITES_CONFIG='{"1":{"id":1,"name":"Documents","url":"https://'"$DOCS_HOST"'","lang":"","type":"link","device":"","icon":"external.svg","groups":[],"redirect":true}}'
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set external sites --value='$SITES_CONFIG'"
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set external max_site --value='1'"
              echo "External Sites link configured"
              
              # Google Integration (Drive/Calendar/Contacts import)
              if [ "${GOOGLE_IMPORT_ENABLED:-false}" = "true" ]; then
                echo "Installing Google Integration app..."
                nc_exec su -s /bin/sh www-data -c "php occ app:install integration_google" 2>/dev/null || true
                nc_exec su -s /bin/sh www-data -c "php occ app:enable integration_google"
                nc_exec su -s /bin/sh www-data -c "php occ config:app:set integration_google client_id --value='$GOOGLE_CLIENT_ID'"
                nc_exec su -s /bin/sh www-data -c "php occ config:app:set integration_google client_secret --value='$GOOGLE_CLIENT_SECRET'"
                echo "Google Integration app enabled"
              else
                echo "Google Integration: skipping (features.google_import_enabled is not true)"
              fi

              # Enable custom Link editor app (deployed by deploy-nextcloud.sh to custom_apps/)
              echo "Enabling custom Link editor app..."
              nc_exec su -s /bin/sh www-data -c "php occ app:enable files_linkeditor" 2>/dev/null || true

              # Configure La Suite Docs URL for the "New Document" menu entry
              echo "Configuring La Suite Docs URL..."
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set files_linkeditor docs_url --value='https://$DOCS_HOST'"
              echo "Link editor app enabled and configured"

              # Enable guest_bridge app (provisions guest users when sharing with external emails)
              echo "Enabling guest_bridge app..."
              nc_exec su -s /bin/sh www-data -c "php occ app:enable guest_bridge" 2>/dev/null || true
              echo "Guest bridge app enabled (API config set by deploy-nextcloud.sh)"

              # === Share Security: sharebymail + guest_bridge (Issue #119, PR #155) ===
              # sharebymail MUST be enabled — it's the only provider for TYPE_EMAIL shares.
              # Security is maintained by guest_bridge, which suppresses sharebymail's
              # notification emails (no unauthenticated public links are sent). Instead,
              # guests receive contextual invite emails from Account Portal.
              echo "Enabling sharebymail app (required by guest_bridge for TYPE_EMAIL shares)..."
              nc_exec su -s /bin/sh www-data -c "php occ app:enable sharebymail" 2>/dev/null || true

              # Share security policies: disable public links, use email + guest_bridge for external sharing
              echo "Configuring share security policies..."
              # Disable public link shares — all external sharing goes through email + guest_bridge
              # (guests authenticate via OIDC/passkeys, no anonymous access)
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set core shareapi_allow_links --value='no'"
              # No password enforcement needed (public links disabled, email shares use passkeys)
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set core shareapi_enforce_links_password --value='no'"
              # Suggest 30-day expiry by default but don't enforce it
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set core shareapi_default_expire_date --value='yes'"
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set core shareapi_expire_after_n_days --value='30'"
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set core shareapi_enforce_expire_date --value='no'"
              nc_exec su -s /bin/sh www-data -c "php occ config:app:set core shareapi_default_permissions --value='1'"
              echo "Share security policies configured"

              # Set default app to Files (skip dashboard splash screen)
              echo "Setting default app to Files..."
              nc_exec su -s /bin/sh www-data -c "php occ config:system:set defaultapp --value='files'"
              echo "Default app set to Files"

              # Disable first run wizard (welcome dialog)
              echo "Disabling first run wizard..."
              nc_exec su -s /bin/sh www-data -c "php occ app:disable firstrunwizard" 2>/dev/null || true
              echo "First run wizard disabled"

              # Clean up default files for admin user (only if they exist)
              echo "Cleaning up default files for admin user..."
              # Delete common default files/folders if they exist
              for FILE in Documents Photos Nextcloud\ Manual.pdf Nextcloud.png; do
                nc_exec su -s /bin/sh www-data -c "php occ files:delete admin/$FILE" 2>/dev/null || true
              done
              # Scan files to update the database
              nc_exec su -s /bin/sh www-data -c "php occ files:scan admin" 2>/dev/null || true
              echo "Admin files cleaned up"
              
              echo "=== Nextcloud OIDC configuration complete ==="
              echo "Access Nextcloud at: https://${FILES_HOST}"
      serviceAccountName: nextcloud-oidc-config
