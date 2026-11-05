# A "VM-like" container: systemd as PID 1 + sshd, so the existing VM playbooks
# (ansible/playbook.yml postgres play, ci/ansible/playbook.yml) configure it
# exactly as they configure a Linode VM. Run privileged with a private cgroup
# namespace; see devhome/ansible/box.yml.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus openssh-server \
      python3 python3-apt sudo iproute2 iptables iputils-ping curl ca-certificates gnupg \
      lsb-release cron rsyslog kmod udev ufw \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl enable ssh \
 && systemctl mask systemd-logind.service getty.target console-getty.service \
      systemd-udev-trigger.service systemd-firstboot.service \
 && mkdir -p /root/.ssh && chmod 700 /root/.ssh
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
