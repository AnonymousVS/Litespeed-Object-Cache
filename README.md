# object-cache

สคริปต์ตั้งค่าและตรวจสอบ LiteSpeed Object Cache (Redis) สำหรับ WordPress ทุกเว็บใน server โดยอัตโนมัติ รองรับการประมวลผลแบบ parallel

---

## สคริปต์ที่มี

| ไฟล์ | หน้าที่ |
|---|---|
| `setup-object-cache.sh` | ตั้งค่า Object Cache ให้ทุกเว็บ |
| `verify-object-cache.sh` | ตรวจสอบว่าตั้งค่าถูกต้องหรือไม่ |

> รันตามลำดับ **setup → verify** เสมอ

---

## ทำอะไร?

### setup-object-cache.sh
- ตรวจสอบว่ามี **WP-CLI** และ **Redis** พร้อมใช้งาน
- ค้นหาเว็บ WordPress ทั้งหมดใน `/home/*/public_html/*/`
- ทำงาน 2 Phase:
  - **Phase 1** — ตรวจสอบค่าปัจจุบันของแต่ละเว็บ
  - **Phase 2** — แก้ไขเว็บที่ยังตั้งค่าไม่ถูกต้อง
- ข้ามเว็บที่ไม่ได้ติดตั้งหรือไม่ได้เปิด LiteSpeed Cache plugin
- บันทึก log ไว้ที่ `/var/log/lscwp-setup.log`

### verify-object-cache.sh
- ตรวจสอบว่าทุกเว็บตั้งค่า Object Cache ถูกต้องครบถ้วน
- แสดงรายชื่อเว็บที่ยัง FAIL พร้อมค่าที่ผิด
- บันทึก log ไว้ที่ `/var/log/lscwp-verify.log`

### ค่าที่ตั้งให้

| ค่า | Setting |
|---|---|
| Object Cache | เปิด (`1`) |
| Cache Type | Redis (`1`) |
| Host | `/var/run/redis/redis.sock` |
| Port | `0` (Unix Socket) |

---

## ข้อกำหนด

| รายการ | รายละเอียด |
|---|---|
| OS | Linux (CentOS, Ubuntu, AlmaLinux ฯลฯ) |
| Shell | Bash 4.0 ขึ้นไป |
| สิทธิ์ | root |
| WP-CLI | ต้องติดตั้งและใช้คำสั่ง `wp` ได้ |
| Redis | ต้องรันอยู่และมี socket ที่ `/var/run/redis/redis.sock` |
| Plugin | LiteSpeed Cache ต้องติดตั้งและเปิดใช้งานอยู่ |
| เหมาะกับ | เซิร์ฟเวอร์ cPanel / DirectAdmin ที่มีหลาย user |

---

## วิธีรัน

### 1. Setup Object Cache ตั้งค่า

```bash
curl -s "https://raw.githubusercontent.com/ufavision/object-cache/main/setup-object-cache.sh" | bash
```

### 2. Verify Object Cache ตรวจสอบผลลัพธ์

```bash
curl -s "https://raw.githubusercontent.com/ufavision/object-cache/main/verify-object-cache.sh" | bash
```

---

## ดู Log

### setup-object-cache.sh

```bash
# ดู real-time ขณะรัน
tail -f /var/log/lscwp-setup.log

# ดูย้อนหลัง 100 บรรทัด
tail -n 100 /var/log/lscwp-setup.log

# กรองเฉพาะ error
grep "❌" /var/log/lscwp-setup.log

# กรองเฉพาะเว็บที่ต้องแก้ไข
grep "NEEDS FIX" /var/log/lscwp-setup.log

# กรองตามวันที่
grep "2025-01-01" /var/log/lscwp-setup.log
```

### verify-object-cache.sh

```bash
# ดู real-time ขณะรัน
tail -f /var/log/lscwp-verify.log

# ดูย้อนหลัง 100 บรรทัด
tail -n 100 /var/log/lscwp-verify.log

# กรองเฉพาะเว็บที่ FAIL
grep "❌" /var/log/lscwp-verify.log

# กรองเฉพาะเว็บที่ผ่าน
grep "✅ PASS" /var/log/lscwp-verify.log

# กรองตามวันที่
grep "2025-01-01" /var/log/lscwp-verify.log
```
