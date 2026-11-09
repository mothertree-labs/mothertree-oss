# devhome — dev + CI on one box

`devhome` is a dev-class environment (like `dev`) whose whole footprint
(the dev Kubernetes cluster, the CI host, and PostgreSQL) runs on **one machine**.
That machine is a small server at home (it was rehearsed on a Linode first;
`box_enabled` in the Terraform still creates that stand-in). The only public
part is a 1 GB "periscope" node:

```
internet ──► periscope (nanode, public IP; DNS for *.devhome.<domain> points here)
               │  HAProxy L4 forward — PROXY v2 on every port except 25
               │  iptables DNAT for UDP media (Jitsi JVB)
               ▼  over the dev tailnet (Headscale)
             devhome box ─ HAProxy ─► k3d cluster "devhome" (single k3s node)
                         ├─ devhome-pg  (VM-like container: systemd + sshd, tag:postgres)
                         └─ devhome-ci  (VM-like container: Woodpecker, tag:ci)
```

* **Same scripts, same manifests.** `deploy_infra`, `create_env` and the
  `.woodpecker` pipelines run unchanged. Two config settings select the differences:
  * The env name is dev-class (`dev*`), so it gets the relaxed dev behaviour
    (`mt_is_dev_class` in `scripts/lib/common.sh`).
  * `cluster.platform: k3s` is set in `config/platform/infra/devhome.config.yaml`.
    `scripts/lib/platform.sh` reads it.
* **What k3s changes:**
  * The Linode Cloud Firewall Controller is skipped.
  * `linode-block-storage*` StorageClasses are served by local-path
    (`apps/manifests/k3s/storageclasses.yaml`).
  * The public ingress IP is `cluster.public_ip`, the periscope, and not the
    ServiceLB address (`mt_ingress_public_ip`).
  * JVB advertises the periscope IP as its media address (`JVB_PUBLIC_IP`, set by
    `apps/deploy-jitsi.sh` on k3s). The periscope DNATs the media UDP port to the box.
    `--node-external-ip` is deliberately not used: k3s would then advertise
    that address as the `kubernetes` Service endpoint, and pods could not reach it.
  * Cluster CIDRs match LKE: pods `10.2.0.0/16`, services `10.128.0.0/16`.
* **VM-like containers.** The PostgreSQL and CI containers run systemd and sshd,
  so the existing VM playbooks configure them as they would a Linode VM:
  * PostgreSQL: the postgres play in `ansible/playbook.yml`, via
    `manage_infra -e devhome --ansible`.
  * CI: `ci/ansible/playbook.yml`.
* **One PgBouncer replica.** Its pod anti-affinity is hard and there is one node,
  so set `pgbouncer.replicas: 1` and double `default_pool_size` (20 instead of
  dev's 10 × 2 pods). PgBouncer runs in session mode: during a Stalwart rolling
  update the old pod keeps its whole pool, and at 10 the new pod never becomes Ready.
* **Outbound mail goes through the periscope.** Residential ISPs block
  outbound TCP 25, so Stalwart cannot deliver to MX directly as it does on dev.
  The periscope runs a relay-only Postfix on its tailnet address
  (`devhome_mail_relay_port`, default 2525) that accepts only the box's tailnet
  address, and `mail.smtp_relay` in `config/platform/infra/devhome.config.yaml`
  points Stalwart's relay route at it (`apps/deploy-stalwart.sh`). The public
  :25 stays HAProxy's inbound forward.
* **One pipeline at a time.** The CI host leases a single pool slot
  (`CI_POOL_SLOTS=pool1`). It deploys with `MT_CI_DEV_ENV=devhome` and reads
  the cluster kubeconfig from `MT_CI_DEV_KUBECONFIG_FILE` (`/home/woodpecker/.kube/devhome.yaml`, placed by `devhome/ansible/ci-bootstrap.yml`). These are Woodpecker
  global env vars.

## Bring-up (from an operator machine)

Private inputs live in `config/platform/devhome/` (committed to the private
platform repo, like `ci/ansible-vars.yml`): `inventory.yml`, `ci-inventory.yml`,
`ansible-vars.yml`, `ci-ansible-vars.yml` and `terraform.tfvars`.
`ansible-vars.yml` holds single-use Headscale pre-auth keys (mint tagged ones
through the Headscale API: box `tag:k8s-node`+`tag:operator`, PG `tag:postgres`,
CI `tag:ci`), the forwarded ports and the box's base-OS settings.

The operator machine only needs SSH to the box on the LAN. Everything else is
reached through it: the VM-like containers on its docker network, and the
periscope on its tailnet address (the periscope's public SSH is limited to
`operator_ips`). Below, `-i …` is `-i config/platform/devhome/inventory.yml -e
@config/platform/devhome/ansible-vars.yml`.

1. **Periscope machine:**
   `cd devhome/terraform && terraform apply -var-file=../../config/platform/devhome/terraform.tfvars`.
2. **Box base OS:** install Ubuntu 24.04 with the operator account and its SSH
   key, then `ansible-playbook -i … --ask-become-pass devhome/ansible/host-base.yml`
   (passwordless sudo, keys-only SSH, wired-first netplan with WiFi fallback,
   root LV grown to the disk, unattended upgrades with a 04:30 reboot). The
   netplan apply drops the LAN for up to ~90 s while DHCP/ARP settle.
3. **Box, first pass:** `ansible-playbook -i … devhome/ansible/box.yml`. It
   joins the tailnet and prints the box's tailnet IP. Set `box_tailscale_ip`.
4. **Periscope:** `ansible-playbook -i … devhome/ansible/periscope.yml`
   (HAProxy, UDP DNAT and the mail relay, all aimed at `box_tailscale_ip`).
5. **Box, second pass:** run `box.yml` again. It creates the k3d cluster, HAProxy,
   dnsmasq and the VM-like containers. HAProxy accepts PROXY headers on the
   tailnet address only from `periscope_tailscale_ip`. Copy
   `/root/devhome-kubeconfig.yaml` from the box to `kubeconfig.devhome.yaml`.
6. **PostgreSQL:**
   * `ansible-playbook -i … devhome/ansible/pg-prepare.yml` (the VM's cloud-init
     steps: C-locale initdb, `postgres_exporter`, and the tailnet join). Put the
     address it prints in `pgbouncer.pg_vm_tailscale_ip` and `POSTGRES_SERVER_IP`
     (`config/platform/infra/terraform-outputs.devhome.env`).
   * `ANSIBLE_SSH_ARGS="-o ProxyJump=<operator>@<box>" manage_infra -e devhome --ansible --limit=postgres`.
     A fresh database cannot reuse an old pgBackRest stanza in the bucket:
     move `pgbackrest/` aside first (`stanza-create` fails with error 028).
   * `devhome/scripts/pg-bootstrap.sh -e devhome -t <infra-tenant> root@172.30.0.10 -o ProxyJump=<operator>@<box>`.
7. **CI:** `ansible-playbook -i config/platform/devhome/ci-inventory.yml -e
   @config/platform/devhome/ci-ansible-vars.yml devhome/ansible/ci-bootstrap.yml`,
   then the same with `ci/ansible/playbook.yml`.
8. **Cluster:** `deploy_infra -e devhome`, `manage_infra -e devhome --dns`, then
   `create_env -e devhome -t <tenant>`.

## Ports

Each tenant's Stalwart and JVB ports must be listed in **three places**:
* `devhome_forward_tcp` / `devhome_forward_udp` (Ansible);
* `mail_tcp_ports` / `media_udp_ports` (Terraform firewall);
* the k3d port publishes, which are fixed when the cluster is created.
  Adding a tenant later means recreating the k3d cluster.

## Moving to a real home box (done 2026-11-08)

1. Set `box_enabled = false` and re-apply Terraform. That destroys the Linode
   stand-in and keeps the periscope.
2. Install Ubuntu 24.04 on the home box and point the `box` inventory entry at
   it (LAN hostname, the non-root operator account).
3. Run the bring-up from step 2.

The periscope reaches the box over the tailnet, so the home router needs no
port forwards.

## Home network isolation

The box runs PR code as root (CI) and holds deploy secrets, so it is kept away
from the rest of the home network in two layers:

* **Gateway (the real boundary):** the box lives on its own VLAN
  (`devhome_vlan_id`, tagged by the box in `host-base.yml`). The gateway
  firewall blocks that VLAN from every internal network and from the gateway's
  own management, and allows only DHCP and DNS to the gateway. The VLAN is
  IPv4-only (no RA, no DHCPv6), matching the IPv4 firewall rules.
* **On the box (second layer):** the `DEVHOME-NO-LAN` chain in `box.yml`
  rejects new connections from any container out of the uplink interfaces to
  private ranges.

Known gap: because the box sets its own tag on a port that also carries the
untagged home LAN, root on the box could drop the tag and reach the LAN. The
fix is a switch port of its own, configured as an access port on the devhome
VLAN only (native = devhome, no other tagged VLANs), with the box-side tag
removed. Verify it from the host as root: an address on the bare NIC, or on
another VLAN ID, must reach nothing.

**Switching the network is a one-way door without console access.** WiFi is
not configured on a VLAN box, so if the VLAN doesn't come up after a netplan
change, the box is unreachable. Arm a timed rollback before applying, e.g.:

```bash
sudo sh -c 'umask 077; tar -C /etc -czf /root/netplan-prev.tgz netplan'   # may hold a WiFi PSK
sudo rm -f /run/devhome-net-ok        # a stale flag would disarm the watchdog
sudo systemd-run --unit=devhome-net-watchdog --collect bash -c '
  for i in $(seq 1 120); do sleep 5; [ -f /run/devhome-net-ok ] && exit 0; done
  rm -rf /etc/netplan && tar -C /etc -xzf /root/netplan-prev.tgz && netplan apply'
# run host-base.yml, find the box at its new address, then:
sudo touch /run/devhome-net-ok && sudo rm -f /root/netplan-prev.tgz
```

Don't start this near the unattended-upgrades reboot time (`devhome_reboot_time`):
a reboot inside the window kills the watchdog without restoring. If the
watchdog does roll back, the box is on its previous network again, which may be
the un-isolated LAN; check `ip -br a` before trusting the isolation.
