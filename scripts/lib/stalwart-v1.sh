#!/usr/bin/env bash
# Stalwart v1 deployment and the one-time 0.15 → v1 migration (#715).
# Sourced by apps/deploy-stalwart.sh after config.sh / common.sh.
#
# Migration invariants (see apps/manifests/stalwart/migrate/):
#   * The live 0.15 database (STALWART_DB_NAME) is only ever read. Hop 1 runs
#     on a scratch copy; v1 writes only STALWART_V1_DB_NAME. Until v1 has
#     accepted mail, rolling back is "scale 0.15 up again".
#   * Migration output holds the OAuth signing key and DKIM/TLS keys. Nothing
#     here runs `kubectl logs` on a migration Job; only each container's
#     one-line termination message is printed.
#   * prod migrates only with STALWART_MIGRATE_CONFIRM=yes.

# Pinned upstream hop-1 converter (verified 2026-11-24).
STALWART_MIGRATE_V016_URL="https://raw.githubusercontent.com/stalwartlabs/stalwart/v0.16.27/resources/scripts/migrate_v016.py"
STALWART_MIGRATE_V016_SHA256="ebc7c2cc8b3d9378476523ee5fd76c39b1bc0e788a890ff17b507b03c0757458"

# v1 | v015 | none — which Stalwart the tenant runs now.
mt_stalwart_generation() {
    local gen image
    if ! kubectl get deployment stalwart -n "$NS_MAIL" >/dev/null 2>&1; then
        echo none
        return
    fi
    gen=$(kubectl get deployment stalwart -n "$NS_MAIL" -o jsonpath='{.metadata.labels.stalwart\.mothertree/generation}')
    image=$(kubectl get deployment stalwart -n "$NS_MAIL" -o jsonpath='{.spec.template.spec.containers[0].image}')
    if [ "$gen" = "v1" ]; then
        echo v1
    elif [[ "$image" == *":v0.15."* ]]; then
        echo v015
    else
        print_error "Unrecognised Stalwart deployment in $NS_MAIL (image $image, generation '${gen}')" >&2
        return 1
    fi
}

# Print the termination message of every container of a Job's pod (init
# containers included). Never the logs.
_mt_stalwart_job_status() {
    local job="$1"
    kubectl get pods -n "$NS_MAIL" -l "job-name=$job" -o json 2>/dev/null | jq -r '
        .items[0] // empty
        | ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
        | "  [\(.name)] " + (
            (.state.terminated // .lastState.terminated) as $t
            | if $t then (($t.message // "") | gsub("\n"; " ") | .[0:400]) + " (exit \($t.exitCode))"
              elif .state.running then "running"
              else "waiting: \(.state.waiting.reason // "?")" end)'
}

# _mt_stalwart_run_job <job-name> <template> <timeout-seconds>
# Recreates the Job from the template (envsubst on the current env), waits for
# it to finish, prints its status lines. Returns non-zero on failure/timeout.
_mt_stalwart_run_job() {
    local job="$1" tpl="$2" timeout="$3" i state=""
    kubectl delete job "$job" -n "$NS_MAIL" --ignore-not-found --wait=true >/dev/null
    envsubst < "$tpl" | kubectl create -f - >/dev/null
    print_status "Job $job started (timeout ${timeout}s)"
    for ((i = 0; i < timeout; i += 5)); do
        state=$(kubectl get job "$job" -n "$NS_MAIL" -o json | jq -r '
            [.status.conditions[]? | select(.status == "True") | .type] as $c
            | if ($c | index("Complete")) then "complete"
              elif ($c | index("Failed")) then "failed" else "running" end')
        [ "$state" != running ] && break
        sleep 5
    done
    _mt_stalwart_job_status "$job"
    if [ "$state" = complete ]; then
        return 0
    fi
    print_error "Job $job did not complete (state: ${state:-unknown})"
    return 1
}

_mt_stalwart_scripts_configmap() {
    local d="$REPO_ROOT/apps/manifests/stalwart/migrate"
    kubectl create configmap stalwart-migrate-scripts -n "$NS_MAIL" \
        --from-file="$d/dump.sh" --from-file="$d/copy.sh" --from-file="$d/v016-recovery.sh" \
        --from-file="$d/stop-v016.sh" --from-file="$d/migrate.sh" --from-file="$d/answers.toml" \
        --from-file="$d/patch_v016_secrets.py" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

_mt_stalwart_wait_no_pods() {
    local i
    for i in $(seq 1 120); do
        if [ -z "$(kubectl get pods -n "$NS_MAIL" -l app=stalwart -o name 2>/dev/null)" ]; then
            return 0
        fi
        sleep 2
    done
    print_error "Stalwart pods still present after 240s"
    return 1
}

# Restore 0.15 after a failed migration step. Safe because the live 0.15
# database was never written.
_mt_stalwart_restore_v015() {
    print_warning "Restoring Stalwart 0.15 (its database was not modified)"
    kubectl scale deployment stalwart -n "$NS_MAIL" --replicas="$STALWART_MIN_REPLICAS" >/dev/null || true
    if [ "$STALWART_MIN_REPLICAS" != "$STALWART_MAX_REPLICAS" ]; then
        envsubst < "$REPO_ROOT/apps/manifests/stalwart/stalwart-hpa.yaml.tpl" | kubectl apply -f - >/dev/null || true
    fi
    kubectl rollout status deployment/stalwart -n "$NS_MAIL" --timeout=300s || true
}

# The one-time migration. Returns 0 when the v1 database holds the migrated
# store; on failure 0.15 is running again and it returns 1.
mt_stalwart_v1_migrate() {
    : "${STALWART_SCRATCH_DB_NAME:?}" "${STALWART_V1_DB_NAME:?}" "${STALWART_DB_NAME:?}"
    export STALWART_SCRATCH_DB_NAME
    export MIGRATE_V016_URL="$STALWART_MIGRATE_V016_URL" MIGRATE_V016_SHA256="$STALWART_MIGRATE_V016_SHA256"
    # dev-class data is disposable: a half-written v1 DB from an earlier
    # attempt is recreated. prod refuses instead (copy.sh).
    if mt_is_dev_class; then
        export STALWART_RESET_V1=yes
    else
        export STALWART_RESET_V1=no
    fi

    print_status "Stalwart 0.15 → v1 migration for $MT_TENANT (#715)"
    _mt_stalwart_scripts_configmap
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: stalwart-migration
  namespace: ${NS_MAIL}
  labels:
    app.kubernetes.io/name: stalwart
    app.kubernetes.io/component: migrate
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
EOF

    # Job 1 against the running 0.15: no mail outage yet.
    if ! _mt_stalwart_run_job stalwart-migrate-dump \
            "$REPO_ROOT/apps/manifests/stalwart/migrate/dump-job.yaml.tpl" 900; then
        print_error "Export from Stalwart 0.15 failed; 0.15 keeps running, nothing changed"
        return 1
    fi

    # Mail outage starts: inbound waits in Postfix's queue (connect failures
    # are temporary errors there), clients see connection refused.
    print_status "Stopping Stalwart 0.15 (mail outage begins; Postfix queues inbound mail)"
    kubectl delete hpa stalwart-hpa -n "$NS_MAIL" --ignore-not-found >/dev/null
    kubectl scale deployment stalwart -n "$NS_MAIL" --replicas=0 >/dev/null
    if ! _mt_stalwart_wait_no_pods; then
        _mt_stalwart_restore_v015
        return 1
    fi

    if ! _mt_stalwart_run_job stalwart-migrate \
            "$REPO_ROOT/apps/manifests/stalwart/migrate/migrate-job.yaml.tpl" 2700; then
        print_error "Migration failed; see the status lines above"
        _mt_stalwart_restore_v015
        return 1
    fi

    kubectl create configmap stalwart-v1-migration -n "$NS_MAIL" \
        --from-literal=state=done --from-literal=at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --from-literal=summary="$(_mt_stalwart_job_status stalwart-migrate | tail -1)" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    # The volume holds the converted export (OAuth signing key, DKIM keys).
    kubectl delete job stalwart-migrate-dump stalwart-migrate -n "$NS_MAIL" --ignore-not-found --wait=true >/dev/null
    kubectl delete pvc stalwart-migration -n "$NS_MAIL" --ignore-not-found >/dev/null
    print_success "Migration complete; v1 store is in $STALWART_V1_DB_NAME"
}

# Wait until at least one Stalwart pod's container has started (it may not be
# Ready: a fresh store has no 588 listener until the plan is applied).
_mt_stalwart_wait_started() {
    local i
    for i in $(seq 1 90); do
        if kubectl get pods -n "$NS_MAIL" -l app=stalwart -o json \
                | jq -e '[.items[] | select(.metadata.deletionTimestamp == null)
                          | .status.containerStatuses[]? | select(.started == true)] | length > 0' >/dev/null; then
            return 0
        fi
        sleep 5
    done
    print_error "No Stalwart v1 pod started within 450s"
    dump_pod_diagnostics "$NS_MAIL" "app=stalwart" || true
    return 1
}

# Deploy or update Stalwart v1: manifest, config plan, roll on plan change.
# Args: [first-boot-after-migration]
mt_stalwart_v1_deploy() {
    local after_migration="${1:-}"
    source "$REPO_ROOT/scripts/lib/stalwart-v1-plan.sh"

    # OIDC discovery needs the public auth host via the internal ingress.
    INTERNAL_INGRESS_IP=$(kubectl get svc ingress-nginx-internal-controller -n "$NS_INGRESS_INTERNAL" \
        -o jsonpath='{.spec.clusterIP}')
    : "${INTERNAL_INGRESS_IP:?internal ingress controller has no ClusterIP}"
    export INTERNAL_INGRESS_IP
    kubectl apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak-internal-${MT_TENANT}
  namespace: ${NS_AUTH}
  labels:
    app: keycloak
    tenant: ${MT_TENANT}
    purpose: internal-oidc
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
spec:
  ingressClassName: nginx-internal
  rules:
  - host: ${AUTH_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: keycloak-keycloakx-http
            port:
              name: http
  tls:
  - hosts:
    - ${AUTH_HOST}
    secretName: wildcard-tls-${MT_TENANT}
EOF

    export STALWART_REDIS_URL="redis://:${STALWART_REDIS_PASSWORD:?}@stalwart-redis.${NS_MAIL}.svc.cluster.local:6379/0"
    # info everywhere: v1 has no "curated subset" like 0.15's legacy
    # [tracing] block, and dev's e2e diagnostics need delivery events.
    export STALWART_V1_TRACE_LEVEL=info
    local plan
    plan=$(mt_stalwart_v1_plan) || return 1
    local plan_sum
    plan_sum=$(printf '%s' "$plan" | sha256sum | cut -c1-16)
    kubectl create secret generic stalwart-v1-plan -n "$NS_MAIL" \
        --from-file=plan.ndjson=<(printf '%s\n' "$plan") --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Keep the running pods' checksum while the plan goes in, so applying
    # the manifest does not roll pods that would load the old settings.
    local live_sum
    live_sum=$(kubectl get deployment stalwart -n "$NS_MAIL" \
        -o jsonpath='{.spec.template.metadata.annotations.checksum/plan}' 2>/dev/null || true)
    if [ "$(mt_stalwart_generation)" != v1 ]; then
        live_sum=bootstrap
    fi
    export STALWART_PLAN_CHECKSUM="${live_sum:-bootstrap}"
    envsubst < "$REPO_ROOT/apps/manifests/stalwart/stalwart-v1.yaml.tpl" | kubectl apply -f - >/dev/null
    _mt_stalwart_wait_started || return 1

    if ! _mt_stalwart_run_job stalwart-v1-plan "$REPO_ROOT/apps/manifests/stalwart/plan-job.yaml.tpl" 300; then
        print_error "Applying the Stalwart v1 configuration plan failed"
        return 1
    fi

    # Listener, store and coordinator changes need a restart: roll when the
    # plan changed (first boot always does: "bootstrap" never matches).
    export STALWART_PLAN_CHECKSUM="$plan_sum"
    envsubst < "$REPO_ROOT/apps/manifests/stalwart/stalwart-v1.yaml.tpl" | kubectl apply -f - >/dev/null

    if [ "$after_migration" = first-boot-after-migration ]; then
        # Default roles created by 0.16 lack the v1.1/v1.2 permissions. One
        # boot with this flag adds them (and makes upstream's rollback tool
        # unusable from here on; rollback = restore the 0.15 database).
        kubectl set env deployment/stalwart -n "$NS_MAIL" STALWART_UPDATE_ROLE_PERMISSIONS=true >/dev/null
        kubectl rollout status deployment/stalwart -n "$NS_MAIL" --timeout=300s || return 1
        kubectl set env deployment/stalwart -n "$NS_MAIL" STALWART_UPDATE_ROLE_PERMISSIONS- >/dev/null
    fi
    kubectl rollout status deployment/stalwart -n "$NS_MAIL" --timeout=300s || return 1

    if [ "$STALWART_MIN_REPLICAS" != "$STALWART_MAX_REPLICAS" ]; then
        envsubst < "$REPO_ROOT/apps/manifests/stalwart/stalwart-hpa.yaml.tpl" | kubectl apply -f - >/dev/null
    else
        kubectl delete hpa stalwart-hpa -n "$NS_MAIL" --ignore-not-found >/dev/null
    fi
}
