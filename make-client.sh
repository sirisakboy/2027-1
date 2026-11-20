#!/bin/bash
# ใช้แบบนี้: sudo ./make-client.sh ai-client
NAME=${1:-ai-client}
PublicIP=$(curl -s icanhazip.com)

cat > ${NAME}.ovpn <<CONF
client
dev tun
proto tcp
remote $PublicIP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
keepalive 5 30
tun-mtu 1400
mssfix 1200
explicit-exit-notify 0
verb 3
<ca>
$(cat keys/ca.crt)
</ca>
<cert>
$(cat keys/client.crt)
</cert>
<key>
$(cat keys/client.key)
</key>
<tls-auth>
$(cat keys/ta.key)
</tls-auth>
key-direction 1
CONF

echo "สร้างเสร็จแล้ว: ${NAME}.ovpn"
echo "เอาไฟล์นี้ไปใส่ใน Termux / มือถือ ได้เลยไฟล์เดียวจบ"
