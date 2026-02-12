port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server ${vpn_network_cidr}
ifconfig-pool-persist ipp.txt
push "route 10.8.0.0 255.255.255.0"
push "route ${service_cidr}"
push "route ${cluster_subnet_cidr}"
push "route ${vpn_server_subnet_cidr}"
push "dhcp-option DNS ${dns_server_ip}"
push "dhcp-option DOMAIN ${domain}"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
verb 3
explicit-exit-notify 1
