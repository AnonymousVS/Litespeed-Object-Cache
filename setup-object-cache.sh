#!/bin/bash
###############################################################################
# setup-object-cache.sh
# LiteSpeed Object Cache Setup — Redis Socket (across cPanel accounts)
# Version : 2.0.1
# Location: /usr/local/sbin/setup-object-cache.sh
# Usage   : bash /usr/local/sbin/setup-object-cache.sh
# ─────────────────────────────────────────────────────────────────────────────
# CHANGELOG:
#   v2.0.1 | 2026-05-10 18:05 | Fix: octal interpretation bug
#           |                  |   user input "08", "09" → bash $(()) ตีเป็น octal → error
#           |                  |   เปลี่ยนเป็น 10#$sel เพื่อบังคับ decimal
#           |                  | Add: curl availability check (สำหรับ Telegram)
#           |                  |   ถ้าไม่พบ → auto-disable Telegram + warn
#   v2.0.0 | 2026-05-10 17:57 | Add Mode 1/2 interactive menu
#           |                  |   Mode 1 = ทั้งเซิร์ฟเวอร์ (เหมือนเดิม)
#           |                  |   Mode 2 = เลือกเฉพาะบาง cPanel
#           |                  | Add Telegram notification on completion
#           |                  | Add UI banner + color codes (menu/header/summary)
#           |                  | Add print_header(), get_all_cpanel_users()
#           |                  | Add send_telegram()
#           |                  | scan_all_wordpress() now accepts filter_users[]
#           |                  | Strict input validation:
#           |                  |   - ผิดแม้แต่ตัวเดียว → re-prompt ทั้งหมด
#           |                  |   - max retry 3 ครั้ง
#           |                  |   - พิมพ์ q / Q / quit / exit ออกได้ตลอด
#           |                  |   - Enter เปล่า = re-prompt
#           |                  | Log file = OVERWRITE ทุกครั้ง (เปลี่ยนจาก append)
#   v1.x.x | (legacy)         | Auto run all WordPress on server
###############################################################################

VERSION="2.0.1"

# ── Telegram (แก้ค่าตรงนี้) ────────────────────────────────────────────────
TELEGRAM_ENABLED=true
TELEGRAM_BOT_TOKEN="8728146015:AAHEqYfqU8DOEc99BhPNci7HOFEMVGfiaeQ"
TELEGRAM_CHAT_ID="-5107218486"

# ── Logging ────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/lscwp-setup.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-setup-$$"
RAM_PER_JOB_MB=200
WP_TIMEOUT=30

# directories ที่ไม่ใช่ cPanel user
SKIP_DIRS="virtfs|cPanelInstall|almalinux|mig_data|lscache|error_log|lost\+found"

# ── Input validation ───────────────────────────────────────────────────────
MAX_RETRY=3

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   WHITE='\033[1;37m'
BOLD='\033[1m';      DIM='\033[2m';        RESET='\033[0m'

###############################################################################
# Logging functions
###############################################################################
log() {
    local DATE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
}

log_init() {
    # OVERWRITE ทุกครั้ง (Q7 = A)
    : > "$LOG_FILE"
}

cleanup() {
    rm -rf "$RESULT_DIR"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

mkdir -p "$RESULT_DIR"
mkdir -p "$RESULT_DIR/check"
mkdir -p "$RESULT_DIR/fix"

###############################################################################
# Header
###############################################################################
print_header() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║  ${WHITE}${BOLD}LiteSpeed Object Cache Setup  v${VERSION}${RESET}${BLUE}                     ║${RESET}"
    echo -e "${BLUE}║  ${DIM}Server: $(hostname -s)${RESET}${BLUE}                                          ║${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

###############################################################################
# Get All cPanel Users — จาก /etc/trueuserdomains  (Q1 = A)
###############################################################################
get_all_cpanel_users() {
    local -n _out=$1
    _out=()
    [[ ! -f /etc/trueuserdomains ]] && return
    local -A _seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local u
        u=$(awk '{print $2}' <<< "$line" | tr -d ' \t')
        [[ -z "$u" ]] && continue
        [[ "$u" == "root" || "$u" == "nobody" ]] && continue
        [[ -z "${_seen[$u]+x}" ]] && _seen["$u"]=1 && _out+=("$u")
    done < /etc/trueuserdomains
    mapfile -t _out < <(printf '%s\n' "${_out[@]}" | sort)
}

###############################################################################
# Telegram Notification
###############################################################################
send_telegram() {
    [[ "$TELEGRAM_ENABLED" != "true" ]] && return
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return

    local mode_label="$1"
    local total_sites="$2"
    local correct="$3"
    local fixed="$4"
    local failed="$5"
    local skipped="$6"
    local elapsed="$7"
    local accounts_label="$8"

    local end_time
    end_time=$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')
    local icon="✅"
    [[ $failed -gt 0 ]] && icon="⚠️"
    [[ $failed -eq $total_sites && $total_sites -gt 0 ]] && icon="❌"

    local msg
    msg=$(cat <<EOF
${icon} <b>LiteSpeed Object Cache Setup</b>
🖥 Server: <code>$(hostname -s)</code>
🎛 Mode  : <b>${mode_label}</b>
👥 ${accounts_label}
🕐 ${end_time}

├ Total WordPress : ${total_sites}
├ ✔️ Already OK    : ${correct}
├ 🔧 Fixed         : ${fixed}
├ ❌ Failed        : ${failed}
└ ⊘ Skipped       : ${skipped}

⏱ ใช้เวลา : $(( elapsed / 60 )) นาที $(( elapsed % 60 )) วินาที
📄 <code>${LOG_FILE}</code>
EOF
)
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="${msg}" \
        > /dev/null 2>&1
}

###############################################################################
# Pre-flight checks
###############################################################################
check_requirements() {
    if ! command -v wp &>/dev/null; then
        echo -e "${RED}❌ ERROR:${RESET} ไม่พบ WP-CLI กรุณาติดตั้งก่อน"
        exit 1
    fi

    if [ ! -S "/var/run/redis/redis.sock" ]; then
        echo -e "${RED}❌ ERROR:${RESET} ไม่พบ Redis Socket ที่ /var/run/redis/redis.sock"
        exit 1
    fi

    local REDIS_PING
    REDIS_PING=$(redis-cli -s /var/run/redis/redis.sock ping 2>/dev/null)
    if [ "$REDIS_PING" != "PONG" ]; then
        echo -e "${RED}❌ ERROR:${RESET} Redis ไม่ตอบสนอง (ping ได้ = ${REDIS_PING:-ไม่มีผล})"
        exit 1
    fi

    command -v flock &>/dev/null || {
        echo -e "${RED}❌ ERROR:${RESET} ไม่พบ flock (util-linux)"
        exit 1
    }

    # ถ้าเปิดใช้ Telegram → ต้องมี curl
    if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
        command -v curl &>/dev/null || {
            echo -e "${YELLOW}⚠️  WARN:${RESET} ไม่พบ curl — Telegram notification จะถูกข้าม"
            TELEGRAM_ENABLED=false
        }
    fi
}

###############################################################################
# ดึงรายชื่อ cPanel accounts จริงๆ จาก home directory
# รองรับ 3 วิธี ตามความพร้อมของระบบ
###############################################################################
get_cpanel_accounts() {
    local base_dir="$1"
    local accounts=()

    # วิธีที่ 1: /var/cpanel/users/ (แม่นที่สุด)
    if [ -d "/var/cpanel/users" ]; then
        while IFS= read -r user; do
            [ -d "${base_dir}/${user}" ] && accounts+=("$user")
        done < <(ls /var/cpanel/users/ 2>/dev/null | grep -vE "^(root|nobody)$")

    # วิธีที่ 2: /etc/trueuserdomains
    elif [ -f "/etc/trueuserdomains" ]; then
        while IFS= read -r user; do
            [ -d "${base_dir}/${user}" ] && accounts+=("$user")
        done < <(awk '{print $NF}' /etc/trueuserdomains 2>/dev/null | sort -u | grep -vE "^(root|nobody)$")

    # วิธีที่ 3: สแกน directory ตรงๆ กรองเฉพาะที่มี public_html
    else
        for d in "${base_dir}"/*/; do
            local user=$(basename "$d")
            echo "$user" | grep -qE "^(${SKIP_DIRS})$" && continue
            [ -d "${d}public_html" ] && accounts+=("$user")
        done
    fi

    echo "${accounts[@]}"
}

###############################################################################
# scan_all_wordpress — สแกนหา WordPress ทุกเว็บใน base directory
# รองรับ filter_users[] (Q3 = A)
#   - ถ้า filter_users ว่าง: scan ทุก user dir ใน base
#   - ถ้า filter_users มีค่า: scan เฉพาะ /BASE/USER/ ที่อยู่ในรายการ
###############################################################################
EXCLUDE_PATHS="wp-content|node_modules|\.git|/backup|softaculous_backups|wordpress-backups|/cache|/tmp|/logs|\.trash"

declare -A SEEN_INODE

_is_real_wp() {
    [ -f "${1}wp-includes/version.php" ] && return 0
    return 1
}

_add_wp_dir() {
    local site_dir="$1"
    local inode
    inode=$(stat -c "%d:%i" "${site_dir}wp-config.php" 2>/dev/null) || return
    [ -n "${SEEN_INODE[$inode]+_}" ] && return
    SEEN_INODE[$inode]=1
    DIRS+=("$site_dir")
}

_scan_user_in_base() {
    local user_dir="$1"
    [ ! -d "$user_dir" ] && return
    local user
    user=$(basename "$user_dir")
    echo "$user" | grep -qE "^(${SKIP_DIRS})$" && return

    while IFS= read -r wpconfig; do
        local site_dir
        site_dir="$(dirname "$wpconfig")/"
        echo "$site_dir" | grep -qE "${EXCLUDE_PATHS}" && continue
        _is_real_wp "$site_dir" || continue
        _add_wp_dir "$site_dir"
    done < <(find "$user_dir" -maxdepth 6 -name "wp-config.php" -type f 2>/dev/null)
}

scan_all_wordpress() {
    local base="$1"
    shift
    local filter_users=("$@")
    [ ! -d "$base" ] && return

    if [[ ${#filter_users[@]} -eq 0 ]]; then
        # ไม่มี filter — scan ทุก user dir
        for user_dir in "${base}"/*/; do
            _scan_user_in_base "$user_dir"
        done
    else
        # มี filter — scan เฉพาะ user ที่เลือก
        for u in "${filter_users[@]}"; do
            local ud="${base}/${u}/"
            [ -d "$ud" ] || continue
            _scan_user_in_base "$ud"
        done
    fi
}

###############################################################################
# process_site — Check + Fix Object Cache settings
###############################################################################
_clean() { echo "$1" | tr -d "[:space:]'" ; }

process_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"
    local TOTAL_SITES="$6"
    local COUNTER_FILE="$7"

    local base=$(echo "$dir" | cut -d'/' -f2)
    local user=$(echo "$dir" | cut -d'/' -f3)
    local site_name
    site_name=$(basename "${dir%/}")
    [ "$site_name" = "public_html" ] && site_name=$(basename "$(dirname "${dir%/}")")
    local SITE="[${base}/${user}] ${site_name}"
    local UNIQUE="${BASHPID}_$(date +%s%N)"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    _wp_get() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }
    _wp_set() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root >/dev/null 2>&1
    }
    _wp() { _wp_get "$@"; }

    _next_count() {
        local n
        ( flock 201
          n=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
          n=$(( n + 1 ))
          echo "$n" > "$COUNTER_FILE"
          echo "$n"
        ) 201>"${COUNTER_FILE}.lock"
    }

    if ! _wp plugin is-installed litespeed-cache; then
        touch "${RESULT_DIR}/check/noplugin_${UNIQUE}"
        return
    fi
    if ! _wp plugin is-active litespeed-cache; then
        touch "${RESULT_DIR}/check/inactive_${UNIQUE}"
        return
    fi

    local RAW_OPTS
    RAW_OPTS=$(_wp_get litespeed-option list 2>/dev/null)

    _get_opt() {
        echo "$RAW_OPTS" | grep -m1 "^| $1 " | awk -F'|' '{print $3}' | tr -d '[:space:]\'"''"
    }

    local CUR_OBJ;  CUR_OBJ=$(_get_opt "object")
    local CUR_KIND; CUR_KIND=$(_get_opt "object-kind")
    local CUR_HOST; CUR_HOST=$(_get_opt "object-host")
    local CUR_PORT; CUR_PORT=$(_get_opt "object-port")
    local CUR_USER; CUR_USER=$(_get_opt "object-user")
    local CUR_PSWD; CUR_PSWD=$(_get_opt "object-pswd")

    if [ -z "$CUR_OBJ" ] && [ -z "$CUR_HOST" ]; then
        CUR_OBJ=$(_clean "$(_wp_get litespeed-option get object)")
        CUR_KIND=$(_clean "$(_wp_get litespeed-option get object-kind)")
        CUR_HOST=$(_wp_get litespeed-option get object-host | tr -d '[:space:]')
        CUR_PORT=$(_clean "$(_wp_get litespeed-option get object-port)")
        CUR_USER=$(_clean "$(_wp_get litespeed-option get object-user)")
        CUR_PSWD=$(_clean "$(_wp_get litespeed-option get object-pswd)")
    fi

    [ -z "$CUR_PORT" ] && CUR_PORT="0"
    [ -z "$CUR_OBJ"  ] && CUR_OBJ="0"
    [ -z "$CUR_KIND" ] && CUR_KIND="0"

    local NEED_FIX=()
    [ "$CUR_OBJ"  != "1" ] && NEED_FIX+=("object")
    [ "$CUR_KIND" != "1" ] && NEED_FIX+=("object-kind")
    [ "$CUR_HOST" != "/var/run/redis/redis.sock" ] && NEED_FIX+=("object-host")
    [ "$CUR_PORT" != "0" ] && NEED_FIX+=("object-port")
    [ -n "$CUR_USER" ] && NEED_FIX+=("object-user")
    [ -n "$CUR_PSWD" ] && NEED_FIX+=("object-pswd")

    if [ "${#NEED_FIX[@]}" -eq 0 ]; then
        local IDX; IDX=$(_next_count)
        _log "✔️  Object Cache Already Set : [${IDX}/${TOTAL_SITES}] $SITE"
        touch "${RESULT_DIR}/check/correct_${UNIQUE}"
        return
    fi

    _kind_label() {
        case "$1" in
            0) echo "Memcached" ;;
            1) echo "Redis" ;;
            *) echo "${1:-unknown}" ;;
        esac
    }

    local CHANGES=""
    for field in "${NEED_FIX[@]}"; do
        case "$field" in
            object)
                local OBJ_OLD; [ "$CUR_OBJ" = "1" ] && OBJ_OLD="ON" || OBJ_OLD="OFF"
                CHANGES="${CHANGES} ⚙️ Object Cache: ${OBJ_OLD} ► ON  |"
                ;;
            object-kind)
                CHANGES="${CHANGES} ⚙️ Method: $(_kind_label "$CUR_KIND") ► Redis  |"
                ;;
            object-host)
                CHANGES="${CHANGES} ⚙️ Host: '${CUR_HOST:-empty}' ► /var/run/redis/redis.sock  |"
                ;;
            object-port)
                CHANGES="${CHANGES} ⚙️ Port: '${CUR_PORT:-0}' ► 0  |"
                ;;
            object-user)
                CHANGES="${CHANGES} ⚙️ User: '${CUR_USER}' ► (ว่าง)  |"
                ;;
            object-pswd)
                CHANGES="${CHANGES} ⚙️ Password: (มีค่า) ► (ว่าง)  |"
                ;;
        esac
    done
    CHANGES="${CHANGES%  |}"
    local IDX; IDX=$(_next_count)
    _log "🔧 Object Cache Fixed : [${IDX}/${TOTAL_SITES}] $SITE  ${CHANGES}"

    local FAILED=0
    for field in "${NEED_FIX[@]}"; do
        case "$field" in
            object)      _wp_set litespeed-option set object 1 || FAILED=1 ;;
            object-kind) _wp_set litespeed-option set object-kind 1 || FAILED=1 ;;
            object-host) _wp_set litespeed-option set object-host "/var/run/redis/redis.sock" || FAILED=1 ;;
            object-port) _wp_set litespeed-option set object-port "0" || FAILED=1 ;;
            object-user) _wp_set litespeed-option set object-user "" || _wp_set litespeed-option set object-user " " || FAILED=1 ;;
            object-pswd) _wp_set litespeed-option set object-pswd "" || _wp_set litespeed-option set object-pswd " " || FAILED=1 ;;
        esac
    done

    if [ "$FAILED" -eq 1 ]; then
        local IDX; IDX=$(_next_count)
        _log "❌ FAILED : [${IDX}/${TOTAL_SITES}] $SITE"
        touch "${RESULT_DIR}/check/failed_${UNIQUE}"
    else
        touch "${RESULT_DIR}/check/fixed_${UNIQUE}"
    fi
}

export -f process_site
export -f _clean

###############################################################################
# run_setup — main work logic (รับ filter_users[] เพื่อจำกัด scope)
###############################################################################
run_setup() {
    local mode_label="$1"
    shift
    local filter_users=("$@")

    log_init
    log "======================================"
    log " LITESPEED OBJECT CACHE SETUP v${VERSION}"
    log " Mode          : ${mode_label}"
    if [[ ${#filter_users[@]} -gt 0 ]]; then
        log " Filter users  : ${filter_users[*]}"
    else
        log " Filter users  : ALL"
    fi
    log "======================================"

    local START_TIME
    START_TIME=$(date +%s)

    # ────────────────────────────────────────────────
    # PRE-SCAN: cPanel Accounts
    # ────────────────────────────────────────────────
    local CPANEL_USERS_HOME1=()
    local CPANEL_USERS_HOME2=()
    local CPANEL_USERS_BOTH=()
    local CPANEL_USERS_ALL=()

    # build list ของ cPanel accounts ใน /home และ /home2
    if [ -d "/home" ]; then
        local USERS_H1
        read -ra USERS_H1 <<< "$(get_cpanel_accounts /home)"
        for user in "${USERS_H1[@]}"; do
            # ถ้ามี filter → ข้าม user ที่ไม่อยู่ใน list
            if [[ ${#filter_users[@]} -gt 0 ]]; then
                local match=0
                for u in "${filter_users[@]}"; do [[ "$u" == "$user" ]] && match=1 && break; done
                [[ $match -eq 0 ]] && continue
            fi
            local IN_HOME2=false
            [ -d "/home2/${user}" ] && IN_HOME2=true
            if $IN_HOME2; then
                CPANEL_USERS_BOTH+=("$user")
            else
                CPANEL_USERS_HOME1+=("$user")
            fi
            CPANEL_USERS_ALL+=("$user")
        done
    fi

    if [ -d "/home2" ]; then
        local USERS_H2
        read -ra USERS_H2 <<< "$(get_cpanel_accounts /home2)"
        for user in "${USERS_H2[@]}"; do
            if [[ ${#filter_users[@]} -gt 0 ]]; then
                local match=0
                for u in "${filter_users[@]}"; do [[ "$u" == "$user" ]] && match=1 && break; done
                [[ $match -eq 0 ]] && continue
            fi
            local already=false
            for u in "${CPANEL_USERS_BOTH[@]}"; do
                [ "$u" = "$user" ] && already=true && break
            done
            if ! $already; then
                CPANEL_USERS_HOME2+=("$user")
                CPANEL_USERS_ALL+=("$user")
            fi
        done
    fi

    local TOTAL_ACCOUNTS=${#CPANEL_USERS_ALL[@]}
    local COUNT_HOME1=${#CPANEL_USERS_HOME1[@]}
    local COUNT_HOME2=${#CPANEL_USERS_HOME2[@]}
    local COUNT_BOTH=${#CPANEL_USERS_BOTH[@]}

    # ────────────────────────────────────────────────
    # คำนวณ MAX_JOBS อัตโนมัติ
    # ────────────────────────────────────────────────
    local CPU_CORES TOTAL_RAM_MB MAX_JOBS_BY_RAM MAX_JOBS
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

    # accounts label สำหรับ Telegram (Q4)
    local ACCOUNTS_LABEL
    if [[ ${#filter_users[@]} -gt 0 ]]; then
        # นับจำนวน cPanel ทั้งหมดในเซิร์ฟเวอร์ (ไม่ใช่ filtered)
        local ALL_USERS_TMP=()
        get_all_cpanel_users ALL_USERS_TMP
        local SERVER_TOTAL=${#ALL_USERS_TMP[@]}
        ACCOUNTS_LABEL="cPanel Accounts: ${TOTAL_ACCOUNTS} accounts (เลือกจาก ${SERVER_TOTAL})"
        log " 👥 cPanel Accounts ที่เลือก : ${TOTAL_ACCOUNTS} accounts (เลือกจาก ${SERVER_TOTAL})"
    else
        ACCOUNTS_LABEL="cPanel Accounts: ${TOTAL_ACCOUNTS} accounts"
        log " 👥 cPanel Accounts ทั้งหมด : ${TOTAL_ACCOUNTS} accounts"
    fi

    log "======================================"
    log " เริ่มเวลา      : $(date '+%Y-%m-%d %H:%M:%S')"
    log " CPU Cores     : ${CPU_CORES} Core"
    log " Total RAM     : ${TOTAL_RAM_MB} MB"
    log " Auto MAX_JOBS : ${MAX_JOBS}"
    log " Redis Status  : ✅ PONG"
    log " WP-CLI        : ✅ $(wp --version --allow-root 2>/dev/null)"
    log "======================================"

    # ────────────────────────────────────────────────
    # SCAN: WordPress directories (with filter)
    # ────────────────────────────────────────────────
    DIRS=()
    SEEN_INODE=()

    scan_all_wordpress "/home"  "${filter_users[@]}"
    scan_all_wordpress "/home2" "${filter_users[@]}"

    if [ "${#DIRS[@]}" -eq 0 ]; then
        log "⚠️  ไม่พบ WordPress เลย หยุดการทำงาน"
        # ส่ง Telegram แจ้งว่าไม่พบเว็บ
        local END_TIME ELAPSED
        END_TIME=$(date +%s)
        ELAPSED=$(( END_TIME - START_TIME ))
        send_telegram "$mode_label" 0 0 0 0 0 "$ELAPSED" "$ACCOUNTS_LABEL"
        return 0
    fi

    local TOTAL_SITES=${#DIRS[@]}
    local COUNTER_FILE="$RESULT_DIR/counter"
    echo 0 > "$COUNTER_FILE"

    log " จำนวน WordPress : ${TOTAL_SITES} เว็บ"
    log "======================================"

    # ────────────────────────────────────────────────
    # PROCESS sites in parallel
    # ────────────────────────────────────────────────
    declare -a PIDS=()
    for dir in "${DIRS[@]}"; do
        process_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" \
                     "$WP_TIMEOUT" "$TOTAL_SITES" "$COUNTER_FILE" &
        PIDS+=($!)
        if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
            wait "${PIDS[0]}"
            PIDS=("${PIDS[@]:1}")
        fi
    done
    for pid in "${PIDS[@]}"; do wait "$pid"; done

    local END_TIME ELAPSED
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))

    local CORRECT FIXED FAILED NOPLUGIN INACTIVE SKIPPED
    CORRECT=$(find "$RESULT_DIR/check" -name "correct_*"  2>/dev/null | wc -l)
    FIXED=$(find   "$RESULT_DIR/check" -name "fixed_*"    2>/dev/null | wc -l)
    FAILED=$(find  "$RESULT_DIR/check" -name "failed_*"   2>/dev/null | wc -l)
    NOPLUGIN=$(find "$RESULT_DIR/check" -name "noplugin_*" 2>/dev/null | wc -l)
    INACTIVE=$(find "$RESULT_DIR/check" -name "inactive_*" 2>/dev/null | wc -l)
    SKIPPED=$(( NOPLUGIN + INACTIVE ))

    log "======================================"
    log " สรุปผลรวม"
    if [[ ${#filter_users[@]} -gt 0 ]]; then
        local ALL_USERS_TMP=()
        get_all_cpanel_users ALL_USERS_TMP
        local SERVER_TOTAL=${#ALL_USERS_TMP[@]}
        log " 👥 cPanel Accounts ที่เลือก : ${TOTAL_ACCOUNTS} accounts (เลือกจาก ${SERVER_TOTAL})"
    else
        log " 👥 cPanel Accounts            : ${TOTAL_ACCOUNTS} accounts"
    fi
    log "    /home  : ${COUNT_HOME1} | /home2 : ${COUNT_HOME2} | ทั้งคู่ : ${COUNT_BOTH}"
    log "--------------------------------------"
    log " รวม WordPress          : $(( CORRECT + FIXED + FAILED + SKIPPED )) เว็บ (นับจากผลจริง)"
    log " ✔️  Object Cache Already Set : ${CORRECT} เว็บ (ตั้งค่าไว้ถูกต้องอยู่แล้ว)"
    log " 🔧 Object Cache Fixed        : ${FIXED} เว็บ (อัปเดตเรียบร้อย)"
    log " ❌ แก้ไขไม่สำเร็จ            : ${FAILED} เว็บ"
    log " ⏭  ข้ามทั้งหมด               : ${SKIPPED} เว็บ"
    log " เวลาที่ใช้                   : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
    log "======================================"

    # Summary banner (with colors)
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║  ${WHITE}${BOLD}SUMMARY${RESET}${BLUE}                                                      ║${RESET}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
    printf  "${BLUE}║${RESET}  Total WordPress    : ${WHITE}%-4d${RESET}%-32s${BLUE}║${RESET}\n" "$TOTAL_SITES" ""
    printf  "${BLUE}║${RESET}  ${GREEN}Already OK${RESET}         : ${GREEN}%-4d${RESET}%-32s${BLUE}║${RESET}\n" "$CORRECT" ""
    printf  "${BLUE}║${RESET}  ${CYAN}Fixed${RESET}              : ${CYAN}%-4d${RESET}%-32s${BLUE}║${RESET}\n" "$FIXED" ""
    printf  "${BLUE}║${RESET}  ${RED}Failed${RESET}             : ${RED}%-4d${RESET}%-32s${BLUE}║${RESET}\n" "$FAILED" ""
    printf  "${BLUE}║${RESET}  ${YELLOW}Skipped${RESET}            : ${YELLOW}%-4d${RESET}%-32s${BLUE}║${RESET}\n" "$SKIPPED" ""
    echo -e "${BLUE}║${RESET}  ${DIM}Log : ${LOG_FILE}${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"

    # Telegram notification
    send_telegram "$mode_label" "$TOTAL_SITES" "$CORRECT" "$FIXED" "$FAILED" "$SKIPPED" "$ELAPSED" "$ACCOUNTS_LABEL"
}

###############################################################################
# is_quit_keyword — รับ q / Q / quit / exit  (Q10 = C)
###############################################################################
is_quit_keyword() {
    local input="${1,,}"   # lowercase
    case "$input" in
        q|quit|exit) return 0 ;;
        *) return 1 ;;
    esac
}

###############################################################################
# select_cpanel_accounts — Mode 2 prompt loop with strict validation
# Q9.1 = max retry 3 + พิมพ์ q ออกได้
# Q9.2 = Enter เปล่า = re-prompt
# Q9.3 = แจ้ง error ทุกตัวที่ผิดในรอบเดียว
# Q10  = รับ q / Q / quit / exit
#
# ผลลัพธ์ผ่าน global SELECTED_USERS array
###############################################################################
select_cpanel_accounts() {
    local -n _list=$1
    local total=${#_list[@]}

    SELECTED_USERS=()

    local attempt=0
    while (( attempt < MAX_RETRY )); do
        (( attempt++ ))

        echo ""
        printf "${WHITE}เลือก [1-%d] (q = ออก): ${RESET}" "$total"
        read -r RAW_SEL

        # Q10: keyword ออก
        local trimmed
        trimmed=$(echo "$RAW_SEL" | xargs)
        if is_quit_keyword "$trimmed"; then
            echo -e "${YELLOW}ยกเลิกการทำงาน${RESET}"
            exit 0
        fi

        # Q9.2: Enter เปล่า
        if [[ -z "$trimmed" ]]; then
            echo -e "  ${RED}[ERROR]${RESET} ไม่ได้เลือกหมายเลขใด"
            if (( attempt < MAX_RETRY )); then
                echo -e "  ${YELLOW}กรุณาพิมพ์ใหม่ทั้งหมดอีกครั้ง (ครั้งที่ ${attempt}/${MAX_RETRY})${RESET}"
                continue
            else
                echo -e "  ${RED}เกินจำนวนครั้งที่กำหนด (${MAX_RETRY} ครั้ง) — ยกเลิกการทำงาน${RESET}"
                exit 1
            fi
        fi

        # Q9.3: validate ทุกตัว → เก็บ error ทั้งหมด
        local -a errors=()
        local -a candidates=()
        for sel in $(echo "$RAW_SEL" | tr ',' ' '); do
            if [[ "$sel" =~ ^[0-9]+$ ]]; then
                # ใช้ 10# prefix เพื่อบังคับให้ bash ตีเป็นเลขฐาน 10
                # (กัน bug ตอน user พิมพ์ "08", "09" ซึ่ง bash จะ ตีเป็น octal → error)
                local idx=$(( 10#$sel - 1 ))
                if (( idx >= 0 && idx < total )); then
                    candidates+=("${_list[$idx]}")
                else
                    errors+=("หมายเลข ${sel} ไม่มีใน list")
                fi
            else
                errors+=("'${sel}' ไม่ใช่หมายเลข")
            fi
        done

        # ถ้ามี error แม้แต่ตัวเดียว → re-prompt
        if [[ ${#errors[@]} -gt 0 ]]; then
            for e in "${errors[@]}"; do
                echo -e "  ${RED}[ERROR]${RESET} $e"
            done
            if (( attempt < MAX_RETRY )); then
                echo -e "  ${YELLOW}กรุณาพิมพ์ใหม่ทั้งหมดอีกครั้ง (ครั้งที่ ${attempt}/${MAX_RETRY})${RESET}"
                continue
            else
                echo -e "  ${RED}เกินจำนวนครั้งที่กำหนด (${MAX_RETRY} ครั้ง) — ยกเลิกการทำงาน${RESET}"
                exit 1
            fi
        fi

        # ถ้าไม่มี candidate (เป็น whitespace อย่างเดียว) → re-prompt
        if [[ ${#candidates[@]} -eq 0 ]]; then
            echo -e "  ${RED}[ERROR]${RESET} ไม่ได้เลือกหมายเลขใด"
            if (( attempt < MAX_RETRY )); then
                echo -e "  ${YELLOW}กรุณาพิมพ์ใหม่ทั้งหมดอีกครั้ง (ครั้งที่ ${attempt}/${MAX_RETRY})${RESET}"
                continue
            else
                echo -e "  ${RED}เกินจำนวนครั้งที่กำหนด (${MAX_RETRY} ครั้ง) — ยกเลิกการทำงาน${RESET}"
                exit 1
            fi
        fi

        # ✅ ผ่าน — dedup + sort
        mapfile -t SELECTED_USERS < <(printf '%s\n' "${candidates[@]}" | sort -u)
        return 0
    done
}

###############################################################################
# confirm_yn — รับ y/N + รองรับ q/quit/exit
###############################################################################
confirm_yn() {
    local prompt="$1"
    printf "%b" "$prompt"
    read -r ANS
    if is_quit_keyword "$ANS"; then
        echo -e "${YELLOW}ยกเลิกการทำงาน${RESET}"
        exit 0
    fi
    [[ "${ANS,,}" == "y" ]]
}

###############################################################################
# MAIN
###############################################################################
check_requirements
print_header

# ─── Menu ───────────────────────────────────────────────────────────────────
echo -e "${WHITE}${BOLD}เลือกโหมดการทำงาน:${RESET}"
echo ""
echo -e "  ${CYAN}1.${RESET}  ตั้งค่า Object Cache ${WHITE}ทุกเว็บ${RESET} ในเซิร์ฟเวอร์นี้ทั้งหมด"
echo -e "  ${CYAN}2.${RESET}  เลือกตั้งค่าเฉพาะบาง ${WHITE}cPanel${RESET} ในเซิร์ฟเวอร์นี้"
echo ""
echo -e "  ${DIM}(พิมพ์ q / quit / exit เพื่อออกได้ตลอด)${RESET}"
echo ""
printf "${WHITE}กรุณาเลือก [1-2]: ${RESET}"
read -r MODE

# รองรับ keyword ออกที่เมนูหลัก
trimmed_mode=$(echo "$MODE" | xargs)
if is_quit_keyword "$trimmed_mode"; then
    echo -e "${YELLOW}ยกเลิกการทำงาน${RESET}"
    exit 0
fi

declare -a ALL_CPANEL_USERS=()
get_all_cpanel_users ALL_CPANEL_USERS

if [[ ${#ALL_CPANEL_USERS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} ไม่พบ cPanel accounts ใน /etc/trueuserdomains"
    exit 1
fi

case "$MODE" in
    1)
        # ───── Mode 1: All cPanel ─────
        print_header
        echo -e "${WHITE}${BOLD}[ Mode 1 ]  Setup Object Cache — ทุก cPanel account${RESET}"
        echo ""
        echo -e "${CYAN}cPanel accounts ที่มีในระบบ (${#ALL_CPANEL_USERS[@]} accounts):${RESET}"
        echo ""
        for u in "${ALL_CPANEL_USERS[@]}"; do
            echo -e "  ${GREEN}•${RESET}  $u"
        done
        echo ""
        echo -e "  ${DIM}(พิมพ์ q / quit / exit เพื่อออก)${RESET}"
        echo ""
        if confirm_yn "${YELLOW}ยืนยันการตั้งค่า Object Cache บนทุก cPanel ข้างบน? [y/N]: ${RESET}"; then
            print_header
            run_setup "Mode 1: ทั้งเซิร์ฟเวอร์"
        else
            echo -e "${RED}ยกเลิก${RESET}"
            exit 0
        fi
        ;;

    2)
        # ───── Mode 2: Select cPanel ─────
        print_header
        echo -e "${WHITE}${BOLD}[ Mode 2 ]  เลือก cPanel account${RESET}"
        echo ""
        echo -e "${CYAN}cPanel accounts ที่มีในระบบ (${#ALL_CPANEL_USERS[@]} accounts):${RESET}"
        echo ""
        for i in "${!ALL_CPANEL_USERS[@]}"; do
            printf "  ${CYAN}%3d.${RESET}  %s\n" "$(( i + 1 ))" "${ALL_CPANEL_USERS[$i]}"
        done
        echo ""
        echo -e "${YELLOW}เลือกหมายเลข (คั่นด้วย space หรือ comma)${RESET}"
        echo -e "${DIM}เช่น:  1 3 5   หรือ   1,3,5${RESET}"

        # Loop with strict validation
        SELECTED_USERS=()
        select_cpanel_accounts ALL_CPANEL_USERS

        echo ""
        echo -e "${CYAN}cPanel ที่เลือก (${#SELECTED_USERS[@]} accounts):${RESET}"
        for u in "${SELECTED_USERS[@]}"; do
            echo -e "  ${GREEN}✔${RESET}  $u"
        done
        echo ""
        if confirm_yn "${YELLOW}ยืนยันการตั้งค่า Object Cache บน cPanel ข้างบน? [y/N]: ${RESET}"; then
            print_header
            run_setup "Mode 2: เลือกบาง cPanel" "${SELECTED_USERS[@]}"
        else
            echo -e "${RED}ยกเลิก${RESET}"
            exit 0
        fi
        ;;

    *)
        echo -e "${RED}[ERROR]${RESET} กรุณาเลือก 1 หรือ 2"
        exit 1
        ;;
esac
