# Litespeed-Object-Cache

Script ตั้งค่า **LiteSpeed Cache → Object Cache** ให้ใช้ **Redis (Unix Socket)** บน WordPress ทุกเว็บใน cPanel/WHM อัตโนมัติ พร้อม parallel + Telegram notification

---

## ✨ Script นี้ทำอะไร

แก้ค่า Object Cache settings ของ **LiteSpeed Cache plugin** บนแต่ละเว็บ WordPress ผ่าน WP-CLI ให้ใช้ Redis ผ่าน Unix Socket แทน TCP

### 🔧 6 Settings ที่ตรวจ + แก้ไข

ในหน้า Admin: **LiteSpeed Cache → Cache → Object**

| Setting ใน UI | DB Key | ค่าที่ตั้ง |
|---|---|---|
| Object Cache | `object` | **ON** |
| Method | `object-kind` | **Redis** |
| Host | `object-host` | `/var/run/redis/redis.sock` |
| Port | `object-port` | `0` |
| Username | `object-user` | (ว่าง) |
| Password | `object-pswd` | (ว่าง) |

> **Settings อื่นๆ ใน LiteSpeed Cache ไม่ถูกแตะต้อง** (Page Cache, CDN, Image Optimize, ฯลฯ)

---

## 🧠 Logic อัจฉริยะ — ไม่ Overwrite สิ่งที่ถูกอยู่แล้ว

```
สำหรับแต่ละเว็บ:
  1. อ่านค่าปัจจุบันทั้งหมด (1 call)
  2. เปรียบเทียบทีละ field
  3. ✔️ ถ้าทุกค่าถูกต้องแล้ว → ข้าม (ไม่ทำอะไร)
  4. 🔧 ถ้ามีบางค่าผิด → แก้เฉพาะที่ผิด แสดงว่าเปลี่ยนจากอะไรเป็นอะไร
```

---

## 🛡 ข้อกำหนดก่อนใช้

- AlmaLinux 9 / cPanel/WHM
- WP-CLI ติดตั้งแล้ว
- Redis Server รันอยู่ + socket อยู่ที่ `/var/run/redis/redis.sock`
- LiteSpeed Cache plugin ติดตั้ง + active บนเว็บนั้น (ถ้าไม่มี → skip เว็บนั้นๆ)
- `flock`, `curl` (ถ้าใช้ Telegram)

---

## 🚀 วิธีใช้
# Run
```bash
bash <(curl -s https://raw.githubusercontent.com/AnonymousVS/Litespeed-Object-Cache/main/setup-object-cache.sh)
```

---

## 🎛 เลือกโหมดการทำงาน

| Mode | ใช้เมื่อ |
|---|---|
| **1. ทั้งเซิร์ฟเวอร์** | ตั้งค่าให้ **ทุกเว็บ** ในเซิร์ฟเวอร์ |
| **2. เลือกบาง cPanel** | ตั้งค่าเฉพาะ cPanel ที่เลือก (พิมพ์หมายเลขคั่นด้วย space/comma เช่น `1 3 5` หรือ `1,3,5`) |

พิมพ์ `q` / `quit` / `exit` เพื่อออกได้ทุก prompt

---

## 📊 Output แสดงอะไรบ้าง

```
✔️  Object Cache Already Set : [25/250] [home/user01] example.com
🔧 Object Cache Fixed : [26/250] [home/user01] shop.com
   ⚙️ Object Cache: OFF ► ON  |
   ⚙️ Method: Memcached ► Redis  |
   ⚙️ Host: '127.0.0.1' ► /var/run/redis/redis.sock
```

**สรุปท้าย:**
- ✔️ Already OK — ค่าถูกต้องอยู่แล้ว
- 🔧 Fixed — แก้ไขสำเร็จ
- ❌ Failed — แก้ไขไม่สำเร็จ
- ⏭ Skipped — Plugin ไม่มี / ไม่ active

---

## 📱 Telegram Notification

เมื่องานเสร็จ จะส่งสรุปผลเข้า Telegram (ตั้งค่า Token + Chat ID ในไฟล์)

```
✅ LiteSpeed Object Cache Setup
🖥 Server: ns5041423
🎛 Mode  : Mode 2: เลือกบาง cPanel
👥 cPanel Accounts: 3 accounts (เลือกจาก 47)
├ Total WordPress : 250
├ ✔️ Already OK    : 200
├ 🔧 Fixed         : 48
├ ❌ Failed        : 2
└ ⊘ Skipped       : 0
⏱ ใช้เวลา : 5 นาที 32 วินาที
```

---

## ⚙️ ปรับแต่ง

แก้ค่าที่หัวไฟล์:

```bash
TELEGRAM_ENABLED=true
TELEGRAM_BOT_TOKEN="..."
TELEGRAM_CHAT_ID="..."
RAM_PER_JOB_MB=200      # RAM ต่อ 1 job
WP_TIMEOUT=30           # timeout WP-CLI ต่อ command
MAX_RETRY=3             # max retry input ที่ Mode 2
```

`MAX_JOBS` คำนวณอัตโนมัติจาก CPU/RAM (limit 1-20)

---

## 📁 Log File

`/var/log/lscwp-setup.log` — **overwrite** ทุกครั้งที่รัน (ดูเฉพาะการรันครั้งล่าสุด)

---

## ❌ Script จะ **ไม่** ทำสิ่งเหล่านี้

- ไม่ติดตั้ง LiteSpeed Cache plugin (ถ้ายังไม่มี → skip)
- ไม่ activate plugin (ถ้า inactive → skip)
- ไม่ flush/purge cache
- ไม่แตะ settings อื่นใน LiteSpeed Cache
- ไม่ติดตั้ง Redis server (ต้อง setup ไว้ก่อน)
- ไม่ test connection จริง WordPress ↔ Redis

---

## 📝 License

MIT
