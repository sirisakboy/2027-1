# 03 — แพลตฟอร์มที่รองรับ (4 แบบ)

> สรุปสั้น: Arena VPN ตรวจแพลตฟอร์มเองได้ — พิมพ์ `arena-vpn platform show` แล้วทำตามที่มันบอก
> เอกสารนี้คือคำตอบว่า **แต่ละที่ต้องไป "เปิดประตู" ตรงไหน** ซึ่งเป็นคนละที่กับตัวสคริปต์

## ตารางสรุป

| แพลตฟอร์ม | รัน VPN server ได้? | MTU | ต้องเปิดพอร์ตที่ไหน | กับดักหลัก |
|---|---|---|---|---|
| **Google Cloud Shell** | ❌ **ไม่ได้** (ใช้เป็นรีโมตคอนโทรล) | — | ไม่ต้อง (ไม่มี inbound) | ไม่มี `/dev/net/tun` · เครื่องถูกลบเมื่อไม่ใช้งาน |
| **Google Cloud VM (GCE)** | ✅ ได้เต็ม | **1360** | VPC Firewall Rule (ingress) | MTU 1460 · firewall อยู่ "นอก" VM · IP ชั่วคราวเปลี่ยน |
| **AWS EC2** | ✅ ได้เต็ม | 1420 | Security Group (inbound) | ต้องมี **IMDSv2** · SG อยู่ "นอก" VM · EIP คิดเงินถ้าไม่ผูก |
| **Oracle Cloud (OCI)** | ✅ ได้เต็ม | 1420 | Security List / NSG | อิมเมจมี `-A INPUT -j REJECT` ท้ายเชน (บั๊กคลาสสิก) · A1.Flex ถูกเรียกคืน |
| **เซิร์ฟเวอร์ส่วนตัว** | ✅ ได้ ถ้ามี public IP | 1420 (PPPoE 1412) | port-forward ที่เราเตอร์ + ufw | CGNAT = ทำไม่ได้ · IP เปลี่ยน (ต้อง DDNS) |

---

## 1. Google Cloud Shell — ใช้เป็น "เครื่องควบคุม" ไม่ใช่เครื่องแม่

Cloud Shell เป็นคอนเทนเนอร์ชั่วคราว **ไม่มี `/dev/net/tun` และไม่มี inbound port**
→ รัน VPN server ในนี้ไม่ได้เลย ไม่ว่าจะตั้งค่าอย่างไร (นี่คือข้อจำกัดของแพลตฟอร์ม ไม่ใช่บั๊ก)

```bash
# ตรวจให้เห็นด้วยตาตัวเอง
arena-vpn platform show       # จะขึ้น TUN: ไม่ · Public IP: ไม่ · ข้อมูลคงทน: ไม่
ls -l /dev/net/tun            # No such file or directory
```

### สิ่งที่ทำได้จริง (และสะดวกมาก)

```bash
# 1) ติดตั้ง VM ใหม่ทั้งเครื่องจาก Cloud Shell — คำสั่งเดียว
arena-vpn bootstrap ubuntu@34.87.x.x --key ~/.ssh/gcp-key

# 2) สั่งงาน VM ผ่าน SSH (ไม่ต้องเปิด terminal ค้าง)
arena-vpn remote ubuntu@34.87.x.x status
arena-vpn remote ubuntu@34.87.x.x peer add phone
arena-vpn remote ubuntu@34.87.x.x peer export phone phone.zip

# 3) เปิด SOCKS5 ผ่าน SSH — ใช้เน็ตของ VPN โดยไม่ต้องมี TUN
arena-vpn proxy start ubuntu@34.87.x.x
export ALL_PROXY=socks5h://127.0.0.1:1080
curl -s https://ifconfig.me/ip     # ← ต้องเป็น IP ของ VM
arena-vpn proxy stop

# 4) ดาวน์โหลดไฟล์ client มาเก็บ (แล้วอัปขึ้น Drive ได้)
arena-vpn remote ubuntu@34.87.x.x peer export phone phone.zip
cloudshell download phone.zip       # คำสั่งของ Cloud Shell เอง
```

> **ข้อควรรู้:** Cloud Shell มี quota ~50 ชม./สัปดาห์ และบ้าน (`$HOME`) 5 GB
> เก็บไฟล์ config ไว้ใน Drive/Git ไม่ใช่ใน Cloud Shell

### ตั้งค่า SSH ให้ `bootstrap` ทำงานได้

```bash
# สร้างกุญแจใน Cloud Shell แล้วใส่ public key ใน VM
ssh-keygen -t ed25519 -f ~/.ssh/arena -N ''
# คัดลอก ~/.ssh/arena.pub ไปวางใน VM (หรือใช้ gcloud)
gcloud compute ssh my-vm --zone=asia-southeast1-b    # จะจัดการ key ให้เอง

# บอก arena-vpn ว่าจะใช้กุญแจไหน (หรือใส่ใน env ก็ได้)
export AVPN_REMOTE_KEY=~/.ssh/arena
export AVPN_REMOTE_PORT=22
```

---

## 2. Google Cloud VM (Compute Engine) — ใช้งานเต็มรูปแบบ

```bash
# บน VM
curl -fsSL https://raw.githubusercontent.com/sirisakboy/2027-1/main/arena-vpn | sudo bash -s -- init --portal --yes
```

หรือจาก Cloud Shell: `arena-vpn bootstrap ubuntu@<EXTERNAL_IP>`

### ต้องเปิด firewall ที่ "นอก VM" (สำคัญที่สุด)

```bash
gcloud compute firewall-rules create arena-vpn \
  --allow=udp:51820,tcp:443,tcp:8443,udp:443 \
  --source-ranges=0.0.0.0/0 --direction=INGRESS \
  --target-tags=arena-vpn
```

หรือ Console → **VPC network → Firewall → Create firewall rule**
- Targets: All instances
- Source IPv4 ranges: `0.0.0.0/0`
- Protocols and ports: `tcp:443,8443` และ `udp:51820,443`

### กับดักของ GCP

| เรื่อง | รายละเอียด | วิธีแก้ |
|---|---|---|
| **MTU** | การ์ดของ GCE = 1460 (ไม่ใช่ 1500) | สคริปต์ตั้ง `1360` ให้แล้ว — ห้ามแก้เป็น 1420 เอง |
| **Firewall อยู่คนละที่** | `iptables` บน VM ไม่ใช่ด่านเดียว | ต้องสร้าง VPC rule ข้างบนด้วย |
| **Ephemeral IP** | หยุด/เริ่มเครื่องใหม่ = IP เปลี่ยน | จอง Static IP หรือใช้ DDNS + `AVPN_PUBLIC_HOST` |
| **Network tier** | Premium ฟรีแค่ 1 GB/เดือน | ตั้งเป็น Standard tier ถ้าเน้นประหยัด |
| **Free tier** | e2-micro ฟรี 1 เครื่อง (us-central1/us-west1/us-east1) | ต้องเลือก region ให้ตรง |

### ตรวจว่าเปิดครบหรือยัง

```bash
bash tools/port-check.sh <EXTERNAL_IP>       # จากเครื่องอื่น ไม่ใช่จากตัว VM
arena-vpn platform check                     # ตรวจเฉพาะแพลตฟอร์ม
arena-vpn doctor
```

---

## 3. AWS EC2 — ใช้งานเต็มรูปแบบ

```bash
# บน VM
curl -fsSL https://raw.githubusercontent.com/sirisakboy/2027-1/main/arena-vpn | sudo bash -s -- init --portal --yes
```

### ต้องเปิด Security Group

```bash
aws ec2 authorize-security-group-ingress --group-id sg-XXXXXXXX \
  --ip-permissions \
    IpProtocol=udp,FromPort=51820,ToPort=51820,IpRanges='[{CidrIp=0.0.0.0/0}]' \
    IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]' \
    IpProtocol=tcp,FromPort=8443,ToPort=8443,IpRanges='[{CidrIp=0.0.0.0/0}]'
```

หรือ Console → **EC2 → Security Groups → Inbound rules → Edit**

> ถ้าใช้ **Launch Wizard / Elastic Beanstalk** ที่สร้าง SG ให้เอง ให้แก้ SG เดียวกันนั้น
> ไม่ใช่สร้างใหม่ (ไม่งั้นกฎจะไม่ผูกกับอินสแตนซ์)

### กับดักของ AWS

| เรื่อง | รายละเอียด | วิธีแก้ |
|---|---|---|
| **IMDSv2** | AMI ใหม่ปิด IMDSv1 → สคริปต์เก่าตรวจไม่เจอ | เวอร์ชันนี้ขอ token ก่อน (แก้แล้ว) — ถ้าปิด IMDS ทั้งหมด ให้ตั้ง `AVPN_PLATFORM=aws` เอง |
| **IP เปลี่ยนเมื่อ stop/start** | เหมือน GCP | ผูก **Elastic IP** หรือใช้ DDNS |
| **EIP คิดเงินถ้าไม่ผูก** | allocate ค้างไว้ = เสียเงินรายชั่วโมง | ผูกหรือ release |
| **Free tier เปลี่ยนแล้ว** | บัญชีใหม่หลัง 15 ก.ค. 2025 ไม่มี 750 ชม. ฟรี | ใช้ credits (~$200/6 เดือน) หรือ t4g.small |
| **SG อยู่คนละที่** | iptables บนเครื่องไม่พอ | เปิด SG ด้วย |

### ตรวจ IMDS ว่าใช้ได้ไหม

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id    # ต้องได้ i-xxxx
```

ถ้าไม่ได้ → SG/IMDS ถูกปิด หรือรันนอก AWS → ตั้ง `AVPN_PLATFORM=aws` ใน `/etc/arena-vpn/arena-vpn.env`

---

## 4. Oracle Cloud (OCI) — ใช้งานเต็มรูปแบบ ⚠️ กับดักเยอะที่สุด

```bash
curl -fsSL https://raw.githubusercontent.com/sirisakboy/2027-1/main/arena-vpn | sudo bash -s -- init --portal --yes
```

### ต้องเปิด Security List / NSG

Networking → **VCN → Security Lists → Default Security List → Add Ingress Rules**

| Stateless | Source CIDR | IP Protocol | Destination Port Range |
|---|---|---|---|
| No | `0.0.0.0/0` | UDP | `51820` |
| No | `0.0.0.0/0` | TCP | `443,8443` |

> ถ้าใช้ NSG (Network Security Group) ต้องเพิ่มที่ NSG ด้วย — **ต้องเปิดทั้งสองชั้น**

### กับดักของ Oracle

#### ① `-A INPUT -j REJECT` ท้ายเชน (บั๊กที่เจอบ่อยที่สุด)

อิมเมจ Oracle Linux และ Ubuntu ของ OCI วางกฎนี้ไว้ **ท้ายสุด** ของเชน INPUT:

```bash
-A INPUT -j REJECT --reject-with icmp-host-prohibited
```

ถ้าสคริปต์ใช้ `iptables -A INPUT -p udp --dport 51820 -j ACCEPT`
กฎนั้นจะไปอยู่ **หลัง** REJECT → **ไม่เคยถูกใช้เลย** → "เปิดพอร์ตแล้วแต่ต่อไม่ติด"

**เวอร์ชันนี้แก้แล้ว:** ทุกกฎ ACCEPT ใช้ `iptables -I <chain> 1` (แทรกบนสุด)

```bash
# ตรวจด้วยตัวเองว่ากฎของ Arena VPN อยู่เหนือ REJECT
sudo iptables -L INPUT -n --line-numbers | head -20
#  1  ACCEPT  udp  --  0.0.0.0/0  0.0.0.0/0  udp dpt:51820   ← ต้องอยู่บน
#  ...
#  N  REJECT  all  --  0.0.0.0/0  0.0.0.0/0  reject-with icmp-host-prohibited
```

#### ② A1.Flex ถูกเรียกคืน (idle reclaim)

A1.Flex (ARM) ที่ CPU/เน็ต/แรมต่ำกว่า 20% ติดกัน 7 วัน อาจถูก **reclaim**
→ ใช้ `arena-vpn backup` เก็บไว้เป็นประจำ

#### ③ Out of capacity

Free tier "Out of capacity" บ่อยมาก → ลอง Availability Domain อื่น / ลดสเปก / เปลี่ยน region

#### ④ อัปเกรดเป็น PAYG (แนะนำ)

- Free tier: 2 OCPU / 12 GB (Ampere)
- **PAYG: 4 OCPU / 24 GB** และ **ไม่ถูกเรียกคืน** — ยังอยู่ใน Always Free

#### ⑤ อิมเมจ Oracle Linux ใช้ `dnf` ไม่ใช่ `apt`

สคริปต์นี้ใช้ `apt` (Debian/Ubuntu)
→ **ต้องเลือกอิมเมจ Ubuntu 22.04/24.04** ตอนสร้างอินสแตนซ์
(ถ้าเลือก Oracle Linux ไปแล้ว `init` จะหยุดพร้อมบอกเหตุผล ไม่ทำอะไรพัง)

```bash
# ตรวจว่าเป็น distro ที่รองรับ
. /etc/os-release && echo "$ID $VERSION_ID"     # ต้องได้ ubuntu หรือ debian
```

---

## 5. เซิร์ฟเวอร์ส่วนตัว (บ้าน/ออฟฟิศ/colo)

```bash
curl -fsSL https://raw.githubusercontent.com/sirisakboy/2027-1/main/arena-vpn | sudo bash -s -- init --portal --yes
```

### ต้องรู้ก่อน: มี public IP จริงหรือไม่

```bash
arena-vpn platform show
#  ─ ถ้าขึ้น "อยู่หลัง NAT" → ต้อง port-forward
#  ─ ถ้า IP ที่ได้เป็น 100.64–100.127.x.x → CGNAT → ทำ VPN server ไม่ได้เลย
```

`is_cgnat_ip` ตรวจให้แล้ว: ช่วง **100.64.0.0/10** คือ CGNAT ของผู้ให้บริการเน็ต
(TRUE/AIS/3BB บางแพ็กเกจใช้) → **ไม่มีทาง port-forward ได้** ต่อให้ตั้งค่าเราเตอร์ถูกก็ตาม

**ทางออกเมื่อเจอ CGNAT**
1. ขอ public IP จากผู้ให้บริการ (มักมีค่าใช้จ่ายเพิ่ม)
2. ใช้ VM คลาวด์ฟรี (GCP e2-micro / Oracle A1) เป็นเครื่องแม่แทน
3. ใช้ Cloudflare Tunnel / Tailscale เป็นชั้นขนส่ง (นอกขอบเขตของ repo นี้ แต่ใช้ร่วมได้)

### Port forwarding ที่เราเตอร์

| บริการ | โปรโตคอล | พอร์ตนอก | → IP ในบ้าน : พอร์ต |
|---|---|---|---|
| WireGuard | UDP | 51820 | `192.168.1.50:51820` |
| OpenVPN | TCP | 443 | `192.168.1.50:443` |
| Portal (HTTPS) | TCP | 8443 | `192.168.1.50:8443` |

> ตั้ง **DHCP reservation** ให้เครื่องนี้ด้วย ไม่งั้น IP เปลี่ยนแล้วกฎจะชี้ผิด

### Firewall บนเครื่อง

```bash
# ufw (Debian/Ubuntu)
sudo ufw allow 51820/udp
sudo ufw allow 443/tcp
sudo ufw allow 8443/tcp
sudo ufw status verbose

# firewalld (ถ้าติดตั้งไว้)
sudo firewall-cmd --permanent --add-port=51820/udp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --permanent --add-port=8443/tcp
sudo firewall-cmd --reload
```

Arena VPN ใส่กฎ `iptables` ให้แล้วโดยตรง — ถ้าใช้ **ufw/firewalld** ต้องเปิดพอร์ต
ที่ชั้นนั้นด้วย (สองชั้นทำงานแยกกัน)

### PPPoE / MTU

ถ้าเราเตอร์Dial PPPoE → MTU จริง = **1492** ไม่ใช่ 1500
→ tunnel ต้อง ≤ 1412 สคริปต์อ่าน MTU ของการ์ดจริงแล้ว clamp ให้ (ไม่ต่ำกว่า 1280)

```bash
ip link show $(ip route show default | awk '{print $5; exit}') | head -1
# mtu 1492 → arena-vpn จะตั้ง tunnel MTU 1412 ให้เอง
```

### IP เปลี่ยน → ใช้ DDNS

```bash
# ตัวอย่าง DuckDNS (ตั้ง cron ทุก 5 นาที)
echo "url = \"https://www.duckdns.org/update?domains=ชื่อบ้าน&token=XXXX&ip=\"" > ~/.ddns
( crontab -l 2>/dev/null; echo "*/5 * * * * curl -s -K ~/.ddns >/dev/null" ) | crontab -
```

แล้วตั้ง `AVPN_PUBLIC_HOST=ชื่อบ้าน.duckdns.org` ใน `/etc/arena-vpn/arena-vpn.env`
(client config จะใช้โดเมนนี้ ไม่ใช่ IP ที่อาจเปลี่ยน)

---

## คำสั่งที่ใช้บ่อย

```bash
arena-vpn platform show            # ฉันอยู่บนอะไร ทำอะไรได้
arena-vpn platform check           # ปัญหาเฉพาะแพลตฟอร์ม
arena-vpn platform guide           # คำสั่ง firewall ที่ต้องไปรันนอกเครื่อง
arena-vpn platform cloudshell      # คู่มือ Cloud Shell
arena-vpn doctor                   # ตรวจทั้งระบบ (รวมแพลตฟอร์ม)

# จากเครื่องที่ไม่มี TUN (Cloud Shell)
arena-vpn bootstrap ubuntu@IP      # ติดตั้งทั้งเครื่อง
arena-vpn remote ubuntu@IP status  # สั่งงาน
arena-vpn proxy start ubuntu@IP    # SOCKS5
```

## ตารางเทียบ: อะไรอยู่ "ในเครื่อง" vs "นอกเครื่อง"

| ชั้น | GCP | AWS | Oracle | ส่วนตัว |
|---|---|---|---|---|
| **ในเครื่อง** | iptables | iptables | iptables (**ต้อง -I**) | iptables + ufw/firewalld |
| **นอกเครื่อง** | VPC Firewall Rule | Security Group | Security List **+ NSG** | port-forward ที่เราเตอร์ |

> ทั้งสองชั้นต้องเปิด — เปิดชั้นเดียว = ต่อไม่ติด ซึ่งเป็นสาเหตุอันดับ 1
> ที่คนเข้าใจผิดว่า "สคริปต์ไม่ทำงาน"

## ดูต่อ

- [05-แก้ปัญหา.md](05-แก้ปัญหา.md) — อาการ → สาเหตุ → วิธีแก้
- [02-คำสั่งทั้งหมด.md](02-คำสั่งทั้งหมด.md) — คำสั่งครบทุกตัว
- [01-เริ่มต้น.md](01-เริ่มต้น.md) — ติดตั้งครั้งแรก
