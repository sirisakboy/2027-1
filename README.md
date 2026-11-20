# AI VPN - เน้นนิ่ง ไม่เน้นเร็ว

ใช้สำหรับ AI Local CLI โดยเฉพาะ

## สร้างเซิร์ฟเวอร์ (ทำครั้งเดียว)
sudo ./setup.sh

## สร้างไฟล์ Client (ทำครั้งเดียว)
sudo ./make-client.sh ai-client

## ต่อ VPN ใน Termux
openvpn --config ai-client.ovpn
