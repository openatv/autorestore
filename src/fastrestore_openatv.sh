#!/bin/bash

ROOTFS=/
LOG=/home/root/FastRestore.log
read STARTED _ < /proc/uptime

log() {
    read CURRENT _ < /proc/uptime
    local elapsed=$(printf "%5s" "$((${CURRENT%%.*} - ${STARTED%%.*}))")
    echo "[$elapsed sec] $*" >> "$LOG"
}

log "Fastrestore: start"
# sync time and date
/etc/init.d/chronyd restart
log "Fastrestore: chronyd restart"
sleep 1
log "Fastrestore: check settings"
[ -e /etc/enigma2/settings ] && exit 0
log "Fastrestore: settings not exist start settings-restore" 
PY=python
[[ -e /usr/bin/python3 ]] && PY=python3
log "Fastrestore: Python:$PY" 
do_panic() {
	log "Fastrestore:do_panic" 
	rm /media/*/images/config/noplugins 2>/dev/null || true
	rm /media/*/images/config/settings 2>/dev/null || true
	rm /media/*/images/config/plugins 2>/dev/null || true
	exit 0
}

get_restoremode() {
	log "Fastrestore:get_restoremode" 
	# Find all folders under /media
	media_folders=$(find /media -mindepth 1 -maxdepth 1 -type d)

	settings=0
	noplugins=0
	plugins=0
	slow=0
	fast=0
	turbo=1

	# Iterate through each folder found under /media
	for folder in $media_folders; do
		# Check if the specific config files exist in the current folder
		[ -e "$folder/images/config/settings" ] && settings=1
		[ -e "$folder/images/config/noplugins" ] && noplugins=1
		[ -e "$folder/images/config/plugins" ] && plugins=1
		[ -e "$folder/images/config/slow" ] && slow=1
		[ -e "$folder/images/config/fast" ] && fast=1 && turbo=0

		# Append results to the log file
		log "RestoreMode: mount: $(basename "$folder") settings: $settings" 
		log "RestoreMode: mount: $(basename "$folder") noplugins: $noplugins" 
		log "RestoreMode: mount: $(basename "$folder") plugins: $plugins" 
		log "RestoreMode: mount: $(basename "$folder") slow: $slow" 
		log "RestoreMode: mount: $(basename "$folder") fast: $fast" 
		log "RestoreMode: mount: $(basename "$folder") turbo: $turbo" 
	done

	# If "noplugins" and "plugins" is set at the same time, "plugins" wins
	noplugins=$((noplugins & ! plugins))


	# if neither "plugins" nor "noplugins" are set, fall back to "slow", because "ask user" can not be done in a boot script
	# "slow" takes precedence over "fast"/"turbo" if explicitely set
	fast=$((settings & (plugins | noplugins) & ! slow))
	log "RestoreMode: final settings: $settings" 
	log "RestoreMode: final noplugins: $noplugins" 
	log "RestoreMode: final plugins: $plugins" 
	log "RestoreMode: final slow: $slow" 
	log "RestoreMode: final fast: $fast" 
	log "RestoreMode: final turbo: $turbo" 
}

get_backupset() {
    log "Fastrestore:get_backupset" 
    source /usr/lib/enigma.info
    # Find all folders under /media
    media_folders=$(find /media -mindepth 1 -maxdepth 1 -type d)
    filename="enigma2settingsbackup.tar.gz"
    found_location=""
    
    # Iterate through all folders found under /media
    for folder in $media_folders; do
        log "Fastrestore:check backupset folder:$folder" 
        # Check if the backup file exists in the current folder
        if [ -e "$folder/backup_${distro}_${machinebuild}/${filename}" ]; then
            found_location="$folder/backup_${distro}_${machinebuild}"
            log "Fastrestore:check backupset found_location:$found_location" 
            break
        elif [ -e "$folder/backup_${distro}_${model}/${filename}" ]; then
            found_location="$folder/backup_${distro}_${model}"
            log "Fastrestore:check backupset found_location:$found_location" 
            break
        fi
    done
    
    # If no backup file is found in specific folders, set a default location
    if [ -z "$found_location" ]; then
        found_location="/media/hdd/backup_${distro}_${machinebuild}"
        log "Fastrestore:user fallback location:$found_location" 
    fi
    
    backuplocation="$found_location"
    log "Fastrestore:backuplocation:$backuplocation" 
}

get_boxtype() {
source /usr/lib/enigma.info
boxtype=${machinebuild}
}

show_logo() {
	log "Fastrestore:show_logo" 
	BOOTLOGO=/usr/share/restore.mvi
	[ ! -e $BOOTLOGO ] && BOOTLOGO=/usr/share/bootlogo.mvi
	[ -e $BOOTLOGO ] && nohup $(/usr/bin/showiframe ${BOOTLOGO}) >/dev/null 2>&1 &
}

lock_device() {
	log "Fastrestore:lock_device" 
	get_boxtype

	DEV=/dev/null
	for good in vusolo2 sf4008 sf5008; do
		if [ "$boxtype" == "$good" ]; then
			[ -e /dev/dbox/oled0 ] && DEV=/dev/dbox/oled0
			[ -e /dev/dbox/lcd0 ] && DEV=/dev/dbox/lcd0
		fi
	done

	if [ "x$DEV" != "x/dev/null" ]; then
		[ -e /proc/stb/lcd/oled_brightness ] && echo 255 > /proc/stb/lcd/oled_brightness || true
		exec 200>$DEV
		flock -n 200
	fi
}

spinner() {
	log "Fastrestore:spinner" 
	local pid=$1
	local task=$2
	local delay=0.025
	local spinstr='|/-\'
	while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
		local temp=${spinstr#?}
		spin=$(printf "%c" "$spinstr")
		local spinstr=$temp${spinstr%"$temp"}
		if [ "x$DEV" != "x/dev/null" ]; then
			echo -n "${task} ${spin}" 1>&200
		fi
		sleep $delay
	done
}

get_rightset() {
	log "Fastrestore:get_rightset" 
	RIGHTSET=$($PY - <<END
import sys
sys.path.append('/usr/lib/enigma2/python/Tools')
try:
	import ShellCompatibleFunctions
except ImportError:
	sys.path.append('/usr/lib/enigma2/python/Plugins/SystemPlugins/SoftwareManager')
	import ShellCompatibleFunctions
print(ShellCompatibleFunctions.MANDATORY_RIGHTS)
END
	)
}

get_blacklist() {
	log "Fastrestore:get_blacklist" 
	BLACKLIST=$($PY - <<END
import sys
sys.path.append('/usr/lib/enigma2/python/Tools')
try:
	import ShellCompatibleFunctions
except ImportError:
	sys.path.append('/usr/lib/enigma2/python/Plugins/SystemPlugins/SoftwareManager')
	import ShellCompatibleFunctions
TMPLIST=ShellCompatibleFunctions.BLACKLISTED
TMPLIST.insert(0, "")
print(" --exclude=".join(TMPLIST))
END
	)
}

do_restoreUserDB() {
	log "Fastrestore:do_restoreUserDB" 
	$($PY - <<END
import sys
sys.path.append('/usr/lib/enigma2/python/Tools')
try:
	from ShellCompatibleFunctions import restoreUserDB
	restoreUserDB()
except ImportError:
	sys.path.append('/usr/lib/enigma2/python/Plugins/SystemPlugins/SoftwareManager')
	from ShellCompatibleFunctions import restoreUserDB
	restoreUserDB()
END
	)
}

restore_rctype_settings() {
    log "" 
    log "Extracting saved settings from $backuplocation/enigma2settingsbackup.tar.gz" 
    log "" 

    # Extract the settings file from the tar.gz to a temporary location
    temp_settings=$(mktemp)
    tar -xzf "$backuplocation/enigma2settingsbackup.tar.gz" -O etc/enigma2/settings > "$temp_settings" 2>>$LOG

    # Check if the specific entry exists and extract its value
    rctype=$(grep -oP '^config\.plugins\.remotecontroltype\.rctype=\K.*' "$temp_settings")

    if [ -n "$rctype" ]; then
        log "Found remote control type: $rctype" 

        # Check if the target file exists in the proc filesystem
        if [ -e /proc/stb/ir/rc/type ]; then
            log "Writing remote control type to /proc/stb/ir/rc/type" 
            log "$rctype" > /proc/stb/ir/rc/type
        else
            log "/proc/stb/ir/rc/type does not exist, skipping." 
        fi
    else
        log "Remote control type not found in settings file." 
    fi

    # Clean up the temporary file
    rm -f "$temp_settings"
}


restore_settings() {
	log ""
	log "Extracting saved settings from $backuplocation/enigma2settingsbackup.tar.gz" 
	log ""
	get_rightset
	get_blacklist
	tar -C $ROOTFS -xzvf $backuplocation/enigma2settingsbackup.tar.gz ${BLACKLIST} >>$LOG 2>>$LOG
	eval ${RIGHTSET} >>$LOG 2>>$LOG
	do_restoreUserDB
	touch /etc/.restore_skins
	log ""
}

# Function to check if a given string is a valid IPv4 address
is_valid_ipv4() {
    log "Fastrestore:is_valid_ipv4" 
    local ip=$1
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to check if a given string is a valid IPv6 address
is_valid_ipv6() {
    log "Fastrestore:is_valid_ipv6" 
    local ip=$1
    if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    else
        return 1
    fi
}

restart_network() {
	log "" 
	log "Restarting network ..." 
	log "" 

	[ -e "${ROOTFS}etc/init.d/hostname.sh" ] && ${ROOTFS}etc/init.d/hostname.sh
	[ -e "${ROOTFS}etc/init.d/networking" ] && ${ROOTFS}etc/init.d/networking restart >>$LOG

	sleep 3
	nameserversdns_conf="/etc/enigma2/nameserversdns.conf"
	resolv_conf="/etc/resolv.conf"

	if [ -f "$nameserversdns_conf" ]; then
		log "" 
		log "Found nameserversdns.conf" 
		ip_addresses=$(grep -Eo '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)|([0-9a-fA-F:]+)' "$nameserversdns_conf")
		valid_ip_found=false
		for ip in $ip_addresses; do
			if is_valid_ipv4 "$ip" || is_valid_ipv6 "$ip"; then
				valid_ip_found=true
				log ""
				log "Found valid IP: $ip in nameserversdns.conf" 
				break
			fi
		done
		if $valid_ip_found; then
			log ""
			log "Replacing /etc/resolv.conf with content of nameserversdns.conf" 
			cat "$nameserversdns_conf" > "$resolv_conf"
		fi
	fi

	log ""
	log "Checking network connectivity (max 15s) ..."
	x=0
	while [ $x -lt 15 ]; do
		timestamp=$(date '+%Y-%m-%d %H:%M:%S')
		
		if ping -c 1 -W 1 www.google.com >/dev/null 2>&1; then
			log "$timestamp - ping IPv4 successful"
			break
		else
			log "$timestamp - ping IPv4 failed"
		fi

		if ping6 -c 1 -W 1 www.google.com >/dev/null 2>&1; then
			log "$timestamp - ping IPv6 successful"
			break
		else
			log "$timestamp - ping IPv6 failed"
		fi

		x=$((x+1))
		sleep 1
	done

	total_wait=$((x+3))
	log "Waited about $total_wait seconds for network reconnect."
	log ""
}


restore_plugins() {
	# Restore plugins ...
	log ""
	log "Re-installing previous plugins" 
	log "" 
	log "Updating feeds ..." 
	opkg update 2>&1 | while IFS= read -r line; do
		log "$line"
	done

	log "" 
	log "Installing feeds from feeds ..." 
	allpkgs=$(<${ROOTFS}tmp/installed-list.txt)
	pkgs=""
	for pkg in $allpkgs; do
		if echo $pkg | grep -q "\-feed\-"; then
			opkg --force-overwrite install "$pkg" 2>&1 | while IFS= read -r line; do
				log "$line"
			done || true
			opkg update 2>&1 | while IFS= read -r line; do log "$line"; done || true
		else
			pkgs="$pkgs $pkg"
		fi
	done
	if [ -f /usr/lib/package.lst ]; then
		log ""
		log "Filtering blacklisted packages from install list ..."
		blacklist=$(awk '{print $1}' /usr/lib/package.lst)
		new_pkgs=""

		for pkg in $pkgs; do
			if echo "$blacklist" | grep -qx "$pkg"; then
				log "Skipping blacklisted package: $pkg"
			else
				new_pkgs="$new_pkgs $pkg"
			fi
		done
		pkgs="$new_pkgs"
		log ""
	fi
	log ""
	log "Installing plugins from local media ..." 
	for i in hdd mmc usb backup; do
		if ls /media/${i}/images/ipk/*.ipk >/dev/null 2>/dev/null; then
			log ""
			log "${i}:" 
			opkg install /media/${i}/images/ipk/*.ipk 2>&1 | while IFS= read -r line; do log "$line"; done
		fi
	done
	log ""
	log "Installing plugins from feeds (fast mode)..." 

	TMPLOG=/tmp/opkg_install.log

	opkg --force-overwrite install $pkgs > $TMPLOG 2>&1
	ret=$?

	while IFS= read -r line; do
		log "$line"
	done < $TMPLOG

	if [ $ret -ne 0 ]; then
		log "Fast install failed – falling back to safe per-package mode..."

		for pkg in $pkgs; do
			log "Installing $pkg ..."
			opkg --force-overwrite install $pkg > $TMPLOG 2>&1
			ret=$?
			while IFS= read -r line; do
				log "$line"
			done < $TMPLOG
		done
	fi
	log ""
}

remove_plugins() {
	# remove plugins ...
	log ""
	log "manually removed by the user plugins" 
	log ""
	allpkgs=$(<${ROOTFS}tmp/removed-list.txt)
	for pkg in $allpkgs; do
		opkg --autoremove --force-depends remove $pkg 2>&1 | while IFS= read -r line; do log "$line"; done || true
	done
	log "" 
}

restart_services() {
	log ""
	log "Running in turbo mode ... remounting and restarting some services ..." 
	log ""

	# Linux might have initialized swap on some devices that we need to unmount ...
	[ -x /sbin/swapoff ] && swapoff -a -e 2>/dev/null
	if [ -e /etc/ld.so.conf ] ; then
		/sbin/ldconfig
	fi
	mounts=$(mount | grep -E '(^/dev/s|\b\cifs\b|\bnfs\b|\bnfs4\b)' | awk '{ print $1 }')

	for i in $mounts; do
		log "Unmounting $i ..." 
		umount $i 2>&1 | while IFS= read -r line; do log "$line"; done
	done
	[ -e "${ROOTFS}etc/init.d/volatile-media.sh" ] && ${ROOTFS}etc/init.d/volatile-media.sh
	log "" 
	log "Mounting all local filesystems ..." 
	mount -a -t nonfs,nfs4,smbfs,cifs,ncp,ncpfs,coda,ocfs2,gfs,gfs2,ceph -O no_netdev 2>&1 | while IFS= read -r line; do log "$line"; done
	udevadm trigger --action=add
	udevadm settle
	[ -x /sbin/swapon ] && swapon -a 2>/dev/null
	log "" 
	log "Backgrounding service restarts ..." 
	[ -e "${ROOTFS}etc/init.d/modutils.sh" ] && ${ROOTFS}etc/init.d/modutils.sh >/dev/null >&1
	[ -e "${ROOTFS}etc/init.d/modload.sh" ] && ${ROOTFS}etc/init.d/modload.sh >/dev/null >&1
	log "" 
}

[ -e /media/*/panic.update ] && do_panic

log "blkid:" 
blkid 2>&1 | while IFS= read -r line; do log "$line"; done
log ""
log "mounts:" 
mount 2>&1 | while IFS= read -r line; do log "$line"; done
log ""

get_restoremode

if [ "$slow" -eq 1 ]; then
    get_backupset
    log "Slowrestore:get_backupset done, backuplocation:$backuplocation " 
    # Exit if there is no backup set
    [ ! -e "$backuplocation/enigma2settingsbackup.tar.gz" ] && exit 0
    restore_rctype_settings
    log "Slowrestore:get_restoremode done. slow:$SLOW" 
    exit 0
fi

log "Fastrestore:get_restoremode done. fast:$fast" 
# Only continue in fast mode (includes turbo mode)
[ $fast -eq 1 ] || exit 0
log "Fastrestore:start fast restore" 
get_backupset
log "Fastrestore:get_backupset done, backuplocation:$backuplocation " 
# Exit if there is no backup set
[ ! -e "$backuplocation/enigma2settingsbackup.tar.gz" ] && exit 0

# Show "FastRestore in progress ..." boot logo
show_logo

# Lock LCD
lock_device

# Begin logging
log "FastRestore is restoring settings ..." 
log ""
log ""

# Restore settings ...
restore_settings
spinner $! "Settings "
log ""

# Restart network ...
(restart_network) &
spinner $! "Network "
log ""

# Restart certain services and remount media in "turbo" mode ...
(restart_services)

if [ $plugins -eq 1 ] && [ -e ${ROOTFS}tmp/installed-list.txt ]; then
	(restore_plugins) &
	spinner $! "Plugins "
	log ""
fi

if [ $plugins -eq 1 ] && [ -e ${ROOTFS}tmp/removed-list.txt ]; then
	(remove_plugins) &
	spinner $! "Plugins "
	log ""
fi

for i in hdd mmc usb backup; do
	# Execute MyRestore ...
	if [ -e /media/${i}/images/config/myrestore.sh ]; then
		log "" 
		log "Executing MyRestore script in $i" 
		(. /media/${i}/images/config/myrestore.sh 2>&1 | while IFS= read -r line; do log "$line"; done) &
		spinner $! "MyRestore "
		log "" 
	fi
done


# Reboot here if running in "fast" mode ...
[ "$turbo" -eq 0 ] && { log "Running in fast mode ... reboot ..."; sync; reboot; }

# Restart certain services and remount media in "turbo" mode ...
(restart_services) &
spinner $! "Finishing "


if [ "x$DEV" != "x/dev/null" ]; then
	# Print "OpenATV" in LCD and unlock LCD ...
	echo -n "OpenATV" >&200
	flock -u 200
fi

exit 0
