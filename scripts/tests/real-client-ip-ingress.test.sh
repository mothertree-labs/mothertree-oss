#!/usr/bin/env bash
# Tripwire for the real-client-IP chain (NodeBalancer PROXY -> ingress-nginx ->
# Postfix PROXY listener). Each link alone looks harmless to change, but
# reverting any one of them silently loses the sender IP again (Local) or
# opens a forged-IP hole (the 10025 NetworkPolicy). Static checks, no cluster.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
V="$R/apps/values/ingress-nginx.yaml"
ok "public ingress Service is externalTrafficPolicy: Local" \
   '[ "$(yq ".controller.service.externalTrafficPolicy" "$V")" = Local ]'
ok "NodeBalancer PROXY v2 is the default" \
   '[ "$(yq ".controller.service.annotations[\"service.beta.kubernetes.io/linode-loadbalancer-default-proxy-protocol\"]" "$V")" = v2 ]'
# Port 25 PROXY end to end (no NodeBalancer opt-out; tcp-services 25 ->
# infra-mail/postfix:10025:PROXY:PROXY) lands in the follow-up; until then the
# 10025 listener exists but receives no traffic.
M="$R/apps/manifests/postfix/10-master-cf-overrides.sh"
ok "Postfix 10025 listener exists" 'grep -q "^postconf -M \"10025/inet=10025 inet" "$M"'
ok "10025 requires the PROXY header" 'grep -q "10025/inet/smtpd_upstream_proxy_protocol=haproxy" "$M"'
ok "10025 keeps port 25 recipient restrictions" 'grep -q "10025/inet/smtpd_recipient_restrictions=reject_unverified_recipient,reject_unauth_destination" "$M"'
ok "10025 keeps port 25 relay restrictions" 'grep -q "10025/inet/smtpd_relay_restrictions=reject_unauth_destination" "$M"'
NP="$R/apps/manifests/postfix/networkpolicy.yaml.tpl"
ok "10025 reachable only from the public controller pods" \
   '[ "$(NS_MAIL=m NS_INGRESS=infra-ingress envsubst < "$NP" | yq -o=json | jq -r "[.spec.ingress[] | select(any(.ports[]; .port == 10025))] | length == 1 and (.[0].from | length) == 1 and .[0].from[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"] == \"infra-ingress\" and .[0].from[0].podSelector.matchLabels[\"app.kubernetes.io/component\"] == \"controller\" and .[0].from[0].podSelector.matchLabels[\"app.kubernetes.io/instance\"] == \"ingress-nginx\"")" = true ]'
ok "port 25 rule does not also open 10025" \
   '[ "$(NS_MAIL=m NS_INGRESS=infra-ingress envsubst < "$NP" | yq -o=json | jq -r "[.spec.ingress[] | select((.from // []) | length == 0) | .ports[].port] | index(10025) == null")" = true ]'
ok "postfix Service exposes 10025" \
   '[ "$(NS_MAIL=m envsubst < "$R/apps/manifests/postfix/service-smtp.yaml.tpl" | yq ".spec.ports[] | select(.port == 10025) | .targetPort")" = 10025 ]'
ok "netpol is rendered with NS_INGRESS" \
   'grep -q "envsubst '"'"'\${NS_MAIL} \${NS_INGRESS}'"'"' < \"\$MANIFESTS_DIR/networkpolicy.yaml.tpl\"" "$R/apps/deploy-postfix.sh"'
echo "real-client-ip-ingress: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
