#!/bin/bash
set -e
OpenVPNPath=/etc/openvpn
PublicIP=$(curl -s icanhazip.com)
GetInterface=$(ip -o -4 route show to default | awk '{print $5}')

apt update && apt dist-upgrade -y
apt install openvpn openssl iptables-persistent -y

mkdir -p /var/log/openvpn
touch /var/log/openvpn/openvpn-status.log /var/log/openvpn/openvpn.log

# 1. สร้างกุญแจของตัวเอง ไม่ใช้ของตัวอย่าง
mkdir -p keys && cd keys
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout ca.key -out ca.crt -subj "/CN=My-AI-VPN-CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=server" 2>/dev/null
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650 -sha256 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj "/CN=ai-client" 2>/dev/null
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 3650 -sha256 2>/dev/null
openvpn --genkey secret ta.key
openssl dhparam -out dh2048.pem 2048
cd ..

# 2. สร้าง server.conf แบบจูนสำหรับ AI CLI โดยเฉพาะ
cat > server.conf <<'CONF'
port 1194
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh2048.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 5 30
tls-auth ta.key 0
key-direction 0
cipher AES-256-CBC
auth SHA256
max-clients 5
user nobody
group nogroup
persist-key
persist-tun
tun-mtu 1400
mssfix 1200
topology subnet
status /var/log/openvpn/openvpn-status.log
log /var/log/openvpn/openvpn.log
verb 3
CONF

cp server.conf $OpenVPNPath/
cp keys/{ca.crt,ca.key,server.crt,server.key,ta.key,dh2048.pem} $OpenVPNPath/

# 3. เปิด Forward + NAT
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
iptables -t nat -A POSTROUTING -o $GetInterface -j MASQUERADE
iptables -A FORWARD -i tun+ -o $GetInterface -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i tun+ -o $GetInterface -j ACCEPT
netfilter-persistent save

systemctl enable openvpn@server.service
systemctl restart openvpn@server.service

echo "=== DONE ==="
echo "Public IP: $PublicIP"
echo "ไฟล์ client อยู่ในโฟลเดอร์ keys/"
