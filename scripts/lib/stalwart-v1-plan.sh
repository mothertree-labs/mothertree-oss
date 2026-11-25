#!/usr/bin/env bash
# Stalwart v1 configuration plan (#715).
#
# Stalwart v1 has no TOML: config.json names only the data store, and every
# other setting is a JMAP object. This renders the NDJSON plan that
# deploy-stalwart.sh applies with `stalwart-cli apply` (stalwartlabs/cli).
# Applying it twice changes nothing (upsert/reconcile/update only).
#
# Shapes were verified against stalwartlabs/stalwart:v1.2.0 in the 2026-11-24
# rehearsal. Secrets appear only as {"@type":"EnvironmentVariable"} references
# resolved inside the Stalwart pod, EXCEPT the Redis URL: v1's single-node
# Redis store has no secret-typed field, so its password is rendered in, and
# the plan must be stored as a Secret, never a ConfigMap or a log line.
#
# Usage: mt_stalwart_v1_plan > plan.ndjson
# Required env: EMAIL_DOMAIN MAIL_HOST AUTH_HOST TENANT_KEYCLOAK_REALM
#   S3_MAIL_BUCKET S3_CLUSTER S3_INTERNAL_ENDPOINT STALWART_V1_ROUTE
#   STALWART_V1_TRACE_LEVEL STALWART_REDIS_URL
# STALWART_V1_ROUTE is one of:
#   ses                 relay to $SES_SMTP_ENDPOINT:587 as $SES_SMTP_USERNAME,
#                       password from env SES_SMTP_PASSWORD in the pod
#   relay:<host>:<port>:<allow-invalid-certs true|false>
#                       unauthenticated smart host (devbox Mailpit, tailnet relay)
#   mx                  direct MX delivery

mt_stalwart_v1_plan() {
    local v
    for v in EMAIL_DOMAIN MAIL_HOST AUTH_HOST TENANT_KEYCLOAK_REALM S3_MAIL_BUCKET \
             S3_CLUSTER S3_INTERNAL_ENDPOINT STALWART_V1_ROUTE STALWART_V1_TRACE_LEVEL \
             STALWART_REDIS_URL; do
        if [ -z "${!v:-}" ]; then
            echo "[ERROR] mt_stalwart_v1_plan: $v is not set" >&2
            return 1
        fi
    done

    local route_name route_obj
    case "$STALWART_V1_ROUTE" in
        ses)
            : "${SES_SMTP_ENDPOINT:?SES route needs SES_SMTP_ENDPOINT}"
            : "${SES_SMTP_USERNAME:?SES route needs SES_SMTP_USERNAME}"
            route_name=relay
            route_obj=$(jq -nc --arg host "$SES_SMTP_ENDPOINT" --arg user "$SES_SMTP_USERNAME" '{
                "@type":"Relay", name:"relay", description:"AWS SES (SASL, STARTTLS)",
                host:$host, port:587, protocol:"smtp", implicitTls:false, allowInvalidCerts:false,
                authUsername:$user,
                authSecret:{"@type":"EnvironmentVariable", variableName:"SES_SMTP_PASSWORD"}}')
            ;;
        relay:*)
            local host port insecure
            IFS=: read -r _ host port insecure <<<"$STALWART_V1_ROUTE"
            if [ -z "$host" ] || ! [[ "$port" =~ ^[0-9]+$ ]] || ! [[ "$insecure" =~ ^(true|false)$ ]]; then
                echo "[ERROR] mt_stalwart_v1_plan: bad STALWART_V1_ROUTE '$STALWART_V1_ROUTE'" >&2
                return 1
            fi
            route_name=relay
            route_obj=$(jq -nc --arg host "$host" --argjson port "$port" --argjson insecure "$insecure" '{
                "@type":"Relay", name:"relay", description:"Smart host (unauthenticated)",
                host:$host, port:$port, protocol:"smtp", implicitTls:false, allowInvalidCerts:$insecure}')
            ;;
        mx)
            route_name=mx
            route_obj=""
            ;;
        *)
            echo "[ERROR] mt_stalwart_v1_plan: unknown STALWART_V1_ROUTE '$STALWART_V1_ROUTE'" >&2
            return 1
            ;;
    esac

    jq -nc \
        --arg domain "$EMAIL_DOMAIN" --arg host "$MAIL_HOST" \
        --arg issuer "https://${AUTH_HOST}/realms/${TENANT_KEYCLOAK_REALM}" \
        --arg bucket "$S3_MAIL_BUCKET" --arg s3region "$S3_CLUSTER" --arg s3url "$S3_INTERNAL_ENDPOINT" \
        --arg trace "$STALWART_V1_TRACE_LEVEL" --arg route "$route_name" \
        --arg routeexpr "'${route_name}'" --arg localexpr "'local'" \
        --arg redis "$STALWART_REDIS_URL" --arg routeobj "$route_obj" '
      def env(v): {"@type":"EnvironmentVariable", variableName:v};
      def expr(e; m): {else:e, match:m};
      def listener(n; port; proto; tls; implicit):
        {("l-" + n): {name:n, bind:{("[::]:" + (port|tostring)):true}, protocol:proto, useTls:tls, implicitTls:implicit}};

      {"@type":"update", object:"BlobStore", value:{"@type":"S3", bucket:$bucket, timeout:30000,
        region:{"@type":"Custom", url:$s3url, region:$s3region},
        accessKeyId:env("S3_ACCESS_KEY"), secretKey:env("S3_SECRET_KEY")}},

      {"@type":"upsert", object:"Domain", matchOn:["name"],
        value:{dom:{name:$domain, dkimManagement:{"@type":"Manual"}}}},

      {"@type":"update", object:"SystemSettings", value:{defaultHostname:$host, defaultDomainId:"#dom"}},

      # 587/588 STARTTLS, 465/993/994/4190 implicit TLS, 443 plain HTTP behind
      # the ingress, 8080 plain HTTP for probes and management. Reconcile
      # removes the v1 defaults we do not run (pop3s 995, TLS on 443).
      {"@type":"reconcile", object:"NetworkListener", matchOn:["name"], value:(
        listener("smtp"; 25; "smtp"; true; false) +
        listener("submissions"; 465; "smtp"; true; true) +
        listener("submission"; 587; "smtp"; true; false) +
        listener("submission-app"; 588; "smtp"; true; false) +
        listener("imaps"; 993; "imap"; true; true) +
        listener("imaps-app"; 994; "imap"; true; true) +
        listener("sieve"; 4190; "manageSieve"; true; true) +
        listener("https"; 443; "http"; false; false) +
        listener("health"; 8080; "http"; false; false))},

      # cert-manager wildcard Secret mounted at /certs
      {"@type":"reconcile", object:"Certificate", matchOn:["certificate"], value:{cert:{
        certificate:{"@type":"File", filePath:"/certs/tls.crt"},
        privateKey:{"@type":"File", filePath:"/certs/tls.key"}}}},

      # Keycloak. Discovery runs against the PUBLIC issuer (it must equal the
      # token iss); the pod resolves AUTH_HOST to the internal ingress through
      # hostAliases. Tokens must carry aud=stalwart (stalwart-audience mapper
      # on the roundcube client).
      {"@type":"upsert", object:"Directory", matchOn:["description"], value:{kc:{"@type":"Oidc",
        description:"keycloak", issuerUrl:$issuer, claimUsername:"preferred_username", claimName:"name",
        usernameDomain:$domain, acceptedAudiences:{stalwart:true}, skipAudienceValidation:false,
        unscopedTokens:"interoperable", opaqueTokenValidation:"none"}}},
      {"@type":"update", object:"Authentication", value:{directoryId:"#kc"}},

      {"@type":"reconcile", object:"Tracer", matchOn:["@type"], value:{stdout:{"@type":"Stdout",
        level:$trace, ansi:false, enable:true}}},

      # Outbound: local domains delivered locally, everything else to $route.
      ( if $routeobj != "" then
          {"@type":"upsert", object:"MtaRoute", matchOn:["name"], value:{($route):($routeobj|fromjson)}}
        else empty end ),
      {"@type":"update", object:"MtaOutboundStrategy", value:{route:expr($routeexpr;
        {"0":{if:"is_local_domain(rcpt_domain)", then:$localexpr}})}},

      # SES signs outbound (Easy DKIM); Stalwart must not.
      {"@type":"update", object:"MtaStageData", value:{dkimSignDomain:expr("false"; {})}},

      # Inbound only ever arrives from cluster Postfix/nginx on pod IPs.
      {"@type":"update", object:"SenderAuth", value:{reverseIpVerify:expr("disable"; {}),
        spfEhloVerify:expr("disable"; {}), spfFromVerify:expr("disable"; {}),
        dkimVerify:expr("relaxed"; {}), dmarcVerify:expr("relaxed"; {})}},
      {"@type":"upsert", object:"AllowedIp", matchOn:["address"], value:{
        ip0:{address:"10.0.0.0/8", reason:"cluster-internal"},
        ip1:{address:"172.16.0.0/12", reason:"cluster-internal"},
        ip2:{address:"192.168.0.0/16", reason:"cluster-internal"}}},
      {"@type":"upsert", object:"SpamTag", matchOn:["tag"], value:{
        forged_rcvd_trail:{"@type":"Score", tag:"FORGED_RCVD_TRAIL", score:0.0},
        helo_iprev_mismatch:{"@type":"Score", tag:"HELO_IPREV_MISMATCH", score:0.0},
        helo_nores_a_or_mx:{"@type":"Score", tag:"HELO_NORES_A_OR_MX", score:0.0}}},

      # Same as 0.15 ([queue.limiter.inbound.*] enable=false): every client is
      # Roundcube/Postfix behind one pod IP, so per-IP throttles only hurt.
      {"@type":"upsert", object:"MtaInboundThrottle", matchOn:["description"], value:{
        t_rcpt:{description:"Sender address to recipient throttle", enable:false},
        t_ip:{description:"Sender IP throttle", enable:false}}},

      # No startup downloads from GitHub: no ASN/Geo data, no web admin UI.
      {"@type":"update", object:"Asn", value:{"@type":"Disabled"}},
      {"@type":"upsert", object:"Application", matchOn:["description"], value:{
        webui:{description:"Stalwart Web Interface", enable:false}}},

      # HA: in-memory store first, then the coordinator (order matters; both
      # need a restart to take effect).
      {"@type":"update", object:"InMemoryStore", value:{"@type":"Redis", url:$redis}},
      {"@type":"update", object:"Coordinator", value:{"@type":"Redis", url:$redis}}
    '
}
