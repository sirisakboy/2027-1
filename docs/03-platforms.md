# แพลตฟอร์มคลาวด์ฟรี — เลือกเจ้าไหน ตั้งค่าอย่างไร (ข้อมูล พ.ย. 2026)

> ⚠️ Free tier เปลี่ยนนโยบายได้ทุกเมื่อ ตัวเลขด้านล่างตรวจสอบล่าสุด พ.ย. 2026
> ก่อนสมัคร ให้เช็กหน้า pricing ของเจ้าของอีกครั้ง

## สรุปสั้น: เลือกเจ้าไหน

| ถ้าคุณ... | เลือก | เหตุผล |
|---|---|---|
| ต้องการแบนด์วิดท์เยอะ (ดาวน์โหลดโมเดล/AI CLI) | **Oracle Cloud** | 10 TB/เดือน ฟรีตลอดชีพ |
| ต้องการสมัครแล้วใช้ได้เลย ไม่ต้องลุ้น | **Google Cloud** | e2-micro ฟรีตลอดชีพ สมัครง่าย |
| ต้องการเครื่องสำรองชั่วคราว | AWS / Azure เครดิต | ใช้ไม่เกิน 6–12 เดือน |
| อยู่ในไทยและเน็ต AIS/True | ทุกเจ้าได้ แต่เลือก region **Singapore** ถ้ามี | latency ต่ำสุด (~30 ms) |

---

## 1. Google Cloud (แนะนำสำหรับเริ่มต้น)

### สเปกฟรี (Always Free)
- 1 × `e2-micro` (2 vCPU shared, 1 GB RAM) — เฉพาะ region `us-central1`, `us-west1`, `us-east1`
- 30 GB standard persistent disk
- **200 GB/เดือน egress ผ่าน Standard Tier** (Premium Tier ฟรีแค่ 1 GB — ต้องเปลี่ยน!)
- 1 GB IPv4 (มีค่าใช้จ่ายเล็กน้อยถ้าเปิด static IP ค้างในบางกรณี)

### ขั้นตอน
1. สมัครที่ `console.cloud.google.com` → เปิด billing (ได้เครดิต $300/90 วัน แต่ **Always Free ไม่หักเครดิต**)
2. Compute Engine → **Create instance**
   - Region: `us-central1` (หรือ west1/east1)
   - Machine type: **e2-micro** ← สำคัญ
   - Boot disk: Debian 12, **Standard persistent disk, 30 GB** (ห้ามเลือก Balanced/SSD)
   - Networking → **Network service tier: Standard** ← สำคัญมาก
   - Allow HTTP/SSH traffic ติ๊กไว้ก่อน
3. สร้าง Firewall rule (VPC network → Firewall):
   ```
   Name: allow-arena-vpn
   Direction: Ingress · Targets: All instances · Source: 0.0.0.0/0
   Protocols/ports: tcp:443,8443  udp:443,51820
   ```
4. SSH เข้าเครื่อง (ปุ่ม SSH ในเบราว์เซอร์) แล้วติดตั้ง:
   ```bash
   sudo apt-get update -qq && sudo apt-get install -y git
   git clone https://github.com/sirisakboy/2027-1.git && cd 2027-1
   sudo ./arena-vpn init --preset gcp --portal --yes
   ```

### กับดักที่คนพลาดบ่อย
- ❌ **MTU**: GCP ใช้ MTU 1460 → ต้องตั้ง VPN MTU 1360 (`--preset gcp` ทำให้แล้ว) ไม่งั้นเว็บโหลดค้างครึ่งเดียว
- ❌ **Premium tier**: ถ้าไม่เปลี่ยนเป็น Standard จะเสียค่า egress $0.12/GB ทันทีที่เกิน 1 GB
- ❌ **Static IP**: ถ้าจอง static IP แล้วไม่ผูกกับเครื่องที่รันอยู่ อาจมีค่าใช้จ่าย — ใช้ ephemeral ก็พอ (แต่ IP เปลี่ยนเมื่อ stop/start → `watch-ip` จัดการให้)
- ✅ ตั้ง Budget alert ที่ $1 ในหน้า Billing

---

## 2. Oracle Cloud (แบนด์วิดท์ดีสุด แต่สมัครยาก)

### สเปกฟรี (Always Free) — หลังปรับลด มิ.ย. 2026
- **2 OCPU ARM (Ampere A1) + 12 GB RAM** รวมกันทั้งบัญชี (เดิม 4/24)
  - Pay-As-You-Go (อัปเกรดแต่ยังใช้ในโควตาฟรี) ได้คืน 4 OCPU/24 GB และ **ไม่ถูกเรียกคืนเพราะ idle**
- 2 × AMD `VM.Standard.E2.1.Micro` (1/8 OCPU, 1 GB)
- 200 GB block storage, **10 TB/เดือน egress**
- 1 × flexible load balancer 10 Mbps

### ขั้นตอน
1. สมัคร `cloud.oracle.com/free` (ต้องใช้บัตรเครดิต/เดบิตตรวจสอบ — **ไม่ตัดเงิน** ถ้าใช้แค่ Always Free)
2. เลือก **Home region** ให้ดี (เปลี่ยนทีหลังไม่ได้) — แนะนำ Singapore / Japan-East Tokyo สำหรับคนไทย
3. Compute → Instances → Create instance
   - Image: **Canonical Ubuntu 24.04** หรือ Oracle Linux (ถ้าใช้ Oracle Linux ต้องแปลง apt→dnf)
   - Shape: **VM.Standard.A1.Flex** → 2 OCPU / 12 GB (หรือแบ่งเป็น 2 เครื่อง 1/6)
   - ถ้าเจอ **"Out of capacity"** → ลองใหม่ภายหลัง/เปลี่ยน Availability Domain/เปลี่ยน region
   - ติ๊ก **Assign a public IPv4 address**
4. Networking → VCN → Security Lists → Add Ingress Rules:
   ```
   Source 0.0.0.0/0 · IP Protocol UDP · Destination Port 51820
   Source 0.0.0.0/0 · IP Protocol TCP · Destination Port 443
   Source 0.0.0.0/0 · IP Protocol TCP · Destination Port 8443
   ```
5. SSH: `ssh -i key.pem ubuntu@<IP>` (Ubuntu) หรือ `opc@<IP>` (Oracle Linux)

### กับดัก
- ❌ **Idle reclamation**: A1 ที่ CPU/network/memory ต่ำกว่า 20% ติดกัน 7 วัน **อาจถูกปิด/เรียกคืน**
  → ทางแก้: อัปเกรดเป็น PAYG (ฟรียังเท่าเดิม + ปลอดการเรียกคืน) หรือรัน cron เบา ๆ:
  ```bash
  # เพิ่มภาระเบา ๆ เพื่อไม่ให้ถูกมองว่า idle (ใช้ CPU <1%)
  echo '*/5 * * * * root dd if=/dev/zero of=/dev/null bs=1M count=200 2>/dev/null' | sudo tee /etc/cron.d/keepalive-a1
  ```
- ❌ **iptables ในเครื่อง Oracle Linux/Ubuntu image** มีกฎ default ที่บล็อก — สคริปต์เราจัดการให้แล้ว
  แต่ถ้าใช้ Oracle Linux ให้ปิด `firewalld` ก่อน
- ❌ iSCSI/block volume เพิ่มได้แต่ระวังเกิน 200 GB
- ✅ อัปเกรด PAYG แล้วตั้ง budget alert $0.01 + limit

---

## 3. AWS (ใช้เป็นเครื่องสำรอง)

### สถานะ พ.ย. 2026
- บัญชีใหม่ (หลัง 15 ก.ค. 2025): **ไม่มี 750 ชม. ฟรี 12 เดือนแล้ว** → ได้เครดิต ~$200 ใช้ได้ 6 เดือน
- Always Free ที่ยังมี: Lambda 1M req, DynamoDB 25 GB, CloudFront 1 TB — **ไม่มี EC2 ฟรีตลอดชีพ**
- บัญชีเก่า (ก่อน ก.ค. 2025): ยังได้ t2.micro 750 ชม./เดือน 12 เดือน

### ถ้าจะใช้ชั่วคราว
1. EC2 → Launch instance → **t3.micro / t4g.micro** (เลือก AMI Ubuntu 24.04)
2. Security Group → Inbound: `22/tcp`, `443/tcp`, `8443/tcp`, `51820/udp`
3. Elastic IP (ฟรีเมื่อผูกกับเครื่องที่รันอยู่)
4. **ตั้ง Budget ที่ $1** และปิดเครื่องเมื่อเลิกใช้ (`stop` ไม่ใช่ `terminate` ถ้าอยากกลับมา)

---

## 4. ทางเลือกอื่นที่ควรรู้

| เจ้า | ข้อดี | ข้อควรระวัง |
|---|---|---|
| **Fly.io** | ฟรี 3 shared-cpu-1x, รัน Docker ง่าย | ไม่มี public IPv4 ฟรีเต็มรูปแบบ (ต้องใช้ IPv6/allocate) และ TUN อาจจำกัด |
| **Railway/Render** | deploy ง่าย | ไม่เหมาะกับ VPN (ไม่มี raw socket/TUN) |
| **Hetzner/Vultr** | เสถียร เร็ว | ไม่ฟรี (€4–6/เดือน — ถูกกว่าเน็ตบ้านรายเดือน) |
| **Oracle PAYG** | ดีที่สุดถ้าจ่ายไหว | ต้องเฝ้า bill |

> **คำแนะนำจากประสบการณ์**: อุโมงค์ VPN ที่ต้อง "ใช้ยามฉุกเฉิน" ควรมี **2 เครื่องคนละเจ้า**
> (เช่น GCP เป็นหลัก + Oracle เป็นสำรอง) แล้วใช้ไฟล์ client คนละชุด — ต้นทุน 0 บาททั้งคู่

---

## 5. หลังติดตั้งบนทุกเจ้า: ตรวจ 3 อย่างนี้

```bash
sudo arena-vpn doctor
```

1. **Cloud firewall เปิดพอร์ตหรือยัง** — ถ้าในเครื่องเปิดแล้วแต่ข้างนอกปิด จะเห็น `port:` เป็น ok แต่ต่อไม่ติด
   ทดสอบจากเครื่องอื่น: `nc -zvu <IP> 51820` / `nc -zv <IP> 443`
2. **MTU ถูกกับเครือข่ายหรือยัง** — ถ้าเว็บโหลดค้าง/ SSH ค้างหลังต่อ VPN → ลด MTU (`1280` ปลอดภัยสุด)
3. **IP คงที่หรือไม่** — ถ้าเป็น ephemeral ให้ใช้โดเมน + `watch-ip` (ตั้งใน §01)
