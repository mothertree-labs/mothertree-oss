# devhome — a dev environment + CI host that runs on ONE box (a home server in
# the target design) behind a small public "periscope" node.
#
#   internet ── periscope (nanode, public IP, DNS points here)
#                  │  HAProxy L4 forward (PROXY v2) + UDP DNAT over Tailscale
#                  ▼
#               devhome box (k3d dev cluster + CI container + Postgres container)
#
# The box has no public ingress at all: everything arrives through the
# periscope over the dev tailnet, exactly as it will when the box sits behind
# a home router. `box_enabled` lets the same root manage the periscope alone
# once the box is a physical machine at home (the Linode box is the stand-in
# used to rehearse the move).
#
# State is local (like ci/terraform); keep tfvars in config/platform/devhome/.

terraform {
  required_version = ">= 1.0"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 4.0"
    }
  }
}

provider "linode" {
  token = var.linode_token
}

locals {
  operator_cidrs = [for ip in var.operator_ips : "${ip}/32"]
  # Public TCP ports the periscope forwards: HTTP(S), inbound MX, and the
  # per-tenant Stalwart ports (SMTPS / submission / IMAPS / app ports).
  periscope_tcp_ports = join(",", concat(["80", "443", "25"], [for p in var.mail_tcp_ports : tostring(p)]))
  periscope_udp_ports = join(",", [for p in var.media_udp_ports : tostring(p)])
}

resource "linode_firewall" "periscope" {
  label           = "${var.label_prefix}-periscope-fw"
  tags            = var.tags
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  inbound {
    label    = "public-tcp"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = local.periscope_tcp_ports
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  dynamic "inbound" {
    for_each = length(var.media_udp_ports) > 0 ? [1] : []
    content {
      label    = "media-udp"
      action   = "ACCEPT"
      protocol = "UDP"
      ports    = local.periscope_udp_ports
      ipv4     = ["0.0.0.0/0"]
      ipv6     = ["::/0"]
    }
  }

  inbound {
    label    = "Tailscale-WireGuard"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "41641"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "operator-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = local.operator_cidrs
  }
}

resource "linode_instance" "periscope" {
  label           = "${var.label_prefix}-periscope"
  image           = "linode/ubuntu24.04"
  region          = var.region
  type            = var.periscope_type
  tags            = concat(var.tags, ["periscope"])
  authorized_keys = [var.ssh_public_key]
  firewall_id     = linode_firewall.periscope.id

  lifecycle {
    ignore_changes = [disk, metadata]
  }
}

# ── Rehearsal box (stand-in for the home server) ──────────────────────────
resource "linode_firewall" "box" {
  count           = var.box_enabled ? 1 : 0
  label           = "${var.label_prefix}-box-fw"
  tags            = var.tags
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  inbound {
    label    = "Tailscale-WireGuard"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "41641"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Operator SSH for bootstrap only (a home box is reached on the LAN instead).
  inbound {
    label    = "operator-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = local.operator_cidrs
  }
}

resource "linode_instance" "box" {
  count           = var.box_enabled ? 1 : 0
  label           = "${var.label_prefix}-box"
  image           = "linode/ubuntu24.04"
  region          = var.region
  type            = var.box_type
  tags            = concat(var.tags, ["devhome-box"])
  authorized_keys = [var.ssh_public_key]
  firewall_id     = linode_firewall.box[0].id

  lifecycle {
    ignore_changes = [disk, metadata]
  }
}
