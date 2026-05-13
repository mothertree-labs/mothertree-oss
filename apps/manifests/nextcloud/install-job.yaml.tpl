apiVersion: batch/v1
kind: Job
metadata:
  name: nextcloud-install
  namespace: ${NS_FILES}
  labels:
    app.kubernetes.io/name: nextcloud
    app.kubernetes.io/component: install
    app.kubernetes.io/part-of: mother-tree
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nextcloud
        app.kubernetes.io/component: install
        app.kubernetes.io/part-of: mother-tree
    spec:
      restartPolicy: Never
      serviceAccountName: nextcloud-install
      containers:
        - name: install
          image: nextcloud:32.0.5-apache
          imagePullPolicy: IfNotPresent
          env:
            - name: POSTGRES_HOST
              valueFrom: { secretKeyRef: { name: nextcloud-db, key: db-hostname } }
            - name: POSTGRES_DB
              valueFrom: { secretKeyRef: { name: nextcloud-db, key: db-database } }
            - name: POSTGRES_USER
              valueFrom: { secretKeyRef: { name: nextcloud-db, key: db-username } }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: nextcloud-db, key: db-password } }
            - name: NEXTCLOUD_ADMIN_USER
              valueFrom: { secretKeyRef: { name: nextcloud-credentials, key: nextcloud-username } }
            - name: NEXTCLOUD_ADMIN_PASSWORD
              valueFrom: { secretKeyRef: { name: nextcloud-credentials, key: nextcloud-password } }
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail

              echo "=== Nextcloud install Job ==="

              # 1. Wait for PgBouncer to accept a Nextcloud-user connection.
              echo "Waiting for database $POSTGRES_DB on $POSTGRES_HOST..."
              for i in $(seq 1 30); do
                if PGPASSWORD="$POSTGRES_PASSWORD" psql \
                     -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
                     -tAc 'SELECT 1' >/dev/null 2>&1; then
                  echo "Database reachable after $((i*5))s"
                  break
                fi
                sleep 5
              done

              # 2. Populate /var/www/html with the Nextcloud source. This mimics
              # the official entrypoint's rsync step. We bypass the entrypoint
              # entirely so we can run occ maintenance:install with argv quoting
              # (the entrypoint's install path is eval-prone for passwords
              # containing $<digit> — see Phase 2 progress notes).
              cd /var/www/html
              if [ ! -f version.php ]; then
                echo "Copying Nextcloud source into /var/www/html..."
                cp -a /usr/src/nextcloud/. .
                chown -R www-data:www-data /var/www/html
              fi

              # 3. If config.php already reports installed=true (re-run against
              # an already-installed DB), skip the install step. The Job is
              # idempotent.
              if su -p www-data -s /bin/sh -c "php /var/www/html/occ status --output=json 2>/dev/null" \
                   | grep -q '"installed":true'; then
                echo "Nextcloud is already installed; skipping maintenance:install"
              else
                echo "Running occ maintenance:install (DB=$POSTGRES_DB user=$POSTGRES_USER)..."
                # IMPORTANT: pass each value as its own argv element via the
                # bash array. PHP receives the values directly through execve;
                # there is no second shell-parsing pass over the password.
                INSTALL_ARGS=(
                  --database=pgsql
                  --database-host="$POSTGRES_HOST"
                  --database-name="$POSTGRES_DB"
                  --database-user="$POSTGRES_USER"
                  --database-pass="$POSTGRES_PASSWORD"
                  --admin-user="$NEXTCLOUD_ADMIN_USER"
                  --admin-pass="$NEXTCLOUD_ADMIN_PASSWORD"
                )
                # su -p preserves the env so the password ends up in the
                # invoked-process env (via -E), but we instead pass through
                # runuser to keep argv intact across the privilege drop.
                runuser -u www-data -- php /var/www/html/occ maintenance:install "${INSTALL_ARGS[@]}"
                echo "occ maintenance:install completed successfully"
              fi

              # 4. Extract identity values from config.php. Done via php so the
              # values never end up in shell variables that might leak into a
              # crash dump or pod logs (the variables here are kept local and
              # POSTed straight to the API).
              extract() {
                runuser -u www-data -- php -r "
                  \$CONFIG = [];
                  require '/var/www/html/config/config.php';
                  echo \$CONFIG['$1'];
                "
              }
              INSTANCEID=$(extract instanceid)
              PASSWORDSALT=$(extract passwordsalt)
              SECRET=$(extract secret)

              if [ -z "$INSTANCEID" ] || [ -z "$PASSWORDSALT" ] || [ -z "$SECRET" ]; then
                echo "ERROR: failed to extract identity values from config.php"
                exit 1
              fi
              echo "Identity extracted: instanceid=${INSTANCEID:0:6}... (values not logged)"

              # 5. POST the nextcloud-identity Secret to the Kubernetes API
              # using the pod's ServiceAccount token. This keeps the identity
              # values OUT of pod logs (we never echo them) and out of the Job
              # spec (no envFrom). Idempotent via PUT-after-409.
              TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
              API=https://kubernetes.default.svc

              b64() { printf '%s' "$1" | base64 -w0; }

              SECRET_JSON=$(cat <<EOF
              {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": "nextcloud-identity", "namespace": "$NAMESPACE"},
                "type": "Opaque",
                "data": {
                  "instanceid":   "$(b64 "$INSTANCEID")",
                  "passwordsalt": "$(b64 "$PASSWORDSALT")",
                  "secret":       "$(b64 "$SECRET")"
                }
              }
              EOF
              )

              CREATE_URL="$API/api/v1/namespaces/$NAMESPACE/secrets"
              CODE=$(curl -sSk -o /tmp/api-out.json -w '%{http_code}' \
                       -X POST \
                       -H "Authorization: Bearer $TOKEN" \
                       -H "Content-Type: application/json" \
                       --cacert "$CACERT" \
                       --data "$SECRET_JSON" \
                       "$CREATE_URL")
              if [ "$CODE" = "201" ]; then
                echo "Created Secret nextcloud-identity"
              elif [ "$CODE" = "409" ]; then
                # Already exists; replace it via PUT so we converge on the
                # current identity (this should be rare — deploy script skips
                # the Job when the Secret exists, but guard anyway).
                PUT_URL="$API/api/v1/namespaces/$NAMESPACE/secrets/nextcloud-identity"
                CODE=$(curl -sSk -o /tmp/api-out.json -w '%{http_code}' \
                         -X PUT \
                         -H "Authorization: Bearer $TOKEN" \
                         -H "Content-Type: application/json" \
                         --cacert "$CACERT" \
                         --data "$SECRET_JSON" \
                         "$PUT_URL")
                if [ "$CODE" = "200" ]; then
                  echo "Replaced existing Secret nextcloud-identity"
                else
                  echo "ERROR: failed to replace nextcloud-identity (HTTP $CODE)"
                  cat /tmp/api-out.json
                  exit 1
                fi
              else
                echo "ERROR: failed to create nextcloud-identity (HTTP $CODE)"
                cat /tmp/api-out.json
                exit 1
              fi

              echo "=== Install Job complete ==="
