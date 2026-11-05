# devhome — dev + CI on one box

`devhome` is a dev-class environment (like `dev`) whose whole footprint
(the dev Kubernetes cluster, the CI host, and PostgreSQL) runs on **one machine**.
That machine is meant to be a small server at home. Today a Linode stands in for it.
The only public part is a 1 GB "periscope" node:

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
* **One pipeline at a time.** The CI host leases a single pool slot
  (`CI_POOL_SLOTS=pool1`). It deploys with `MT_CI_DEV_ENV=devhome` and reads
  the cluster kubeconfig from `MT_CI_DEV_KUBECONFIG_FILE` (`/home/woodpecker/.kube/devhome.yaml`, placed by `devhome/ansible/ci-bootstrap.yml`). These are Woodpecker
  global env vars.

## Bring-up (from an operator machine)

Private inputs live in `config/platform/devhome/`: `terraform.tfvars`,
`inventory.yml` and `ansible-vars.yml`. The last holds single-use Headscale
pre-auth keys and the forwarded ports.

1. **Machines:**
   `cd devhome/terraform && terraform apply -var-file=../../config/platform/devhome/terraform.tfvars`.
   This creates the periscope plus, while `box_enabled`, the Linode stand-in box.
2. **Box:**
   `ansible-playbook -i …/inventory.yml -e @…/ansible-vars.yml devhome/ansible/box.yml`.
   * The first pass joins the tailnet and prints the box's tailnet IP.
   * Set `box_tailscale_ip`, then run it again. The second pass creates the k3d
     cluster, HAProxy, dnsmasq and the VM-like containers.
3. **Periscope:** `ansible-playbook … devhome/ansible/periscope.yml`.
4. **PostgreSQL:**
   * Join `devhome-pg` to the tailnet.
   * Put its address in `pgbouncer.pg_vm_tailscale_ip` and `POSTGRES_SERVER_IP`
     (`config/platform/infra/terraform-outputs.devhome.env`).
   * Run `devhome/ansible/pg-prepare.yml` (the VM's cloud-init steps: C-locale
     initdb, `postgres_exporter`), then `manage_infra -e devhome --ansible --limit=postgres`, then
     `devhome/scripts/pg-bootstrap.sh -e devhome -t <infra-tenant> root@172.30.0.10 -o ProxyJump=root@<box>`.
5. **Cluster:** `deploy_infra -e devhome`, `manage_infra -e devhome --dns`, then
   `create_env -e devhome -t <tenant>`.

## Ports

Each tenant's Stalwart and JVB ports must be listed in **three places**:
* `devhome_forward_tcp` / `devhome_forward_udp` (Ansible);
* `mail_tcp_ports` / `media_udp_ports` (Terraform firewall);
* the k3d port publishes, which are fixed when the cluster is created.
  Adding a tenant later means recreating the k3d cluster.

## Moving to a real home box

1. Set `box_enabled = false` and re-apply Terraform. That destroys the Linode
   stand-in and keeps the periscope.
2. Install Ubuntu 24.04 on the home box and point the `box` inventory entry at it.
3. Run the playbooks as above.

The periscope reaches the box over the tailnet, so the home router needs no
port forwards.
