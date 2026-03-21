#!/bin/bash
# Shared Cloudflare DNS management functions
#
# Requires:
#   TF_VAR_cloudflare_api_token — Cloudflare API token
#   TF_VAR_cloudflare_zone_id   — Cloudflare zone ID
#
# Used by: scripts/manage-dns.sh, scripts/create_env

# Create or update a Cloudflare DNS record
# Args: record_name record_type record_content [proxied]
# proxied: "true" to enable Cloudflare proxy (orange cloud), default "false"
create_dns_record() {
  local record_name="$1"
  local record_type="$2"
  local record_content="$3"
  local proxied="${4:-false}"
  local ttl=300

  # Cloudflare requires ttl=1 (automatic) when proxied is enabled
  if [ "$proxied" = "true" ]; then
    ttl=1
  fi

  # Check if record of the same type exists
  EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records?name=${record_name}&type=${record_type}" \
    -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
    -H "Content-Type: application/json")

  RECORD_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')

  if [ -z "$RECORD_ID" ]; then
    # No record of the same type — check for a conflicting record of a different type
    CONFLICTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records?name=${record_name}" \
      -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
      -H "Content-Type: application/json")
    CONFLICT_ID=$(echo "$CONFLICTING" | jq -r '.result[0].id // empty')
    CONFLICT_TYPE=$(echo "$CONFLICTING" | jq -r '.result[0].type // empty')

    if [ -n "$CONFLICT_ID" ] && [ "$CONFLICT_TYPE" != "$record_type" ]; then
      print_status "Removing conflicting ${CONFLICT_TYPE} record for $record_name (replacing with ${record_type})"
      curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records/${CONFLICT_ID}" \
        -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
        -H "Content-Type: application/json" >/dev/null
    fi
  fi

  if [ -n "$RECORD_ID" ]; then
    # Update existing record (same type)
    RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records/${RECORD_ID}" \
      -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"${record_type}\",\"name\":\"${record_name}\",\"content\":\"${record_content}\",\"ttl\":${ttl},\"proxied\":${proxied}}")
    if echo "$RESULT" | jq -e '.success' >/dev/null 2>&1; then
      print_status "Updated DNS: $record_name -> $record_content (proxied=$proxied)"
    else
      print_error "Failed to update DNS: $record_name — $(echo "$RESULT" | jq -r '.errors[0].message // "unknown error"')"
    fi
  else
    # Create new record
    RESULT=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records" \
      -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"${record_type}\",\"name\":\"${record_name}\",\"content\":\"${record_content}\",\"ttl\":${ttl},\"proxied\":${proxied}}")
    if echo "$RESULT" | jq -e '.success' >/dev/null 2>&1; then
      print_status "Created DNS: $record_name -> $record_content (proxied=$proxied)"
    else
      print_error "Failed to create DNS: $record_name — $(echo "$RESULT" | jq -r '.errors[0].message // "unknown error"')"
    fi
  fi
}

# Create or update a Cloudflare SRV record
# Args: srv_service srv_proto srv_domain srv_priority srv_weight srv_port srv_target
create_srv_record() {
  local srv_service="$1"   # e.g., "_imaps"
  local srv_proto="$2"     # e.g., "_tcp"
  local srv_domain="$3"    # e.g., "example.com"
  local srv_priority="$4"  # e.g., 0
  local srv_weight="$5"    # e.g., 1
  local srv_port="$6"      # e.g., 993
  local srv_target="$7"    # e.g., "mail.example.com"

  local record_name="${srv_service}.${srv_proto}.${srv_domain}"

  EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records?name=${record_name}&type=SRV" \
    -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
    -H "Content-Type: application/json")

  RECORD_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')

  local srv_data="{\"type\":\"SRV\",\"name\":\"${record_name}\",\"data\":{\"service\":\"${srv_service}\",\"proto\":\"${srv_proto}\",\"name\":\"${srv_domain}\",\"priority\":${srv_priority},\"weight\":${srv_weight},\"port\":${srv_port},\"target\":\"${srv_target}\"},\"ttl\":300}"

  if [ -n "$RECORD_ID" ]; then
    RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records/${RECORD_ID}" \
      -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
      -H "Content-Type: application/json" \
      --data "$srv_data")
    if echo "$RESULT" | jq -e '.success' >/dev/null 2>&1; then
      print_status "Updated SRV: ${record_name} -> ${srv_target}:${srv_port}"
    else
      local err_msg
      err_msg=$(echo "$RESULT" | jq -r '.errors[0].message // "unknown error"')
      if echo "$err_msg" | grep -qi "identical record already exists"; then
        print_status "SRV unchanged: ${record_name} -> ${srv_target}:${srv_port}"
      else
        print_error "Failed to update SRV: ${record_name} — $err_msg"
      fi
    fi
  else
    RESULT=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records" \
      -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
      -H "Content-Type: application/json" \
      --data "$srv_data")
    if echo "$RESULT" | jq -e '.success' >/dev/null 2>&1; then
      print_status "Created SRV: ${record_name} -> ${srv_target}:${srv_port}"
    else
      local err_msg
      err_msg=$(echo "$RESULT" | jq -r '.errors[0].message // "unknown error"')
      if echo "$err_msg" | grep -qi "identical record already exists"; then
        print_status "SRV already exists: ${record_name} -> ${srv_target}:${srv_port}"
      else
        print_error "Failed to create SRV: ${record_name} — $err_msg"
      fi
    fi
  fi
}

# Create or update a Cloudflare MX record
# Args: record_name mx_content priority
create_mx_record() {
  local record_name="$1"
  local mx_content="$2"
  local priority="${3:-10}"

  EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records?name=${record_name}&type=MX" \
    -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
    -H "Content-Type: application/json")

  RECORD_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')

  local mx_data="{\"type\":\"MX\",\"name\":\"${record_name}\",\"content\":\"${mx_content}\",\"priority\":${priority},\"ttl\":300}"

  if [ -n "$RECORD_ID" ]; then
    RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records/${RECORD_ID}" \
      -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
      -H "Content-Type: application/json" \
      --data "$mx_data")
    if echo "$RESULT" | jq -e '.success' >/dev/null 2>&1; then
      print_status "Updated MX: ${record_name} -> ${mx_content} (priority=$priority)"
    else
      print_error "Failed to update MX: ${record_name} — $(echo "$RESULT" | jq -r '.errors[0].message // "unknown error"')"
    fi
  else
    RESULT=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${TF_VAR_cloudflare_zone_id}/dns_records" \
      -H "Authorization: Bearer ${TF_VAR_cloudflare_api_token}" \
      -H "Content-Type: application/json" \
      --data "$mx_data")
    if echo "$RESULT" | jq -e '.success' >/dev/null 2>&1; then
      print_status "Created MX: ${record_name} -> ${mx_content} (priority=$priority)"
    else
      print_error "Failed to create MX: ${record_name} — $(echo "$RESULT" | jq -r '.errors[0].message // "unknown error"')"
    fi
  fi
}

# Set Linode reverse DNS (PTR) for an IP address
# Args: ip_address rdns_hostname
# Linode requires forward DNS to resolve first
set_linode_rdns() {
  local ip_address="$1"
  local rdns_hostname="$2"

  # Check current rDNS
  CURRENT_RDNS=$(curl -s "https://api.linode.com/v4/networking/ips/${ip_address}" \
    -H "Authorization: Bearer ${TF_VAR_linode_token}" | jq -r '.rdns // empty')

  if [ "$CURRENT_RDNS" = "$rdns_hostname" ]; then
    print_status "rDNS already set: $ip_address -> $rdns_hostname"
    return 0
  fi

  RESULT=$(curl -s -X PUT "https://api.linode.com/v4/networking/ips/${ip_address}" \
    -H "Authorization: Bearer ${TF_VAR_linode_token}" \
    -H "Content-Type: application/json" \
    -d "{\"rdns\": \"${rdns_hostname}\"}")

  if echo "$RESULT" | jq -e '.rdns' >/dev/null 2>&1; then
    print_status "Set rDNS: $ip_address -> $rdns_hostname"
  else
    local err_msg
    err_msg=$(echo "$RESULT" | jq -r '.errors[0].reason // "unknown error"')
    print_error "Failed to set rDNS for $ip_address — $err_msg"
    print_error "Ensure forward DNS ($rdns_hostname) resolves to $ip_address first"
  fi
}
