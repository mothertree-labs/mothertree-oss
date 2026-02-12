client
dev tun
proto udp
remote vpn.${domain} 1194
resolv-retry infinite
nobind
user nobody
group nogroup
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
verb 3

# DNS configuration for internal services
dhcp-option DNS ${dns_server_ip}
dhcp-option DOMAIN ${domain}
