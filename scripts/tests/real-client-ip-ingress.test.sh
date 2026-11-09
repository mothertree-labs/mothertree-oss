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
ok "no per-port PROXY opt-out on the NodeBalancer (port 25 included)" \
   '[ "$(yq ".controller.service.annotations | keys | map(select(test(\"linode-loadbalancer-port-\"))) | length" "$V")" = 0 ]'
# Port 25: nginx decodes the NodeBalancer's PROXY header and re-sends it to
# Postfix's 10025 listener. Both deploy_infra sites (pre-sync migration and the
# late patch) must use the same entry, or a deploy flips 25 back to plain.
D="$R/scripts/deploy_infra"
ok "tcp-services 25 entry is postfix:10025, decode + re-send PROXY" \
   'grep -qx "MT_SMTP_INBOUND_TCP_SERVICE=\"infra-mail/postfix:10025:PROXY:PROXY\"" "$D"'
ok "pre-sync migration points 25 at MT_SMTP_INBOUND_TCP_SERVICE" \
   'grep -q "jq --arg smtp \"\$MT_SMTP_INBOUND_TCP_SERVICE\"" "$D" && grep -q "if .key == \"25\" then .value = \$smtp" "$D"'
ok "late patch writes MT_SMTP_INBOUND_TCP_SERVICE for 25" \
   'grep -q "jq -cn --arg v \"\$MT_SMTP_INBOUND_TCP_SERVICE\" '"'"'{data: {\"25\": \$v}}'"'"'" "$D"'
ok "no plain postfix:25 tcp-services entry left in deploy_infra" \
   '! grep -q "infra-mail/postfix:25\"" "$D"'
ok "pre-sync migration runs before the tier=system helmfile sync" \
   '[ "$(grep -n "^MT_SMTP_INBOUND_TCP_SERVICE=" "$D" | cut -d: -f1)" -lt "$(grep -n "helmfile -e \"\$MT_ENV\" -l tier=system sync" "$D" | head -1 | cut -d: -f1)" ]'
# Trust list: only peers that may assert the client address in a PROXY header.
CIDR=$(yq '.controller.config["proxy-real-ip-cidr"]' "$V")
ok "prod trust list includes the NodeBalancer backend range" \
   'printf "%s" "$CIDR" | tr , "\n" | grep -qx 192.168.255.0/24'
ok "prod trust list has no pod/node/RFC1918 catch-alls" \
   '! printf "%s" "$CIDR" | tr , "\n" | grep -qE "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.0\.0/16)"'
ok "Cloudflare IPv4 reference ranges are all trusted" \
   '! grep -v "^#" "$R/scripts/cloudflare-ips-v4.txt" | grep . | while read -r c; do printf "%s" "$CIDR" | tr , "\n" | grep -qx "$c" || echo "$c"; done | grep -q .'
ok "devhome trusts only the k3d gateway" \
   '[ "$(yq ".controller.config[\"proxy-real-ip-cidr\"]" "$R/apps/environments/dev/ingress-nginx.yaml.gotmpl")" = 172.28.0.1/32 ]'
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
