#!/bin/bash

# sync time and date
/etc/init.d/chronyd restart
sleep 1

[ -e /etc/enigma2/settings ] && exit 0

ROOTFS=/
LOG=/home/root/FastRestore.log


PY=python
[[ -e /usr/bin/python3 ]] && PY=python3

do_panic() {
	rm /media/*/images/config/noplugins 2>/dev/null || true
	rm /media/*/images/config/settings 2>/dev/null || true
	rm /media/*/images/config/plugins 2>/dev/null || true
	exit 0
}

get_restoremode() {
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
		echo "RestoreMode: mount: $(basename "$folder") settings: $settings" >> "$LOG"
		echo "RestoreMode: mount: $(basename "$folder") noplugins: $noplugins" >> "$LOG"
		echo "RestoreMode: mount: $(basename "$folder") plugins: $plugins" >> "$LOG"
		echo "RestoreMode: mount: $(basename "$folder") slow: $slow" >> "$LOG"
		echo "RestoreMode: mount: $(basename "$folder") fast: $fast" >> "$LOG"
		echo "RestoreMode: mount: $(basename "$folder") turbo: $turbo" >> "$LOG"
	done

	# If "noplugins" and "plugins" is set at the same time, "plugins" wins
	noplugins=$((noplugins & ! plugins))


	# if neither "plugins" nor "noplugins" are set, fall back to "slow", because "ask user" can not be done in a boot script
	# "slow" takes precedence over "fast"/"turbo" if explicitely set
	fast=$((settings & (plugins | noplugins) & ! slow))
	echo "RestoreMode: final settings: $settings" >> "$LOG"
	echo "RestoreMode: final noplugins: $noplugins" >> "$LOG"
	echo "RestoreMode: final plugins: $plugins" >> "$LOG"
	echo "RestoreMode: final slow: $slow" >> "$LOG"
	echo "RestoreMode: final fast: $fast" >> "$LOG"
	echo "RestoreMode: final turbo: $turbo" >> "$LOG"
}

get_backupset() {
	backuplocation=$($PY - <<END
import sys
sys.path.append('/usr/lib/enigma2/python')
from boxbranding import getBoxType, getMachineBrand, getMachineName, getImageDistro
boxtype = getBoxType()
distro = getImageDistro()
if boxtype in ('maram9', 'classm', 'axodin', 'axodinc', 'starsatlx', 'genius', 'evo', 'galaxym6') and not path.exists("/media/hdd/backup_%s_%s" % (distro, boxtype)):
	backuplocation = '/media/backup/backup_'
else:
	backuplocation = '/media/hdd/backup_'
print(backuplocation+distro+"_"+boxtype)
END
	)
}

get_boxtype() {
	boxtype=$($PY - <<END
import sys
sys.path.append('/usr/lib/enigma2/python')
from boxbranding import getBoxType, getMachineBrand, getMachineName, getImageDistro
boxtype = getBoxType()
print(boxtype)
END
	)
}

show_logo() {
	BOOTLOGO=/usr/share/restore.mvi
	[ ! -e $BOOTLOGO ] && BOOTLOGO=/usr/share/bootlogo.mvi
	[ -e $BOOTLOGO ] && nohup $(/usr/bin/showiframe ${BOOTLOGO}) >/dev/null 2>&1 &
}

lock_device() {
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
	RIGHTSET=$($PY - <<END
import sys
sys.path.append('/usr/lib/enigma2/python/Plugins/SystemPlugins/SoftwareManager')
import ShellCompatibleFunctions
print(ShellCompatibleFunctions.MANDATORY_RIGHTS)
END
	)
}

get_blacklist() {
	BLACKLIST=$($PY - <<END
import sys
sys.path.append('/usr/lib/enigma2/python/Plugins/SystemPlugins/SoftwareManager')
import ShellCompatibleFunctions
TMPLIST=ShellCompatibleFunctions.BLACKLISTED
TMPLIST.insert(0, "")
print(" --exclude=".join(TMPLIST))
END
	)
}

do_restoreUserDB() {
	$($PY - <<END
import sys
sys.path.append('/usr/lib/enigma2/python/Plugins/SystemPlugins/SoftwareManager')
from ShellCompatibleFunctions import restoreUserDB
restoreUserDB()
END
	)
}

restore_settings() {
	echo >>$LOG
	echo "Extracting saved settings from $backuplocation/enigma2settingsbackup.tar.gz" >> $LOG
	echo >>$LOG
	get_rightset
	get_blacklist
	tar -C $ROOTFS -xzvf $backuplocation/enigma2settingsbackup.tar.gz ${BLACKLIST} >>$LOG 2>>$LOG
	eval ${RIGHTSET} >>$LOG 2>>$LOG
	do_restoreUserDB
	touch /etc/.restore_skins
	echo >>$LOG
}

# Function to check if a given string is a valid IPv4 address
is_valid_ipv4() {
    local ip=$1
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to check if a given string is a valid IPv6 address
is_valid_ipv6() {
    local ip=$1
    if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    else
        return 1
    fi
}

restart_network() {
	echo >>$LOG
	echo "Restarting network ..." >>$LOG
	echo >>$LOG
	[ -e "${ROOTFS}etc/init.d/hostname.sh" ] && ${ROOTFS}etc/init.d/hostname.sh
	[ -e "${ROOTFS}etc/init.d/networking" ] && ${ROOTFS}etc/init.d/networking restart >>$LOG
	sleep 3
	nameserversdns_conf="/etc/enigma2/nameserversdns.conf"
	resolv_conf="/etc/resolv.conf"

	# Check if the file /etc/enigma2/nameserversdns.conf exists
	if [ -f "$nameserversdns_conf" ]; then
		# Extract IP addresses from nameserversdns.conf
		echo >>$LOG
		echo "Found nameserversdns.conf" >>$LOG
		ip_addresses=$(grep -Eo '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)|([0-9a-fA-F:]+)' "$nameserversdns_conf")
		valid_ip_found=false
		# Loop through each extracted IP address
		for ip in $ip_addresses; do
			if is_valid_ipv4 "$ip" || is_valid_ipv6 "$ip"; then
				valid_ip_found=true
				echo >>$LOG
				echo "Found valid ip in nameserversdns.conf" >>$LOG
				break
			fi
		done
		if $valid_ip_found; then
			# Replace /etc/resolv.conf with the content of nameserversdns.conf
			echo >>$LOG
			echo "Replace /etc/resolv.conf with the content of nameserversdns.conf" >>$LOG
			cat "$nameserversdns_conf" > "$resolv_conf"
		fi
	fi
	x=0
	while [ $x -lt 15 ]; do
	        ping -c 1 www.google.com | grep -q "1 received" && break
		ping6 -c 1 www.google.com | grep -q "1 received" && break
	        x=$((x+1))
	done
	echo "Waited about $((x+3)) seconds for network reconnect." >>$LOG 2>>$LOG
	echo >>$LOG
}

restore_plugins() {
	# Restore plugins ...
	echo >>$LOG
	echo "Re-installing previous plugins" >> $LOG
	echo >>$LOG
	echo "Updating feeds ..." >> $LOG
	opkg update >>$LOG 2>>$LOG
	echo >>$LOG
	echo "Installing feeds from feeds ..." >> $LOG
	allpkgs=$(<${ROOTFS}tmp/installed-list.txt)
	pkgs=""
	for pkg in $allpkgs; do
		if echo $pkg | grep -q "\-feed\-"; then
			opkg --force-overwrite install $pkg >>$LOG 2>>$LOG || true
			opkg update >>$LOG 2>>$LOG || true
		else
			pkgs="$pkgs $pkg"
		fi
	done
	echo >>$LOG
	echo "Installing plugins from local media ..." >> $LOG
	for i in hdd mmc usb backup; do
		if ls /media/${i}/images/ipk/*.ipk >/dev/null 2>/dev/null; then
			echo >>$LOG
			echo "${i}:" >>$LOG
			opkg install /media/${i}/images/ipk/*.ipk >>$LOG 2>>$LOG
		fi
	done
	echo >>$LOG
	echo "Installing plugins from feeds ..." >> $LOG
	opkg --force-overwrite install $pkgs >>$LOG 2>>$LOG
	echo >>$LOG
}

remove_plugins() {
	# remove plugins ...
	echo >>$LOG
	echo "manually removed by the user plugins" >> $LOG
	echo >>$LOG
	allpkgs=$(<${ROOTFS}tmp/removed-list.txt)
	for pkg in $allpkgs; do
		opkg --autoremove --force-depends remove $pkg >>$LOG 2>>$LOG || true
	done
	echo >>$LOG
}

restart_services() {
	echo >>$LOG
	echo "Running in turbo mode ... remounting and restarting some services ..." >>$LOG
	echo >>$LOG

	# Linux might have initialized swap on some devices that we need to unmount ...
	[ -x /sbin/swapoff ] && swapoff -a -e 2>/dev/null
	if [ -e /etc/ld.so.conf ] ; then
		/sbin/ldconfig
	fi
	mounts=$(mount | grep -E '(^/dev/s|\b\cifs\b|\bnfs\b|\bnfs4\b)' | awk '{ print $1 }')

	for i in $mounts; do
		echo "Unmounting $i ..." >>$LOG
		umount $i >>$LOG 2>>$LOG
	done
	[ -e "${ROOTFS}etc/init.d/volatile-media.sh" ] && ${ROOTFS}etc/init.d/volatile-media.sh
	echo >>$LOG
	echo "Mounting all local filesystems ..." >>$LOG
	mount -a -t nonfs,nfs4,smbfs,cifs,ncp,ncpfs,coda,ocfs2,gfs,gfs2,ceph -O no_netdev >>$LOG 2>>$LOG
	mdev -s
	[ -x /sbin/swapon ] && swapon -a 2>/dev/null
	echo >>$LOG
	echo "Backgrounding service restarts ..." >>$LOG
	[ -e "${ROOTFS}etc/init.d/modutils.sh" ] && ${ROOTFS}etc/init.d/modutils.sh >/dev/null >&1
	[ -e "${ROOTFS}etc/init.d/modload.sh" ] && ${ROOTFS}etc/init.d/modload.sh >/dev/null >&1
	echo >>$LOG
}

[ -e /media/*/panic.update ] && do_panic

echo "blkid:" >>$LOG
blkid >>$LOG
echo >>$LOG
echo "mounts:" >>$LOG
mount >>$LOG
echo >>$LOG

get_restoremode

# Only continue in fast mode (includes turbo mode)
[ $fast -eq 1 ] || exit 0

get_backupset

# Exit if there is no backup set
[ ! -e "$backuplocation/enigma2settingsbackup.tar.gz" ] && exit 0

# Show "FastRestore in progress ..." boot logo
show_logo

# Lock LCD
lock_device

# Begin logging
echo "FastRestore is restoring settings ..." > $LOG
echo >> $LOG
echo >> $LOG

# Restore settings ...
restore_settings
spinner $! "Settings "
echo >>$LOG

# Restart network ...
(restart_network) &
spinner $! "Network "
echo >>$LOG

# Restart certain services and remount media in "turbo" mode ...
(restart_services)

if [ $plugins -eq 1 ] && [ -e ${ROOTFS}tmp/installed-list.txt ]; then
	(restore_plugins) &
	spinner $! "Plugins "
	echo >>$LOG
fi

if [ $plugins -eq 1 ] && [ -e ${ROOTFS}tmp/removed-list.txt ]; then
	(remove_plugins) &
	spinner $! "Plugins "
	echo >>$LOG
fi

for i in hdd mmc usb backup; do
	# Execute MyRestore ...
	if [ -e /media/${i}/images/config/myrestore.sh ]; then
		echo >>$LOG
		echo "Executing MyRestore script in $i" >> $LOG
		(. /media/${i}/images/config/myrestore.sh >>$LOG 2>>$LOG) &
		spinner $! "MyRestore "
		echo >>$LOG
	fi
done


# Reboot here if running in "fast" mode ...
[ $turbo -eq 0 ] && echo "Running in fast mode ... reboot ..." >>$LOG && sync && reboot


# Restart certain services and remount media in "turbo" mode ...
(restart_services) &
spinner $! "Finishing "


if [ "x$DEV" != "x/dev/null" ]; then
	# Print "OpenATV" in LCD and unlock LCD ...
	echo -n "OpenATV" >&200
	flock -u 200
fi

exit 0
