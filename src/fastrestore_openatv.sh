#!/bin/sh
# FastRestore (busybox/ash, POSIX-ish)

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
    # Log a command and stream its output line by line
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

    # Scan direct subfolders in /media
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

    # Conflict: if both set, "plugins" wins over "noplugins"
    if [ "$plugins" -eq 1 ]; then noplugins=0; fi
    # Fast if settings and (plugins|noplugins) and not slow
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
    # Use '.' instead of 'source' for POSIX sh
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
    # Use sed instead of grep -P
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
    # Extract files
    tar -C "$ROOTFS" -xzvf "$backuplocation/enigma2settingsbackup.tar.gz" ${BLACKLIST} >>"$LOG" 2>>"$LOG" || true
    # Apply mandatory permissions
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

restore_plugins() {
    log ""
    log "Re-installing previous plugins"
    log ""

    log "Updating feeds ..."
    opkg update 2>&1 | while IFS= read -r line; do log "$line"; done

    log ""
    log "Installing feed meta-packages if any ..."
    allpkgs="$(cat "${ROOTFS}tmp/installed-list.txt" 2>/dev/null || echo "")"
    pkgs=""
    for pkg in $allpkgs; do
        echo "$pkg" | grep -q -- '-feed-' && {
            opkg --force-overwrite install "$pkg" 2>&1 | while IFS= read -r line; do log "$line"; done || true
            opkg update 2>&1 | while IFS= read -r line; do log "$line"; done || true
        } || pkgs="$pkgs $pkg"
    done

    if [ -f /usr/lib/package.lst ]; then
        log ""
        log "Filtering blacklisted packages from install list ..."
        blacklist="$(awk '{print $1}' /usr/lib/package.lst)"
        new_pkgs=""
        for pkg in $pkgs; do
            echo "$blacklist" | grep -qx "$pkg" && log "Skipping blacklisted package: $pkg" || new_pkgs="$new_pkgs $pkg"
        done
        pkgs="$new_pkgs"
        log ""
    fi

    log ""
    log "Installing plugins from local media ..."
    for i in hdd mmc usb backup; do
        if ls "/media/${i}/images/ipk/"*.ipk >/dev/null 2>&1; then
            log ""; log "${i}:"
            opkg install "/media/${i}/images/ipk/"*.ipk 2>&1 | while IFS= read -r line; do log "$line"; done
        fi
    done

    log ""
    log "Installing plugins from feeds (fast mode)..."
    TMPLOG=/tmp/opkg_install.log
    opkg --force-overwrite install $pkgs > "$TMPLOG" 2>&1
    ret=$?
    while IFS= read -r line; do log "$line"; done < "$TMPLOG"

    if [ "$ret" -ne 0 ]; then
        log "Fast install failed – falling back to per-package mode..."
        for pkg in $pkgs; do
            log "Installing $pkg ..."
            opkg --force-overwrite install "$pkg" > "$TMPLOG" 2>&1
            while IFS= read -r line; do log "$line"; done < "$TMPLOG"
        done
    fi
    log ""
}

remove_plugins() {
    log ""
    log "Plugins manually removed by the user"
    log ""
    allpkgs="$(cat "${ROOTFS}tmp/removed-list.txt" 2>/dev/null || echo "")"
    for pkg in $allpkgs; do
        opkg --autoremove --force-depends remove "$pkg" 2>&1 | while IFS= read -r line; do log "$line"; done || true
    done
    log ""
}

restart_services() {
    log ""
    log "Running in turbo mode ... remounting and restarting some services ..."
    log ""

    [ -x /sbin/swapoff ] && swapoff -a -e 2>/dev/null || true
    [ -e /etc/ld.so.conf ] && /sbin/ldconfig 2>/dev/null || true

    # Build list "device mountpoint" per line
    mounts="$(mount | awk '/^(\/dev\/s|cifs|nfs)/ {print $1 " " $3}')"
    rootdev="$(mount | awk '$3=="/"{print $1;exit}')"

    echo "$mounts" | while IFS= read -r line; do
        dev=$(printf "%s" "$line" | awk '{print $1}')
        mp=$(printf "%s" "$line" | awk '{print $2}')
        [ -z "$dev" ] || [ -z "$mp" ] && continue
        [ "$dev" = "$rootdev" ] && continue
        case "$mp" in
            /|/proc|/sys|/dev|/dev/pts|/run|/tmp) continue ;;
        esac
        log "Unmounting $dev on $mp ..."
        umount "$mp" 2>&1 | while IFS= read -r l; do log "$l"; done || true
    done

    [ -x "${ROOTFS}etc/init.d/volatile-media.sh" ] && ${ROOTFS}etc/init.d/volatile-media.sh
    log ""; log "Mounting all local filesystems ..."
    mount -a -t nonfs,nfs4,smbfs,cifs,ncp,ncpfs,coda,ocfs2,gfs,gfs2,ceph -O no_netdev 2>&1 | while IFS= read -r l; do log "$l"; done
    command -v udevadm >/dev/null 2>&1 && { udevadm trigger --action=add; udevadm settle; }
    [ -x /sbin/swapon ] && swapon -a 2>/dev/null || true
    log ""; log "Backgrounding service restarts ..."
    [ -x "${ROOTFS}etc/init.d/modutils.sh" ] && ${ROOTFS}etc/init.d/modutils.sh >/dev/null 2>&1 || true
    [ -x "${ROOTFS}etc/init.d/modload.sh" ]  && ${ROOTFS}etc/init.d/modload.sh  >/devnull 2>&1 || true
    log ""
}

# --- main flow ---
get_restoremode

if [ "$slow" -eq 1 ]; then
    get_backupset
    log "Slowrestore: backuplocation:$backuplocation"
    [ ! -e "$backuplocation/enigma2settingsbackup.tar.gz" ] && exit 0
    restore_rctype_settings
    log "Slowrestore: done."
    exit 0
fi

log "Fastrestore: fast:$fast"
[ "$fast" -eq 1 ] || exit 0

log "Fastrestore: start fast restore"
get_backupset
log "Fastrestore: backuplocation:$backuplocation"
[ ! -e "$backuplocation/enigma2settingsbackup.tar.gz" ] && exit 0

show_logo
lock_device
# Ensure LCD is unlocked and last message printed even on abrupt exit/reboot
trap 'if [ -e /proc/self/fd/200 ]; then printf "OpenATV" 1>&200; fi; command -v flock >/dev/null 2>&1 && flock -u 9 2>/dev/null || true' EXIT

log "FastRestore is restoring settings ..."
log ""; log ""

# Restore settings (foreground)
restore_settings

# Restart network (background + spinner)
(restart_network) &
spinner $! "Network"

# Turbo prep/remount (foreground)
(restart_services)

# Plugins add/remove (conditional, background + spinner)
if [ "$plugins" -eq 1 ] && [ -e "${ROOTFS}tmp/installed-list.txt" ]; then
    (restore_plugins) &
    spinner $! "Plugins install"
    log ""
fi
if [ "$plugins" -eq 1 ] && [ -e "${ROOTFS}tmp/removed-list.txt" ]; then
    (remove_plugins) &
    spinner $! "Plugins remove"
    log ""
fi

# MyRestore hooks
for i in hdd mmc usb backup; do
    if [ -e "/media/${i}/images/config/myrestore.sh" ]; then
        log ""; log "Executing MyRestore script in $i"
        ( . "/media/${i}/images/config/myrestore.sh" 2>&1 | while IFS= read -r line; do log "$line"; done ) &
        spinner $! "MyRestore"
        log ""
    fi
done

# Fast mode → reboot
if [ "$turbo" -eq 0 ]; then
    log "Running in fast mode ... reboot ..."
    sync
    reboot
fi

# Turbo mode (no immediate reboot): finalize
(restart_services) &
spinner $! "Finishing"

if [ -e /proc/self/fd/200 ]; then
    printf "OpenATV" 1>&200
    command -v flock >/dev/null 2>&1 && flock -u 200 2>/dev/null || true
fi

exit 0
