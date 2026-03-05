#!/bin/bash

LOG_FILE="/var/log/lscwp-setup.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-setup-$$"
RAM_PER_JOB_MB=200
WP_TIMEOUT=30

# ====================================
# รองรับ /home และ /home2
# ====================================
HOME_DIRS=(/home /home2)

log() {
    local DATE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
}

cleanup() {
    rm -rf "$RESULT_DIR"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

mkdir -p "$RESULT_DIR"
mkdir -p "$RESULT_DIR/check"
mkdir -p "$RESULT_DIR/fix"

START_TIME=$(date +%s)

# ====================================
# เช็ค WP-CLI
# ====================================
if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI กรุณาติดตั้งก่อน"
    exit 1
fi

# ====================================
# เช็ค Redis
# ====================================
if [ ! -S "/var/run/redis/redis.sock" ]; then
    log "❌ ERROR: ไม่พบ Redis Socket ที่ /var/run/redis/redis.sock"
    exit 1
fi

REDIS_PING=$(redis-cli -s /var/run/redis/redis.sock ping 2>/dev/null)
if [ "$REDIS_PING" != "PONG" ]; then
    log "❌ ERROR: Redis ไม่ตอบสนอง (ping ได้ = ${REDIS_PING:-ไม่มีผล})"
    exit 1
fi

# ====================================
# คำนวณ MAX_JOBS อัตโนมัติ
# ====================================
CPU_CORES=$(nproc)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
MAX_JOBS_BY_RAM=$(( TOTAL_RAM_MB / RAM_PER_JOB_MB ))

if [ "$CPU_CORES" -lt "$MAX_JOBS_BY_RAM" ]; then
    MAX_JOBS=$CPU_CORES
else
    MAX_JOBS=$MAX_JOBS_BY_RAM
fi

[ "$MAX_JOBS" -lt 1 ] && MAX_JOBS=1
[ "$MAX_JOBS" -gt 20 ] && MAX_JOBS=20

# ====================================
# แสดง home directories ที่พบ
# ====================================
FOUND_HOMES=()
for base in "${HOME_DIRS[@]}"; do
    if [ -d "$base" ]; then
        FOUND_HOMES+=("$base")
    fi
done

log "======================================"
log " LITESPEED OBJECT CACHE SETUP"
log " เริ่มเวลา      : $(date '+%Y-%m-%d %H:%M:%S')"
log " CPU Cores     : $CPU_CORES Core"
log " Total RAM     : $TOTAL_RAM_MB MB"
log " Auto MAX_JOBS : $MAX_JOBS"
log " Redis Status  : ✅ PONG"
log " WP-CLI        : ✅ $(wp --version --allow-root 2>/dev/null)"
log " Home Dirs     : ${FOUND_HOMES[*]}"
log "======================================"

# ============================================================
# DISCOVERY: กวาดหา cPanel users + WordPress ทั้งหมด
# แสดงรายงานก่อนเริ่มทำงาน
# ============================================================
log ""
log "======================================"
log " DISCOVERY: กำลังสแกนหา cPanel Users..."
log "======================================"

# เก็บข้อมูลรวม
DIRS=()
TOTAL_CPANEL_USERS=0
TOTAL_WP_SITES=0

# ใช้ associative array เก็บจำนวนเว็บต่อ user
declare -A USER_WP_COUNT
declare -A USER_HOME_BASE
declare -A USER_WP_SITES

for base in "${HOME_DIRS[@]}"; do
    [ -d "$base" ] || continue

    USERS_IN_BASE=0

    for userhome in "${base}"/*/; do
        [ -d "$userhome" ] || continue
        [ -d "${userhome}public_html" ] || continue

        USERNAME=$(basename "$userhome")

        # ข้าม system directories ที่ไม่ใช่ cPanel user
        case "$USERNAME" in
            cPanel|virtfs|cpeasyapache|softaculous|.cpan) continue ;;
        esac

        # หา WordPress ทั้งหมดใน user นี้
        WP_COUNT=0
        WP_LIST=""

        while IFS= read -r wpconfig; do
            WPDIR=$(dirname "$wpconfig")
            DIRS+=("${WPDIR}/")

            SUBDIR=${WPDIR#*public_html/}
            SUBDIR=${SUBDIR%/}
            [ "$SUBDIR" = "$WPDIR" ] && SUBDIR="main"  # ถ้าอยู่ตรง public_html

            if [ -n "$WP_LIST" ]; then
                WP_LIST="${WP_LIST}, ${SUBDIR:-main}"
            else
                WP_LIST="${SUBDIR:-main}"
            fi

            ((WP_COUNT++))
        done < <(find "${userhome}public_html" -name "wp-config.php" \
            -not -path "*/wp-content/*" \
            -not -path "*/wp-includes/*" \
            -not -path "*/backup*/*" \
            -not -path "*/cache/*" \
            -not -path "*/tmp/*" \
            -not -path "*/.trash/*" \
            -not -path "*/node_modules/*" \
            2>/dev/null)

        if [ "$WP_COUNT" -gt 0 ]; then
            USER_WP_COUNT["$USERNAME"]=$WP_COUNT
            USER_HOME_BASE["$USERNAME"]=$base
            USER_WP_SITES["$USERNAME"]=$WP_LIST
            ((TOTAL_CPANEL_USERS++))
            TOTAL_WP_SITES=$((TOTAL_WP_SITES + WP_COUNT))
            ((USERS_IN_BASE++))
        fi
    done

    log " 📂 $base : พบ $USERS_IN_BASE cPanel users ที่มี WordPress"
done

log ""
log "======================================"
log " สรุปผล DISCOVERY"
log " cPanel Users (มี WP) : $TOTAL_CPANEL_USERS users"
log " WordPress ทั้งหมด     : $TOTAL_WP_SITES เว็บ"
log "======================================"
log ""

# ====================================
# แสดงรายละเอียดแต่ละ cPanel user
# ====================================
log "--------------------------------------"
log " รายละเอียด cPanel Users"
log "--------------------------------------"

# เรียงตามชื่อ user
SORTED_USERS=($(echo "${!USER_WP_COUNT[@]}" | tr ' ' '\n' | sort))

INDEX=1
for user in "${SORTED_USERS[@]}"; do
    log " $INDEX) $user"
    log "    Home     : ${USER_HOME_BASE[$user]}"
    log "    WP Sites : ${USER_WP_COUNT[$user]} เว็บ"
    log "    Sites    : ${USER_WP_SITES[$user]}"
    ((INDEX++))
done

log "--------------------------------------"
log ""

TOTAL=${#DIRS[@]}

if [ "$TOTAL" -eq 0 ]; then
    log "ไม่พบเว็บ WordPress ใดๆ ในระบบ"
    exit 0
fi

# ====================================
# PHASE 1: Check
# ====================================
log "======================================"
log " PHASE 1: กำลังตรวจสอบค่าปัจจุบัน..."
log " ตรวจสอบ $TOTAL เว็บ จาก $TOTAL_CPANEL_USERS cPanel users"
log "======================================"

check_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"
    local UNIQUE="${BASHPID}_$(date +%s%N)"

    # ดึงชื่อ SITE แบบยืดหยุ่น (รองรับทุก /home* และทุก level)
    local AFTER_HOME=${dir#/home*/}
    local USERNAME=${AFTER_HOME%%/*}
    local SUBDIR=${dir#*public_html/}
    SUBDIR=${SUBDIR%/}
    local SITE="${USERNAME}/${SUBDIR:-main}"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    _wp() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }

    if ! _wp plugin is-installed litespeed-cache; then
        _log "⏭  NO LITESPEED: $SITE ($dir)"
        touch "${RESULT_DIR}/check/noplugin_${UNIQUE}"
        return
    fi

    if ! _wp plugin is-active litespeed-cache; then
        _log "⏭  INACTIVE: $SITE ($dir)"
        touch "${RESULT_DIR}/check/inactive_${UNIQUE}"
        return
    fi

    local CUR_OBJ=$(_wp litespeed-option get object | tr -d '[:space:]')
    local CUR_KIND=$(_wp litespeed-option get object-kind | tr -d '[:space:]')
    local CUR_HOST=$(_wp litespeed-option get object-host | tr -d '[:space:]')
    local CUR_PORT=$(_wp litespeed-option get object-port | tr -d '[:space:]')

    if [ "$CUR_OBJ" = "1" ] && [ "$CUR_KIND" = "1" ] && \
       [ "$CUR_HOST" = "/var/run/redis/redis.sock" ] && [ "$CUR_PORT" = "0" ]; then
        _log "✅ CORRECT: $SITE"
        touch "${RESULT_DIR}/check/correct_${UNIQUE}"
    else
        _log "⚠️  NEEDS FIX: $SITE"
        _log "   object=$CUR_OBJ | kind=$CUR_KIND | host=$CUR_HOST | port=$CUR_PORT"
        ( flock 200; echo "$dir" >> "$RESULT_DIR/needs_fix.txt" ) 200>"$LOCK_FILE"
        touch "${RESULT_DIR}/check/needsfix_${UNIQUE}"
    fi
}

export -f check_site

declare -a PIDS=()
for dir in "${DIRS[@]}"; do
    check_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

CORRECT=$(find "$RESULT_DIR/check" -name "correct_*" 2>/dev/null | wc -l)
NEEDSFIX=$(find "$RESULT_DIR/check" -name "needsfix_*" 2>/dev/null | wc -l)
NOPLUGIN=$(find "$RESULT_DIR/check" -name "noplugin_*" 2>/dev/null | wc -l)
INACTIVE=$(find "$RESULT_DIR/check" -name "inactive_*" 2>/dev/null | wc -l)
SKIPPED=$(( NOPLUGIN + INACTIVE ))

log "======================================"
log " สรุปผล PHASE 1"
log " รวมทั้งหมด         : $TOTAL เว็บ"
log " ✅ ถูกต้องแล้ว      : $CORRECT เว็บ"
log " ⚠️  ต้องแก้ไข       : $NEEDSFIX เว็บ"
log " ⏭  ข้าม (No Plugin) : $NOPLUGIN เว็บ"
log " ⏭  ข้าม (Inactive)  : $INACTIVE เว็บ"
log "======================================"

if [ "$NEEDSFIX" -eq 0 ]; then
    log "✅ ทุกเว็บถูกต้องแล้ว ไม่ต้องแก้ไขอะไร"
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))
    log " เวลาที่ใช้ : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
    log "======================================"
    exit 0
fi

# ====================================
# PHASE 2: Setup
# ====================================
log "======================================"
log " PHASE 2: กำลังแก้ไข $NEEDSFIX เว็บ..."
log "======================================"

fix_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"
    local UNIQUE="${BASHPID}_$(date +%s%N)"

    # ดึงชื่อ SITE แบบยืดหยุ่น (รองรับทุก /home* และทุก level)
    local AFTER_HOME=${dir#/home*/}
    local USERNAME=${AFTER_HOME%%/*}
    local SUBDIR=${dir#*public_html/}
    SUBDIR=${SUBDIR%/}
    local SITE="${USERNAME}/${SUBDIR:-main}"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    _wp() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }

    local FAILED=0

    _wp litespeed-option set object 1 || FAILED=1
    _wp litespeed-option set object-kind 1 || FAILED=1
    _wp litespeed-option set object-host "/var/run/redis/redis.sock" || FAILED=1
    _wp litespeed-option set object-port "0" || FAILED=1
    _wp litespeed-option set object-user "" || \
    _wp litespeed-option set object-user " " || FAILED=1
    _wp litespeed-option set object-pswd "" || \
    _wp litespeed-option set object-pswd " " || FAILED=1

    if [ "$FAILED" -eq 1 ]; then
        _log "❌ FAILED (Set Error): $SITE ($dir)"
        touch "${RESULT_DIR}/fix/failed_${UNIQUE}"
        return
    fi

    _log "✅ SET DONE: $SITE"
    touch "${RESULT_DIR}/fix/success_${UNIQUE}"
}

export -f fix_site

declare -a PIDS=()
while IFS= read -r dir; do
    fix_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done < "$RESULT_DIR/needs_fix.txt"
for pid in "${PIDS[@]}"; do wait "$pid"; done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

SUCCESS=$(find "$RESULT_DIR/fix" -name "success_*" 2>/dev/null | wc -l)
FAILED=$(find "$RESULT_DIR/fix" -name "failed_*" 2>/dev/null | wc -l)

log "======================================"
log " สรุปผลรวม"
log " รวมทั้งหมด         : $TOTAL เว็บ"
log " ✅ ถูกต้องอยู่แล้ว  : $CORRECT เว็บ"
log " ✅ Set สำเร็จ       : $SUCCESS เว็บ"
log " ❌ Set ไม่สำเร็จ    : $FAILED เว็บ"
log " ⏭  ข้ามทั้งหมด      : $SKIPPED เว็บ"
log " เวลาที่ใช้          : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log " ✅ รัน verify ต่อด้วย: verify-object-cache.sh"
log "======================================"
