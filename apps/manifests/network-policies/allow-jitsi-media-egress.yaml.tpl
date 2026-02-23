# Allow Jitsi Media Egress (UDP + TURN)
# JVB requires UDP egress to arbitrary client IPs for ICE connectivity checks
# and RTP media delivery. Also allows TURN server access (STUN/TURN on 3478)
# for NAT traversal and the TURN health probe.
#
# Required environment variables:
#   NAMESPACE - Target namespace (must be the Jitsi namespace, e.g., tn-example-jitsi)
#
# Applied only to the Jitsi namespace by deploy-network-policies.sh

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-jitsi-media-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: network-policies
    policy-type: allow-jitsi-media
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # JVB needs UDP to any destination for ICE checks and media
    - ports:
        - protocol: UDP
    # TURN server TCP fallback (TURN over TCP on port 3478)
    - ports:
        - protocol: TCP
          port: 3478
        - protocol: TCP
          port: 5349
