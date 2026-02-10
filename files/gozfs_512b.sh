#!/bin/sh

# Current Version: 1.55

# original script by Philipp Wuensche at http://anonsvn.h3q.com/s/gpt-zfsroot.sh
# This script is considered beer ware (http://en.wikipedia.org/wiki/Beerware)
# modifyed with great help of gkontos from http://www.aisecure.net/2011/05/01/root-on-zfs-freebsd-current/
# by Olaf Klein - monkeytower internet agency http://www.monkeytower.net
#
# DISCLAIMER: Use at your own risk! Always make backups, don't blame me if this renders your system unusable or you lose any data!
#
# This only works/only tested with FreeBSD 9.0 rc2, you have been warned!
#
# Startup the FreeBSD livefs (i used memstick). Go into the Fixit console. and prepare:
# tcsh
# set autolist
# umount /tmp
# mdmfs -s 512M md1 /tmp
# ifconfig
# dhclient nfe0 (or whatever your NIC is)
# mkdir -p /tmp/bsdinstall_etc
# echo nameserver 10.0.0.1 >/etc/resolv.conf
# cd /tmp
# fetch http://www.monkeytower.net/go9.sh
# chmod +x go9.sh
#
# Execute the script with the following parameter:
#
# -p sets the geom provider to use, you can use multiple. Add a name for the GPT labels: -p ad4=black -p ad6=white
# -s sets the swap_partition_size to create, you can use m/M for megabyte or g/G for gigabyte
# -S sets the zfs_partition_size to create, you can use m/M for megabyte or g/G for gigabyte, default is all available size
# -n sets the name of the zpool to create
# -m sets the zpool raid-mode, stripe (only single disk), mirror (at least two disks) and raidz (at least three disks) or raid10 with at least 4 disks
# -d sets local directory to get distribution packages from
#
# You can use more than one device, creating a mirror. To specify more than one device, use multiple -p options.
# eg. go.sh -p ad0 -p ad1 -s 512m -n tank
#
#
# in case something goes wrong and you want to start over:
# zpool destroy tank
# might be a good idea (_before_ you give it another try).
#
# enjoy. Feedback welcome to ok@monkeytower.net
#
# regards.
# olaf.

[ "${DEBUG:-}" = "1" ] && set -x

ftphost="ftp://ftp.de.freebsd.org/pub/FreeBSD/releases/amd64/amd64/12.3-BETA3/"
ftp_mirror_list="ftp6.ua ftp1.fr ftp2.de"
filelist="base lib32 kernel"
filelist_optional="MANIFEST"			# only fetch
memdisknumber=10
#iface_manual=YES
#manual_gw='defaultrouter="1.1.1.1"'			# gateway IP
#manual_iface='ifconfig_vtnet0="inet 1.1.1.2/24"'	# interface IP
#nameserver="8.8.8.8"							# single nameserver
#manual_gw_v6='ipv6_defaultrouter="2001:41d0:0005:1000::1"'			# gateway IP
#manual_iface_v6='ifconfig_vtnet0_ipv6=""2001:41d0:0005:1000:0000:0000:0000:abcd/64"'	# interface IP

usage="Usage: $0 -p <geom_provider> -s <swap_partition_size> -S <zfs_partition_size> -n <zpoolname> -f <ftphost>
[ -m <zpool-raidmode> -d <distribution_dir> -D <destination_dir> -M <size_memory_disk> -o <offset_end_disk>
-B <boot_mode> -P <new_password> -t <timezone> -k <url_ssh_key_file> -K <url_ssh_key_dir>
-z <file_zfs_skeleton> -Z <url_file_zfs_skeleton> ]
[ -g <gateway> [-i <iface>] -I <IP_address/mask> ]

boot_mode: auto (default), bios, uefi, hybrid"

exerr() {
	printf '%b\n' "$*" >&2
	exit 1
}

while getopts p:P:s:S:n:h:f:m:M:o:d:D:t:g:i:I:B:z:Z:k:K: arg; do
	case ${arg} in
	p) provider="$provider ${OPTARG}" ;;
	P) password=${OPTARG} ;;
	s) swap_partition_size=${OPTARG} ;;
	S) zfs_partition_size=${OPTARG} ;;
	n) poolname=${OPTARG} ;;
	h) hostname=${OPTARG} ;;
	f) ftphost=${OPTARG} ;;
	m) mode=${OPTARG} ;;
	M) memdisksize=${OPTARG} ;;
	o) offset=${OPTARG} ;;
	d) distdir=${OPTARG} ;;	# source of local system archives
	D) destdir=${OPTARG} ;;	# mount point of the new pool
	t) timezone=${OPTARG} ;;
	g) gateway=${OPTARG} ;;
	i) iface=${OPTARG} ;;
	I) ip_address=${OPTARG} ;;
	B) boot_mode=${OPTARG} ;;
	z) file_zfs_skeleton=${OPTARG} ;;
	Z) url_file_zfs_skeleton=${OPTARG} ;;
	k) ssh_key_file="${ssh_key_file} ${OPTARG}" ;;
	K) ssh_key_dir="${ssh_key_dir} ${OPTARG}" ;;
	?) exerr "${usage}" ;;
	esac
done
shift "$((OPTIND-1))"

if [ -z "$poolname" ] || [ -z "$provider" ]; then
	exerr "${usage}"
fi

# count the number of providers
devcount=$(echo "${provider}" | xargs -n1 | sort -u | xargs | wc -w | tr -d ' ')
if [ -z "$devcount" ] || [ "$devcount" = ' ' ] || [ "$devcount" = "0" ]; then
	exerr "${usage}"
fi

#[ -z "$distdir" ] && distdir="/mfs"
[ -z "$ftphost" ] && ftphost="ftp://ftp.de.freebsd.org/pub/FreeBSD/releases/amd64/amd64/12.3-BETA3/"
[ -z "$timezone" ] && timezone="Europe/Kyiv"
[ -z "$memdisksize" ] && memdisksize=350M # deprecated
[ -z "$password" ] && password="mfsroot123"
[ -z "$hostname" ] && hostname="core.domain.com"
[ -z "$offset" ] && offset="2048"	# remainder at the end of the disc, 1 MB
									# 1 MB approximately for every full and partial 1 TB of disk capacity.
destdir=${destdir:-/mnt}
esp_size="800m"						# EFI System Partition size

# auto-detect or validate boot mode
detect_boot_mode() {
	if sysctl -n machdep.bootmethod 2>/dev/null | grep -qi uefi; then
		echo "uefi"
	elif [ -d /sys/firmware/efi ]; then
		echo "uefi"
	else
		echo "bios"
	fi
}

if [ -z "$boot_mode" ] || [ "$boot_mode" = "auto" ]; then
	boot_mode=$(detect_boot_mode)
	echo "Auto-detected boot mode: $boot_mode"
fi

case "$boot_mode" in
	bios|uefi|hybrid) ;;
	*) exerr "Invalid boot mode: $boot_mode. Use bios, uefi, or hybrid." ;;
esac
echo "Boot mode: $boot_mode"

# autodetect physical network interfaces
iface=${iface:-"$(ifconfig -l -u | sed -e 's/lo[0-9]*//' -e 's/enc[0-9]*//' -e 's/gif[0-9]*//' \
-e 's/fwe[0-9]*//' -e 's/fwip[0-9]*//' -e 's/ipfw[0-9]*//' -e 's/pflog[0-9]*//' -e 's/plip[0-9]*//' \
-e 's/stf[0-9]*//' -e 's/lagg[0-9]*//' -e 's/  / /g')"}
iface=${iface:-"em0 em1 re0 igb0 vtnet0"}

if [ "$gateway" = "auto" ] || [ "${ip_address}" = "auto" ]; then
	gateway=$(netstat -rn4 | awk '/default/{print $2;}')
	ip_address=$(ifconfig | grep 'inet\b' | grep -v 127.0 | awk '{ print $2 }' | head -1)
	net_mask=$(ifconfig | grep 'inet\b' | grep -v 127.0 | awk '{ print $4 }' | head -1)
fi

[ "$gateway" = "DHCP" ] && gateway=''
[ "${ip_address}" = "DHCP" ] && ip_address=''

if [ -n "$gateway" ] && [ -n "${ip_address}" ] && [ -n "${net_mask}" ]; then
	iface_manual=yes
	manual_gw="defaultrouter=\"$gateway\""                      # gateway IP
	manual_iface="ifconfig_${iface%% *}=\"inet ${ip_address} netmask ${net_mask}\"" # interface IP and netmask
fi

sysctl kern.geom.label.gptid.enable=0
sysctl kern.geom.debugflags=16
# sysctl vfs.zfs.min_auto_ashift=12	# need module zfs

[ -n "$nameserver" ] && {
	mkdir -p /tmp/bsdinstall_etc
	echo "nameserver $nameserver" >/tmp/bsdinstall_etc/resolv.conf
}

if [ -n "$distdir" ]; then
	if [ ! -d "$distdir" ]; then
		mkdir -p "$distdir"
		if [ ! -d "$distdir" ]; then
			distdir="/opt$distdir"
			mkdir -p "$distdir" || exit 1
		fi
	fi
fi

if [ "$memdisksize" != "0" ] && [ -n "$distdir" ]; then
	if [ -e "/dev/md$memdisknumber" ]; then
		umount /dev/md$memdisknumber
		mdconfig -d -u $memdisknumber
	fi
	if [ ! -e "/dev/md$memdisknumber" ]; then
		mdconfig -a -s $memdisksize -u $memdisknumber
		newfs -U /dev/md$memdisknumber
		mount /dev/md$memdisknumber "$distdir"
	fi
fi

# set our default zpool mirror-mode
if [ -z "$mode" ]; then
	if [ "$devcount" -eq "1" ]; then
		mode='stripe'
	elif [ "$devcount" -eq "4" ]; then
		mode='raid10'
	else
		mode='mirror'
	fi
fi
echo $mode

sleep 1

# check the settings for the users that want to set the mode on their own
if [ "$devcount" -eq "1" ] && [ "$mode" = "mirror" ]; then
	echo "A mirror needs at least two disks!"
	exit 1
fi
if [ "$devcount" -lt "3" ] && [ "$mode" = "raidz" ]; then
	echo "Sorry, you need at least three disks for a zfs raidz!"
	exit 1
fi
if [ "$devcount" -lt "4" ] && [ "$mode" = "raid10" ]; then
	echo "Sorry, you need at least four disks for a raid10 equivalent szenario!"
	exit 1
fi
if [ "$((devcount % 2))" -ne "0" ] && [ "$mode" = "raid10" ]; then
	echo "Sorry, you need an even number of disks for a raid10 equivalent szenario!"
	exit 1
fi

check_size() {
	ref_disk_size=$(gpart list ${ref_disk} | grep 'Mediasize' | awk '{print $2}')
	if [ "${zfs_partition_size}" ]; then
		_zfs_partition_size=$(echo "${zfs_partition_size}" | awk '{print tolower($0)}' |
			sed -Ees:g:km:g -es:m:kk:g -es:k:"*2b":g -es:b:"*128w":g -es:w:"*4 ":g -e"s:(^|[^0-9])0x:\1\0X:g" -ey:x:"*": |
			bc | sed 's:\.[0-9]*$::g')
	fi
	if [ "${swap_partition_size}" ]; then
		_swap_partition_size=$(echo "${swap_partition_size}" | awk '{print tolower($0)}' |
			sed -Ees:g:km:g -es:m:kk:g -es:k:"*2b":g -es:b:"*128w":g -es:w:"*4 ":g -e"s:(^|[^0-9])0x:\1\0X:g" -ey:x:"*": |
			bc | sed 's:\.[0-9]*$::g')
	fi
	total_size=$((_zfs_partition_size + _swap_partition_size + 162))
	if [ "${total_size}" -gt "${ref_disk_size}" ]; then
		echo "ERROR: The current settings for the partitions sizes will not fit onto your disk."
		exit 1
	fi
}

get_disk_labelname() {
	label=${disk##*=}
	disk=${disk%%=*}
}

# stop swapping
if swapinfo >/dev/null 2>/dev/null; then
	swapoff "$(swapinfo | tail -n 1 | awk '{print$1}')"
fi

echo "Creating GPT label on disks:"
for disk in $provider; do
	get_disk_labelname
	if [ ! -e "/dev/$disk" ]; then
		echo " -> ERROR: $disk does not exist"
		exit 1
	fi
	echo " -> $disk"
	# against PR 196102
	# todo need to do tests
	gpart recover /dev/$disk
	if (gpart show /dev/$disk | grep -E -v '=>| - free -|^$'); then
		disk_index_list="$(gpart show /dev/$disk | grep -E -v '=>| - free -|^$' | awk '{print $3;}' | sort -r)"
		for disk_index in ${disk_index_list}; do
			gpart delete -i ${disk_index} /dev/$disk || exit 1
		done
	fi
	zpool labelclear -f $disk >/dev/null
	gpart destroy -F $disk >/dev/null
	gpart create -s gpt $disk >/dev/null
done

smallest_disk_size='0'
echo "Checking disks for size:"
for disk in $provider; do
	get_disk_labelname
	disk_size=$(gpart show $disk | grep '\- free \-' | awk '{print $2}')
	echo " -> $disk - total size $disk_size"
	if [ "$smallest_disk_size" -gt "$disk_size" ] || [ "$smallest_disk_size" -eq "0" ]; then
		smallest_disk_size=$disk_size
		ref_disk=$disk
	fi
done

# check if the size fits
swap_partition_size=${swap_partition_size:-"0"}
check_size

echo
echo "NOTICE: Using ${ref_disk} (smallest or only disk) as reference disk for calculation offsets"
echo

# Create BIOS boot partition
if [ "$boot_mode" = "bios" ] || [ "$boot_mode" = "hybrid" ]; then
	echo "Creating GPT BIOS boot partition on disks:"
	counter=0
	for disk in $provider; do
		get_disk_labelname
		echo " ->  ${disk}"
		gpart add -s 1024 -t freebsd-boot -l boot-${counter} $disk >/dev/null
		counter=$((counter + 1))
	done
fi

# Create EFI System Partition
if [ "$boot_mode" = "uefi" ] || [ "$boot_mode" = "hybrid" ]; then
	echo "Creating EFI System Partition (${esp_size}) on disks:"
	counter=0
	for disk in $provider; do
		get_disk_labelname
		echo " ->  ${disk}"
		gpart add -s ${esp_size} -t efi -l efi-${label} $disk >/dev/null
		counter=$((counter + 1))
	done
fi

if [ "${swap_partition_size}" ]; then
	echo "Creating GPT swap partition with size ${swap_partition_size} on disks: "
	for disk in $provider; do
		get_disk_labelname
		echo " ->  ${disk} (Label: ${label})"
		gpart add -s "${swap_partition_size}" -t freebsd-swap -l swap-"${label}" ${disk} >/dev/null
		swapon /dev/gpt/swap-${label}
	done
fi

###offset=$(gpart show ${ref_disk} | grep '\- free \-' | tail -n 1 | awk '{print $1}')
last_partition_disk_size=$(gpart show ${ref_disk} | grep '\- free \-' | tail -n 1 | awk '{print $2}')
if [ "${zfs_partition_size}" ] && [ "${last_partition_disk_size}" -le "${smallest_disk_size}" ]; then
	size_string="-s $((zfs_partition_size - offset))"
else
	size_string="-s $((last_partition_disk_size - offset))"
fi

echo "Creating GPT ZFS partition on with size ${zfs_partition_size} on disks: "
counter=0
if [ "$mode" = "raid10" ]; then
	labellist=" mirror "
fi
for disk in $provider; do
	get_disk_labelname
	echo " ->  ${disk} (Label: ${label})"
	gpart add -t freebsd-zfs ${size_string} -l system-${label} ${disk} >/dev/null

	counter=$((counter + 1))
	labellist="${labellist} gpt/system-${label}"
	if [ "$((counter % 2))" -eq "0" ] && [ "$devcount" -ne "$counter" ] && [ "$mode" = "raid10" ]; then
		labellist="${labellist} mirror "
	fi
done

# show list GPT label
ls -l /dev/gpt/

# Make first partition active so the BIOS boots from it
# see https://forums.freebsd.org/threads/freebsd-gpt-uefi.42781/#post-238472

if ! $(/sbin/kldstat -m zfs >/dev/null 2>/dev/null); then
	/sbin/kldload zfs >/dev/null 2>/dev/null
	sysctl vfs.zfs.min_auto_ashift=12	# need module zfs
fi

# we need to create /boot/zfs so zpool.cache can be written.
[ ! -d /boot/zfs ] && mkdir /boot/zfs

zpool_option="-o altroot=$destdir -o cachefile=/tmp/zpool.cache"
# Create the pool and the rootfs

if [ "$mode" = "raidz" ]; then
	zpool create -f ${zpool_option} $poolname raidz ${labellist} || exit
fi
if [ "$mode" = "mirror" ]; then
	zpool create -f ${zpool_option} $poolname mirror ${labellist} || exit
fi
if [ "$mode" = "stripe" ]; then
	zpool create -f ${zpool_option} $poolname ${labellist} || exit
fi
if [ "$mode" = "raid10" ]; then
	zpool create -f ${zpool_option} $poolname ${labellist} || exit
fi

if [ "$(zpool list -H -o name $poolname)" != "$poolname" ]; then
	echo "ERROR: Could not create zpool $poolname"
	exit 1
fi

zpool export $poolname
ls -l /dev/gpt/
sleep 3
zpool import ${zpool_option} $poolname
zpool status
gpart show

echo "Setting checksum to fletcher4"
zfs set checksum=fletcher4 $poolname
zfs set reservation=50M $poolname
zfs set compression=lz4 $poolname

zfs create -p $poolname
zfs set freebsd:boot-environment=1 $poolname
#zpool set bootfs=$poolname $poolname

# Now we create some stuff we also would like to have in separate filesystems

zfs set mountpoint=$destdir $poolname || exit 1

if [ -n "${url_file_zfs_skeleton}" ]; then
	fetch -o /tmp/zfs_skeleton.sh "${url_file_zfs_skeleton}" && sh /tmp/zfs_skeleton.sh
else
	if [ -n "${file_zfs_skeleton}" ]; then
		if [ -f "${file_zfs_skeleton}" ]; then
			# shellcheck source=zfs_skeleton.example
			. "${file_zfs_skeleton}"
		fi
	fi
fi

if [ -z "${url_file_zfs_skeleton}" ] && [ -z "${file_zfs_skeleton}" ]; then

zfs create $poolname/usr
zfs create $poolname/var
zfs create -o compression=on    -o exec=on      -o setuid=off   $poolname/tmp
zfs create                      -o exec=on      -o setuid=off   $poolname/usr/ports
zfs create -o compression=off   -o exec=off     -o setuid=off   $poolname/usr/ports/distfiles
zfs create -o compression=off   -o exec=off     -o setuid=off   $poolname/usr/ports/packages
zfs create                      -o exec=on      -o setuid=off   $poolname/usr/src
zfs create                      -o exec=off     -o setuid=off   $poolname/usr/home
zfs create                      -o exec=off     -o setuid=off   $poolname/var/crash
zfs create                      -o exec=off     -o setuid=off   $poolname/var/db
zfs create                      -o exec=on      -o setuid=off   $poolname/var/db/pkg
zfs create                      -o exec=on      -o setuid=off   $poolname/var/ports
zfs create                      -o exec=off     -o setuid=off   $poolname/var/empty
zfs create                      -o exec=off     -o setuid=off   $poolname/var/log
zfs create -o compression=gzip  -o exec=off     -o setuid=off   $poolname/var/mail
zfs create                      -o exec=off     -o setuid=off   $poolname/var/run
zfs create                      -o exec=on      -o setuid=off   $poolname/var/tmp

fi

zpool export $poolname
zpool import -f -d /dev/gpt/ -o cachefile=/tmp/zpool.cache $poolname

zfs list

chmod 1777 $destdir/tmp
cd $destdir || exit
[ ! -d "$destdir/home" ] && ln -s usr/home home
chmod 1777 $destdir/var/tmp

mkdir -p $destdir/etc
### Add swap info
cat <<EOF >$destdir/etc/fstab
#/etc/fstab

# Device		Mountpoint	FStype		Options	Dump	Pass#
EOF
if [ "$swap_partition_size" ]; then
	echo "Adding swap partitions in fstab:"
	for disk in $provider; do
		get_disk_labelname
		echo " ->  /dev/gpt/swap-${label}"
		printf '/dev/gpt/swap-%s\tnone\t\tswap\tsw\t0\t0\n' "${label}" >>"$destdir/etc/fstab"
		#		swapon /dev/gpt/swap-${label}
	done
else
	touch $destdir/etc/fstab
fi

cat $destdir/etc/fstab

### Downloading system archive files

cd "${destdir:-/}" || exit
for file in ${filelist}; do
	if [ "x$distdir" = "x" ]; then
		(fetch --retry -o - "$ftphost/$file.txz" | tar --unlink -xpJf -) || exit
	else
		[ -e "$distdir/$file.txz" ] && tar --unlink -xpJf "$distdir/$file.txz"
	fi
done
for file in ${filelist_optional}; do
	if [ "x$distdir" = "x" ]; then
		fetch --retry -o "$destdir" "$ftphost/$file"
	fi
	if [ "$file" = "MANIFEST" ]; then
		if [ "x$distdir" = "x" ]; then
		    cp -a "$destdir/$file" /usr/freebsd-dist/
		else
			[ -e "$distdir/$file" ] && cp -a "$distdir/$file" /usr/freebsd-dist/
		fi
	fi
done

cp /tmp/zpool.cache $destdir/boot/zfs/zpool.cache

cat <<EOF >$destdir/etc/rc.conf
zfs_enable="YES"
hostname="$hostname"
sshd_enable="YES"
sshd_flags="-oPort=22 -oCompression=yes -oPermitRootLogin=yes -oPasswordAuthentication=yes -oUseDNS=no"
dumpdev="AUTO"
EOF

# apply DNS settings
[ -n "$nameserver" ] && {
	cat <<EOF >$destdir/etc/resolvconf.conf
	nameserver $nameserver
	nameserver "$nameserver"
	resolv_conf_local_only="NO"
EOF
	resolvconf -u
}

if [ "${iface_manual}" = "1" ] || [ "${iface_manual}" = "yes" ] || [ "${iface_manual}" = "YES" ]; then
	cat <<EOF >>$destdir/etc/rc.conf
${manual_gw}
${manual_iface}
ifconfig_DEFAULT="SYNCDHCP"
ifconfig_enc0="NOAUTO"

EOF
	for interface in ${iface}; do
		echo ifconfig_${interface}_ipv6=\"inet6 accept_rtadv\" >>$destdir/etc/rc.conf
	done
	echo ipv6_activate_all_interfaces=\"YES\" >>$destdir/etc/rc.conf
	echo " " >>$destdir/etc/rc.conf
	if [ -n "${manual_gw_v6}" ] && [ -n "${manual_iface_v6}" ]; then
		cat <<EOF >>$destdir/etc/rc.conf
${manual_gw_v6}
${manual_iface_v6}

EOF
	fi
else
	echo 'ifconfig_DEFAULT="SYNCDHCP"' >>$destdir/etc/rc.conf
	echo 'ifconfig_enc0="NOAUTO"' >>$destdir/etc/rc.conf
	for interface in ${iface}; do
		echo ifconfig_$interface=\"DHCP\" >>$destdir/etc/rc.conf
		echo ifconfig_${interface}_ipv6=\"inet6 accept_rtadv\" >>$destdir/etc/rc.conf
	done
	echo ipv6_activate_all_interfaces=\"YES\" >>$destdir/etc/rc.conf
	echo " " >>$destdir/etc/rc.conf
fi

cat $destdir/etc/rc.conf

# put ssh_key
root_dir=$destdir/root/.ssh
mkdir -p "${root_dir}" >/dev/null 2>&1
chmod 700 ${root_dir}
# ${ssh_key_dir}/key[1..9].pub
if [ -n "${ssh_key_dir}" ]; then
	for url in ${ssh_key_dir}; do
		if (ping -q -c3 $(echo $url | awk -F/ '{print $3;}') >/dev/null 2>&1); then
			for i in $(seq 1 9); do
				fetch -qo - $url/key$i.pub >>${root_dir}/authorized_keys
			done
			chmod 600 ${root_dir}/authorized_keys
			break
		else
			echo "no ping to host $(echo $url | awk -F/ '{print $3;}')"
		fi
	done
fi

if [ -n "${ssh_key_file}" ]; then
	for ssh_key in ${ssh_key_file}; do
		if (ping -q -c3 $(echo ${ssh_key} | awk -F/ '{print $3;}') >/dev/null 2>&1); then
			fetch -qo - ${ssh_key} >>${root_dir}/authorized_keys
			chmod 600 ${root_dir}/authorized_keys
			break
		else
			echo "no ping to host $(echo ${ssh_key} | awk -F/ '{print $3;}')"
		fi
	done
fi

cat <<EOF >>$destdir/boot/loader.conf
zfs_load="YES"
vfs.root.mountfrom="zfs:$poolname"
kern.geom.label.gptid.enable=0
kern.geom.label.disk_ident.enable=0
debug.acpi.disabled="thermal"

## enable vt text mode
#hw.vga.textmode=0

# for Linode Shell
boot_multicons="YES"
boot_serial="YES"
comconsole_speed="115200"
console="comconsole,vidconsole"

## Minimize mode
#beastie_disable="YES"
#autoboot_delay="-1"

EOF

# If the memory is 3GB or less, then we reduce the allocated memory for ZFS
if [ "$(sysctl -n hw.realmem)" -lt "$(((3 * 1024 * 1024 * 1024) + 2000))" ]; then
	cat <<EOF >>$destdir/boot/loader.conf
# with 1-3 GB Memory
vfs.zfs.arc_max="200M"
#
EOF
fi

# Options for tmux
echo "set-option -g history-limit 300000" >>$destdir/root/.tmux.conf

zfs set readonly=on $poolname/var/empty

# Install bootcode
if [ "$boot_mode" = "bios" ] || [ "$boot_mode" = "hybrid" ]; then
	echo
	echo "Installing BIOS bootcode on disks: "
	for disk in $provider; do
		get_disk_labelname
		echo " ->  ${disk}"
		gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 $disk
	done
fi

if [ "$boot_mode" = "uefi" ] || [ "$boot_mode" = "hybrid" ]; then
	echo
	echo "Installing UEFI loader on disks: "
	for disk in $provider; do
		get_disk_labelname
		echo " ->  ${disk}"
		newfs_msdos -F 32 -c 1 /dev/gpt/efi-${label}
		efi_mount=$(mktemp -d)
		mount -t msdosfs /dev/gpt/efi-${label} ${efi_mount}
		mkdir -p ${efi_mount}/EFI/BOOT
		cp $destdir/boot/loader.efi ${efi_mount}/EFI/BOOT/BOOTX64.efi
		# also install as the FreeBSD-specific path
		mkdir -p ${efi_mount}/EFI/FreeBSD
		cp $destdir/boot/loader.efi ${efi_mount}/EFI/FreeBSD/loader.efi
		umount ${efi_mount}
		rmdir ${efi_mount}
	done
fi

echo You\'ve just been chrooted into your fresh installation.
echo passwd root

cd /
[ -d /usr/share/zoneinfo ] && file_timezone=/usr/share/zoneinfo/$timezone;
chroot $destdir /bin/sh -c "hostname $hostname; make -C /etc/mail aliases;
[ -e "${file_timezone}" ] && ln -s ${file_timezone} /etc/localtime;"
echo "$password" | pw -V $destdir/etc usermod root -h 0
chroot $destdir /bin/sh -c "cd /; umount /dev"

zfs umount -a
zfs set mountpoint=legacy $poolname
zfs set mountpoint=/tmp $poolname/tmp
zfs set mountpoint=/usr $poolname/usr
zfs set mountpoint=/var $poolname/var
swapoff /dev/gpt/swap-${label}

echo zpool status:
zpool status
echo
echo "Please reboot the system from the harddisk(s), remove the FreeBSD media from you cdrom!"

zpool export -f $poolname

# for Ansible
file234=/root/"$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")".completed
touch "$file234"
