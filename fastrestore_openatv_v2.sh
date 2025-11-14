#!/bin/sh
# FastRestore with fbprogress

ROOTFS=/
LOG=/home/root/FastRestore.log

# --- basic env ---
umask 022
PATH=/sbin:/bin:/usr/sbin:/usr/bin

# --- log helper with uptime-based timestamp + simple rotation ---
STARTED="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
rotate_log() {
    [ -f "$LOG" ] || return 0
    size="$(wc -c < "$LOG" 2>/dev/null || echo 0)"
    [ "$size" -gt 1048576 ] && { mv -f "$LOG" "$LOG.1" 2>/dev/null || true; : > "$LOG"; }
}
log() {
    rotate_log
    CURRENT="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
    elapsed=$((CURRENT - STARTED))
    printf '[%5d sec] %s\n' "$elapsed" "$*" >> "$LOG"
}
runlog() {
    log "+ $*"
    "$@" 2>&1 | while IFS= read -r line; do log "$line"; done
}

# --- single-instance lock (requires busybox flock applet) ---
LOCKFILE=/run/fastrestore.lock
mkdir -p /run 2>/dev/null || true
exec 9>"$LOCKFILE" 2>/dev/null
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { log "Another FastRestore instance is running. Exit."; exit 0; }
fi

# Kick chrony if available (helps with timestamps)
if [ -x /etc/init.d/chronyd ]; then
    runlog /etc/init.d/chronyd restart
else
    log "chronyd not available, skipping."
fi

log "Fastrestore: start"
log "Fastrestore: check settings"
[ -e /etc/enigma2/settings ] && exit 0

# Choose python interpreter
if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    PY=python3
fi
log "Fastrestore: Python: $PY"

do_panic() {
    log "Fastrestore: do_panic"
    rm /media/*/images/config/noplugins 2>/dev/null || true
    rm /media/*/images/config/settings 2>/dev/null || true
    rm /media/*/images/config/plugins 2>/dev/null || true
    exit 0
}

# Robust panic.update check
for __p in /media/*/panic.update; do
    [ -e "$__p" ] && do_panic
done

log "blkid:"
blkid 2>&1 | while IFS= read -r line; do log "$line"; done
log ""
log "mounts:"
mount 2>&1 | while IFS= read -r line; do log "$line"; done
log ""

get_restoremode() {
    log "Fastrestore: get_restoremode"

    settings=0 noplugins=0 plugins=0 slow=0 fast=0 turbo=1

    for folder in $(find /media -mindepth 1 -maxdepth 1 -type d 2>/dev/null); do
        [ -e "$folder/images/config/settings" ]  && settings=1
        [ -e "$folder/images/config/noplugins" ] && noplugins=1
        [ -e "$folder/images/config/plugins" ]   && plugins=1
        [ -e "$folder/images/config/slow" ]      && slow=1
        if [ -e "$folder/images/config/fast" ]; then fast=1; turbo=0; fi

        base="$(basename "$folder")"
        log "RestoreMode: mount: $base settings:$settings"
        log "RestoreMode: mount: $base noplugins:$noplugins"
        log "RestoreMode: mount: $base plugins:$plugins"
        log "RestoreMode: mount: $base slow:$slow"
        log "RestoreMode: mount: $base fast:$fast"
        log "RestoreMode: mount: $base turbo:$turbo"
    done

    if [ "$plugins" -eq 1 ]; then noplugins=0; fi
    if [ "$settings" -eq 1 ] && [ "$slow" -eq 0 ] && { [ "$plugins" -eq 1 ] || [ "$noplugins" -eq 1 ]; }; then
        fast=1
    else
        fast=0
    fi

    log "RestoreMode: final settings:$settings"
    log "RestoreMode: final noplugins:$noplugins"
    log "RestoreMode: final plugins:$plugins"
    log "RestoreMode: final slow:$slow"
    log "RestoreMode: final fast:$fast"
    log "RestoreMode: final turbo:$turbo"
}

get_backupset() {
    log "Fastrestore: get_backupset"
    [ -r /usr/lib/enigma.info ] && . /usr/lib/enigma.info
    media_folders="$(find /media -mindepth 1 -maxdepth 1 -type d 2>/dev/null)"
    filename="enigma2settingsbackup.tar.gz"
    found_location=""

    for folder in $media_folders; do
        log "Fastrestore: check backupset folder:$folder"
        if [ -e "$folder/backup_${distro}_${machinebuild}/${filename}" ]; then
            found_location="$folder/backup_${distro}_${machinebuild}"
            log "Fastrestore: found_location:$found_location"
            break
        elif [ -e "$folder/backup_${distro}_${model}/${filename}" ]; then
            found_location="$folder/backup_${distro}_${model}"
            log "Fastrestore: found_location:$found_location"
            break
        fi
    done

    if [ -z "$found_location" ]; then
        found_location="/media/hdd/backup_${distro}_${machinebuild}"
        log "Fastrestore: fallback location:$found_location"
    fi

    backuplocation="$found_location"
    log "Fastrestore: backuplocation:$backuplocation"
}

get_boxtype() {
    [ -r /usr/lib/enigma.info ] && . /usr/lib/enigma.info
    boxtype="$machinebuild"
}

show_logo() {
    log "Fastrestore: show_logo"
    BOOTLOGO=/usr/share/restore.mvi
    [ ! -e "$BOOTLOGO" ] && BOOTLOGO=/usr/share/bootlogo.mvi
    [ -e "$BOOTLOGO" ] && nohup /usr/bin/showiframe "$BOOTLOGO" >/dev/null 2>&1 &
}

lock_device() {
    log "Fastrestore: lock_device"
    get_boxtype
    DEV=/dev/null
    for good in vusolo2 sf4008 sf5008; do
        [ "$boxtype" = "$good" ] && {
            [ -e /dev/dbox/oled0 ] && DEV=/dev/dbox/oled0
            [ -e /dev/dbox/lcd0 ]  && DEV=/dev/dbox/lcd0
        }
    done
    if [ "$DEV" != "/dev/null" ]; then
        [ -e /proc/stb/lcd/oled_brightness ] && echo 255 > /proc/stb/lcd/oled_brightness || true
        exec 200>"$DEV"
        if command -v flock >/dev/null 2>&1; then flock -n 200; fi
    fi
}

spinner() {
    pid="$1"; task="$2"
    [ -n "$pid" ] || return 0
    log "Fastrestore: spinner for pid=$pid ($task)"
    spin='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        c=$(printf "%s" "$spin" | cut -c1)
        spin=$(printf "%s%s" "$(printf "%s" "$spin" | cut -c2-)" "$c")
        [ -e /proc/self/fd/200 ] && printf "%s %s\r" "$task" "$c" 1>&200 || true
        sleep 0.1
    done
}

# --- fbprogress integration with 78-char truncation ---------------------------
FBP_BIN=/usr/bin/fbprogress
FBP_PIPE=/tmp/fbprogress_pipe
FBP_ON=0
# Phase weights in percent (sum 100)
W_SETTINGS=20
W_NET=20
W_TURBO_PREP=10
W_PLUGINS_INSTALL=30
W_PLUGINS_REMOVE=5
W_MYRESTORE=10
W_FINISH=5

# sanitize and truncate text to max 78 characters (single line)
sanitize_and_trunc() {
    # replace newlines with spaces, trim to 78 bytes
    # Note: printf '%.78s' truncates safely for ASCII/UTF-8 byte count
    msg="$(printf '%s' "$*" | tr '\n' ' ')"
    printf '%.78s' "$msg"
}

fbp_safe_send() {
    [ "$FBP_ON" -eq 1 ] && [ -p "$FBP_PIPE" ] && printf "%s\n" "$*" > "$FBP_PIPE"
    return 0
}

progress_start() {
    if [ -x "$FBP_BIN" ]; then
        [ -p "$FBP_PIPE" ] && echo QUIT > "$FBP_PIPE" 2>/dev/null || true
        "$FBP_BIN" &
        for _ in 1 2 3 4 5; do
            [ -p "$FBP_PIPE" ] && break
            sleep 0.05
        done
        if [ -p "$FBP_PIPE" ]; then
            FBP_ON=1
            progress_set 0 "Starting restore..."
        fi
    fi
}

progress_end() {
    progress_set 100 "Done."
    if [ -p "$FBP_PIPE" ]; then
        i=0
        while [ $i -lt 5 ]; do
            echo QUIT > "$FBP_PIPE" 2>/dev/null && break
            i=$((i+1))
            sleep 0.5
        done
    fi
}

progress_set() {
    pct="$1"; shift
    raw="$*"
    [ -z "$raw" ] && raw="Working..."
    [ "$pct" -lt 0 ] && pct=0
    [ "$pct" -gt 100 ] && pct=100
    short="$(sanitize_and_trunc "$raw")"
    fbp_safe_send "$pct $short"
}

progress_phase_done() {
    current="$1"; weight="$2"; msg="$3"
    next=$((current + weight))
    [ "$next" -gt 100 ] && next=100
    progress_set "$next" "$msg"
    echo "$next"
}

progress_track_pid() {
    pid="$1"; start="$2"; end="$3"; label="$4"
    [ -n "$pid" ] || return 0
    [ -z "$start" ] && start=0
    [ -z "$end" ] && end=$((start+5))
    [ "$end" -lt "$start" ] && end="$start"
    max_ms=60000
    step_ms=300
    steps=$((max_ms / step_ms))
    inc=$(( (end - start) / (steps>0?steps:1) ))
    [ "$inc" -lt 1 ] && inc=1
    pct="$start"
    progress_set "$pct" "$label..."
    while kill -0 "$pid" 2>/dev/null; do
        pct=$((pct + inc))
        [ "$pct" -ge "$end" ] && pct=$((end-1))
        progress_set "$pct" "$label..."
        sleep 0.3
    done
    progress_set "$end" "$label: done"
}

# Detailed opkg display --------------------------------------------------------
progress_opkg_update() {
    start="$1"; end="$2"
    [ -z "$start" ] && start=0
    [ -z "$end" ] && end=$((start+5))

    pct="$start"
    progress_set "$pct" "opkg: updating feeds..."

    (
        opkg update 2>&1 | while IFS= read -r line; do
            log "$line"
            # Never update pct directly from opkg output → causes jumps
            progress_set "$pct" "opkg update: $line"
        done
    ) &
    upid=$!

    # Safe progress tracking
    step=$(( (end - start) / 30 ))
    [ "$step" -lt 1 ] && step=1

    while kill -0 "$upid" 2>/dev/null; do
        pct=$((pct + step))
        [ "$pct" -ge "$((end-1))" ] && pct=$((start + (pct-start)/2))
        progress_set "$pct" "opkg update running..."
        sleep 0.2
    done

    wait "$upid" 2>/dev/null || true
    progress_set "$end" "opkg update: done"
}


progress_opkg_packages() {
    mode="$1"; start="$2"; end="$3"; shift 3
    pkgs="$*"
    total=0; for _p in $pkgs; do total=$((total+1)); done
    [ "$total" -eq 0 ] && { progress_set "$end" "No packages to $mode"; return 0; }

    i=0
    for pkg in $pkgs; do
        i=$((i+1))
        pct=$(( start + (i* (end-start) / total) ))
        [ "$pct" -gt "$end" ] && pct="$end"
        label="opkg $mode ($i/$total): $pkg"

        TMPLOG=/tmp/opkg_${mode}_${pkg}.log
        : > "$TMPLOG"
        if [ "$mode" = "install" ]; then
            opkg --force-overwrite install "$pkg" 2>&1 | while IFS= read -r line; do
                echo "$line" >>"$TMPLOG"
                log "$line"
                case "$line" in
                    *"Downloading"*) progress_set "$pct" "$label : Downloading";;
                    *"Installing "*) progress_set "$pct" "$label : Installing";;
                    *"Upgrading "*)  progress_set "$pct" "$label : Upgrading";;
                    *"Configuring "*)progress_set "$pct" "$label : Configuring";;
                    *)               progress_set "$pct" "$label";;
                esac
            done
        else
            opkg --autoremove --force-depends remove "$pkg" 2>&1 | while IFS= read -r line; do
                echo "$line" >>"$TMPLOG"
                log "$line"
                case "$line" in
                    *"Removing "*) progress_set "$pct" "$label : Removing";;
                    *)             progress_set "$pct" "$label";;
                esac
            done
        fi
        pct_done=$(( pct > start ? pct : start+1 ))
        progress_set "$pct_done" "$label : done"
    done
    progress_set "$end" "opkg $mode: finished ($total packages)"
}
# -----------------------------------------------------------------------------

get_rightset() {
    log "Fastrestore: get_rightset"
    RIGHTSET="$(
$PY - <<'END'
import sys
sys.path.append('/usr/lib/enigma2/python/Tools')
try:
    import ShellCompatibleFunctions as SCF
except ImportError:
    sys.path.append('/usr/lib/enigma2/python/Plugins/SystemPlugins/SoftwareManager')
    import ShellCompatibleFunctions as SCF
print(SCF.MANDATORY_RIGHTS)
END
    )"
}

get_blacklist() {
    log "Fastrestore: get_blacklist"
    BLACKLIST="$(
$PY - <<'END'
import sys
sys.path.append('/usr/lib/enigma2/python/Tools')
try:
    import ShellCompatibleFunctions as SCF
except ImportError:
    sys.path.append('/usr/lib/enigma2/python/Plugins/SystemPlugins/SoftwareManager')
    import ShellCompatibleFunctions as SCF
tmplist = list(SCF.BLACKLISTED)
tmplist.insert(0, "")
print(" --exclude=".join(tmplist))
END
    )"
}

do_restoreUserDB() {
    log "Fastrestore: do_restoreUserDB"
$PY - <<'END'
import sys
sys.path.append('/usr/lib/enigma2/python/Tools')
try:
    from ShellCompatibleFunctions import restoreUserDB
except ImportError:
    sys.path.append('/usr/lib/enigma2/python/Plugins/SystemPlugins/SoftwareManager')
    from ShellCompatibleFunctions import restoreUserDB
restoreUserDB()
END
}

restore_rctype_settings() {
    log ""
    log "Extracting saved settings from $backuplocation/enigma2settingsbackup.tar.gz"
    log ""
    tmp_settings="$(mktemp 2>/dev/null || echo /tmp/settings.$$)"
    tar -xzf "$backuplocation/enigma2settingsbackup.tar.gz" -O etc/enigma2/settings > "$tmp_settings" 2>>"$LOG" || true
    rctype="$(sed -n 's/^config\.plugins\.remotecontroltype\.rctype=\(.*\)$/\1/p' "$tmp_settings" | tail -n1)"
    if [ -n "$rctype" ]; then
        log "Found remote control type: $rctype"
        if [ -e /proc/stb/ir/rc/type ]; then
            log "Writing remote control type to /proc/stb/ir/rc/type"
            echo "$rctype" > /proc/stb/ir/rc/type
        else
            log "/proc/stb/ir/rc/type does not exist, skipping."
        fi
    else
        log "Remote control type not found in settings file."
    fi
    rm -f "$tmp_settings"
}

restore_settings() {
    log ""
    log "Extracting saved settings from $backuplocation/enigma2settingsbackup.tar.gz"
    log ""
    get_rightset
    get_blacklist
    tar -C "$ROOTFS" -xzvf "$backuplocation/enigma2settingsbackup.tar.gz" ${BLACKLIST} >>"$LOG" 2>>"$LOG" || true
    if [ -n "$RIGHTSET" ]; then eval "$RIGHTSET" >>"$LOG" 2>>"$LOG" || true; fi
    do_restoreUserDB
    : > /etc/.restore_skins
    log ""
}

is_valid_ipv4() {
    ip="$1"
    echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}
is_valid_ipv6() {
    ip="$1"
    echo "$ip" | grep -Eq '^([0-9A-Fa-f]{0,4}:){1,7}[0-9A-Fa-f]{0,4}$'
}

restart_network() {
    log ""
    log "Restarting network ..."
    log ""

    [ -x "${ROOTFS}etc/init.d/hostname.sh" ] && ${ROOTFS}etc/init.d/hostname.sh
    [ -x "${ROOTFS}etc/init.d/networking" ] && ${ROOTFS}etc/init.d/networking restart >>"$LOG" 2>&1

    sleep 3
    nameserversdns_conf="/etc/enigma2/nameserversdns.conf"
    resolv_conf="/etc/resolv.conf"

    if [ -f "$nameserversdns_conf" ]; then
        log ""
        log "Found nameserversdns.conf"
        valid_ip_found=false
        for ip in $(grep -Eo '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)|([0-9A-Fa-f:]+)' "$nameserversdns_conf"); do
            if is_valid_ipv4 "$ip" || is_valid_ipv6 "$ip"; then valid_ip_found=true; log ""; log "Found valid IP: $ip in nameserversdns.conf"; break; fi
        done
        $valid_ip_found && { log ""; log "Replacing /etc/resolv.conf with nameserversdns.conf"; cat "$nameserversdns_conf" > "$resolv_conf"; }
    fi

    log ""
    log "Checking network connectivity (max 15s) ..."
    x=0
    while [ "$x" -lt 15 ]; do
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        if ping -c 1 -W 1 www.google.com >/dev/null 2>&1; then log "$ts - ping IPv4 successful"; break; else log "$ts - ping IPv4 failed"; fi
        if command -v ping6 >/dev/null 2>&1 && ping6 -c 1 -W 1 www.google.com >/dev/null 2>&1; then log "$ts - ping IPv6 successful"; break; else log "$ts - ping IPv6 failed"; fi
        x=$((x+1))
        sleep 1
    done
    total_wait=$((x+3))
    log "Waited about $total_wait seconds for network reconnect."
    log ""

    if [ -x /etc/init.d/chronyd ]; then
        runlog /etc/init.d/chronyd restart
    fi

    log ""
    log "Quick network check:"
    if command -v nslookup >/dev/null 2>&1; then
        nslookup google.com >/dev/null 2>&1 && log "DNS: OK (google.com resolved successfully)" || log "DNS: FAIL (hostname resolution failed)"
    else
        ping -c1 -W1 google.com >/dev/null 2>&1 && log "DNS: OK (via ping)" || log "DNS: FAIL (hostname resolution likely failed)"
    fi
    ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 && log "Internet (IPv4): OK" || log "Internet (IPv4): FAIL"
    if command -v ping6 >/dev/null 2>&1; then
        ping6 -c1 -W1 2606:4700:4700::1111 >/dev/null 2>&1 && log "Internet (IPv6): OK" || log "Internet (IPv6): FAIL"
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T5 -O /dev/null https://feeds2.mynonpublic.com/ >/dev/null 2>&1 && log "SSL: OK (HTTPS feeds2.mynonpublic.com)" \
        || wget -q -T5 -O /dev/null https://example.com >/dev/null 2>&1 && log "SSL: OK (HTTPS general connection)" \
        || log "SSL: FAIL (HTTPS request failed)"
    else
        log "SSL: SKIPPED (wget not installed)"
    fi
}

# FAST MODE helper: install local IPKs with progress
install_local_ipk_progress() {
    start="$1"; end="$2"
    found=0
    for i in hdd mmc usb backup; do
        for dir in \
            "/media/${i}/images/ipk" \
            "/media/${i}/plugins" \
            "/media/${i}/images/plugins"
        do
            if ls "$dir/"*.ipk >/dev/null 2>&1; then
                found=1
                progress_set "$start" "Installing local IPKs from ${dir##/media/}..."
                (
                    opkg install "$dir/"*.ipk 2>&1 | while IFS= read -r line; do
                        log "$line"
                        progress_set "$start" "local ipk: $line"
                    done
                ) &
                pid=$!
                progress_track_pid "$pid" "$start" "$end" "Local IPKs (${dir##/media/})"
                wait "$pid" 2>/dev/null || true
            fi
        done
    done
    [ "$found" -eq 0 ] && progress_set "$end" "No local IPKs found"
}


restart_services() {
    log ""
    log "Turbo mode: remounting and restarting services..."
    log ""

    set +e

    [ -x /sbin/swapoff ] && swapoff -a -e 2>/dev/null || true
    [ -e /etc/ld.so.conf ] && /sbin/ldconfig 2>/dev/null || true

    mounts="$(mount | awk '/^(\/dev\/s|cifs|nfs)/ {print $1 " " $3}')"
    rootdev="$(mount | awk '$3=="/" {print $1; exit}')"

    # FIX: no subshell! while with input redirection = safe
    while IFS= read -r line; do
        dev=$(printf "%s" "$line" | awk '{print $1}')
        mp=$(printf "%s" "$line" | awk '{print $2}')
        [ -z "$dev" ] || [ -z "$mp" ] && continue
        [ "$dev" = "$rootdev" ] && continue
        case "$mp" in /|/proc|/sys|/dev|/dev/pts|/run|/tmp) continue ;; esac

        log "Unmounting $dev on $mp ..."
        umount "$mp" 2>&1 | while IFS= read -r m; do log "$m"; done
    done <<EOF
$mounts
EOF

    [ -x "${ROOTFS}etc/init.d/volatile-media.sh" ] && \
        ${ROOTFS}etc/init.d/volatile-media.sh

    log "Mounting all local file systems..."
    mount -a -t nonfs,nfs4,smbfs,cifs,ncp,ncpfs,coda,ocfs2,gfs,gfs2,ceph \
        -O no_netdev 2>&1 | while IFS= read -r m; do log "$m"; done

    command -v udevadm >/dev/null 2>&1 && {
        udevadm trigger --action=add
        udevadm settle
    }

    [ -x /sbin/swapon ] && swapon -a 2>/dev/null || true

    log "Restarting modules in background..."
    [ -x "${ROOTFS}etc/init.d/modutils.sh" ] && \
        ${ROOTFS}etc/init.d/modutils.sh >/dev/null 2>&1
    [ -x "${ROOTFS}etc/init.d/modload.sh" ] && \
        ${ROOTFS}etc/init.d/modload.sh >/dev/null 2>&1

    log ""
}


get_restoremode

trap ' \
    if [ -e /proc/self/fd/200 ]; then printf "OpenATV" 1>&200; fi; \
    command -v flock >/dev/null 2>&1 && flock -u 9 2>/dev/null || true; \
    progress_end \
' EXIT

# ------------------------------- SLOW MODE ------------------------------------
if [ "$slow" -eq 1 ]; then
    get_backupset
    log "Slowrestore: backuplocation:$backuplocation"
    [ ! -e "$backuplocation/enigma2settingsbackup.tar.gz" ] && exit 0

    progress_start
    progress_set 0 "Slow restore started..."

    restore_rctype_settings
    progress_set 5 "Remote control type set"

    progress_opkg_update 5 20

    install_list="$(cat "${ROOTFS}tmp/installed-list.txt" 2>/dev/null || echo "")"
    remove_list="$(cat "${ROOTFS}tmp/removed-list.txt" 2>/dev/null || echo "")"

    if [ -n "$remove_list" ]; then
        progress_opkg_packages remove 20 30 $remove_list
    else
        progress_set 30 "No packages to remove"
    fi

    if [ -n "$install_list" ]; then
        progress_opkg_packages install 30 98 $install_list
    else
        progress_set 98 "No packages to install"
    fi

    progress_set 99 "Finalizing..."
    progress_end

    log "Slowrestore: done."
    exit 0
fi

# ------------------------------- FAST MODE ------------------------------------
log "Fastrestore: fast:$fast"
[ "$fast" -eq 1 ] || exit 0

log "Fastrestore: start fast restore"
get_backupset
log "Fastrestore: backuplocation:$backuplocation"
[ ! -e "$backuplocation/enigma2settingsbackup.tar.gz" ] && exit 0

show_logo
lock_device

progress_start
pct=0
progress_set "$pct" "Starting fast restore..."

log "FastRestore is restoring settings ..."
log ""; log ""

# 1) Restore settings (foreground)
restore_settings
pct=$(progress_phase_done "$pct" "$W_SETTINGS" "Settings restored")

# 2) Network (background + progress)
(restart_network) &
net_pid=$!
progress_track_pid "$net_pid" "$pct" $((pct+W_NET)) "Network"
wait "$net_pid" 2>/dev/null || true
pct=$((pct+W_NET))

# 3) Turbo prep/remount (foreground)
(restart_services)
pct=$(progress_phase_done "$pct" "$W_TURBO_PREP" "Services/Preparation")

# 4) Plugin restore (v1 logic + fbprogress + full debug, fixed pkgs overwrite)
if [ "$plugins" -eq 1 ] && [ -e "${ROOTFS}tmp/installed-list.txt" ]; then
    log ""
    log "====================[ FAST MODE: PLUGIN RESTORE ]===================="

    # 1) installed-list laden
    allpkgs="$(cat "${ROOTFS}tmp/installed-list.txt" 2>/dev/null || echo "")"
    log "Original installed-list.txt content:"
    for a in $allpkgs; do
        log "  LIST: $a"
    done

    # 2) feedmeta vs plugin_pkgs splitten
    feedmeta=""
    plugin_pkgs=""
    for p in $allpkgs; do
        case "$p" in
            *-feed-*) feedmeta="$feedmeta $p" ;;
            *)        plugin_pkgs="$plugin_pkgs $p" ;;
        esac
    done

    log "Feedmeta packages: ${feedmeta:-<none>}"
    log "Normal packages (pre-filter): ${plugin_pkgs:-<none>}"

    # 3) feedmeta installieren
    feeds_start="$pct"
    feeds_end=$((pct + 5))

    if [ -n "$feedmeta" ]; then
        log "Installing feedmeta packages..."
        # Achtung: progress_opkg_packages überschreibt globale 'pkgs'
        progress_opkg_packages install "$feeds_start" "$feeds_end" $feedmeta
    else
        log "No feedmeta packages found."
        progress_set "$feeds_end" "No meta feeds"
    fi

    # 4) opkg update nach feedmeta
    log "Running opkg update after feedmeta..."
    upd_start="$feeds_end"
    upd_end=$((upd_start + 5))
    progress_opkg_update "$upd_start" "$upd_end"

    # *** WICHTIG: Pluginliste jetzt explizit aus plugin_pkgs setzen ***
    pkgs="$plugin_pkgs"
    log "pkgs BEFORE any blacklist filter: ${pkgs:-<empty>}"

    # 5) Filter A: /usr/lib/package.lst
    log "Filter A: removing packages that exist in /usr/lib/package.lst"
    if [ -f /usr/lib/package.lst ]; then
        pkglist_names="$(awk '{print $1}' /usr/lib/package.lst)"
        log "package.lst contains $(echo "$pkglist_names" | wc -w) entries"

        log "pkgs BEFORE package.lst filter: ${pkgs:-<empty>}"
        filtered=""
        for p in $pkgs; do
            if printf '%s\n' "$pkglist_names" | grep -qx -- "$p"; then
                log "  A-FILTER: $p is in package.lst -> remove"
            else
                filtered="$filtered $p"
            fi
        done
        pkgs="$filtered"
        log "pkgs AFTER package.lst filter: ${pkgs:-<empty>}"
    else
        log "WARNING: /usr/lib/package.lst not found, skipping Filter A"
    fi

    # 6) Filter B: manuelle Blacklist
    log "Filter B: applying manual blacklist"
    MANUAL_BL="
bash-locale-*
nano*
mc*
*-locale-*
*-helpers*
glibc-*
libglib*
packagegroup-*
python3-multiprocessing
iptables-module-ip6t-ipv6header
tar-locale-*
"

    log "pkgs BEFORE manual blacklist: ${pkgs:-<empty>}"
    filtered2=""
    for p in $pkgs; do
        skip=0
        for pat in $MANUAL_BL; do
            [ -z "$pat" ] && continue
            case "$p" in
                $pat)
                    log "  B-FILTER: $p matches pattern '$pat' -> remove"
                    skip=1
                    break
                    ;;
            esac
        done
        [ "$skip" -eq 0 ] && filtered2="$filtered2 $p"
    done
    pkgs="$filtered2"
    log "pkgs AFTER manual blacklist: ${pkgs:-<empty>}"

    # 7) Verbleibende Pakete installieren
    install_start="$upd_end"
    install_end=$((install_start + W_PLUGINS_INSTALL))

    log "Final plugin install list: ${pkgs:-<empty>}"
    if [ -n "$pkgs" ]; then
        log "Starting plugin installation..."
        progress_opkg_packages install "$install_start" "$install_end" $pkgs
    else
        log "No plugins left to install after filtering."
        progress_set "$install_end" "No plugins to install"
    fi

    pct="$install_end"
    log "====================[ FAST MODE: PLUGIN RESTORE DONE ]===================="
    log ""
fi




# 5) Remove plugins (if any) with detailed progress
if [ "$plugins" -eq 1 ] && [ -e "${ROOTFS}tmp/removed-list.txt" ]; then
    rem_end=$((pct + W_PLUGINS_REMOVE))
    remove_list="$(cat "${ROOTFS}tmp/removed-list.txt" 2>/dev/null || echo "")"
    if [ -n "$remove_list" ]; then
        progress_opkg_packages remove "$pct" "$rem_end" $remove_list
    else
        progress_set "$rem_end" "No plugins to remove"
    fi
    pct="$rem_end"
fi

# 6) MyRestore hooks
hooks=""
for i in hdd mmc usb backup; do
    [ -e "/media/${i}/images/config/myrestore.sh" ] && hooks="$hooks $i"
done
if [ -n "$hooks" ]; then
    n=$(printf "%s\n" "$hooks" | wc -w)
    [ "$n" -eq 0 ] && n=1
    per=$(( W_MYRESTORE / n ))
    [ "$per" -lt 1 ] && per=1
    for i in $hooks; do
        end=$((pct + per))
        (
            . "/media/${i}/images/config/myrestore.sh" 2>&1 | while IFS= read -r line; do log "$line"; done
        ) &
        hp=$!
        progress_track_pid "$hp" "$pct" "$end" "MyRestore ($i)"
        wait "$hp" 2>/dev/null || true
        pct="$end"
    done
fi

# 7) Fast mode: reboot or finalize
if [ "$turbo" -eq 0 ]; then
    progress_set 99 "Rebooting..."
    sync
    reboot
fi

(restart_services) &
fin_pid=$!
progress_track_pid "$fin_pid" "$pct" $((pct + W_FINISH)) "Finalizing"
wait "$fin_pid" 2>/dev/null || true
pct=$((pct + W_FINISH))

if [ -e /proc/self/fd/200 ]; then
    printf "OpenATV" 1>&200
    command -v flock >/dev/null 2>&1 && flock -u 200 2>/dev/null || true
fi

progress_end
exit 0
