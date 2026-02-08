#!/bin/sh

# Copyright
# Vladislav V. Prodan <github.com/click0>
# https://support.od.ua
# 2018-2022

script_type="ansible"
# shellcheck disable=SC2034
version_script="1.21"

set -e

exit_error() {
	# shellcheck disable=SC2039
	echo "$*" 1>&2
	exit 1
}

print_version() {
	echo "${version_script}"
}

HOSTNAME="YOURHOSTNAME"
MFSBSDISO="https://mfsbsd.vx.sk/files/iso/12/amd64/mfsbsd-12.2-RELEASE-amd64.iso"
INTERFACE="em0" # or vtnet0
NEED_FREE_SPACE="90" # in megabytes!
DIR_ISO=/boot/images
GRUB_CONFIG=/etc/grub.d/40_custom
# url2=http://otrada.od.ua/FreeBSD/LiveCD/mfsbsd

network_settings() {

	ip=$(ip addr show | grep "inet\b" | grep -v "\blo" | awk '{print $2}' | \
		grep -Ev "^(10\.|127\.0\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)" | cut -d/ -f1 | head -1)
	ip=${ip:-"127.0.0.1"}
	ipv6=$(ip addr show | grep "inet6\b" | grep -v "\bscope host" | awk '{print $2}' | grep -Ev '^::1|^fe' | head -1)
	ip_mask_short=$(ip addr show | grep "inet\b" | grep -v "\blo" | awk '{print $2}' |
		grep -Ev "^(10\.|127\.0\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)" | cut -d/ -f2 | head -1)

	ip_default=$(ip route | grep default | awk '{print $3;}' | head -1)
	ip_mask_short=${ip_mask_short:-"24"}
	[ "${ip_mask_short}" = "32" ] && ip_mask_short=22
	ipv6_default=$(ip -6 route | grep default | awk '{print $3;}' | head -1)

}

check_free_space_boot() {

	echo Checking the free space on the /boot partition

	if grep -q ' /boot ' /proc/mounts; then
		if [ "$(df -m /boot | awk '/\// {print $4;}')" -le "${NEED_FREE_SPACE}" ]; then
			echo "No space in partition /boot!"
			exit 1
		fi
	else
		if grep -q ' / ' /proc/mounts; then
			if [ "$(df -m / | awk '/\// {print $4;}')" -le "${NEED_FREE_SPACE}" ]; then
				echo "No space in partition / !"
				exit 1
			fi
		fi
	fi

}

usage() {
	cat <<-EOF
		Usage: $0 [-hv] [-m url_iso -a md5_iso] [-H your_hostname] [-i network_iface] [-p 'myPassW0rD'] [-s need_free_space]
	
		  -a :  Md5 checksum rescue ISO
		  -h    Show help
		  -H    Set the hostname of the host. The default value is 'YOURHOSTNAME'.
		  -v    Show version
		  -i    Use a specific network interface if the machine has more than one.
		        By default, a network interfaces is $INTERFACE.
		  -m :  URL of mfsbsd image (defaults to image on https://mfsbsd.vx.sk)
		        For example, ISO $MFSBSDISO.
		        Some ISO images do not have ssh key access, so be aware of the risks.
		  -p :  The user password to set in the Rescue ISO.
		        By default, MfsBSD's password is 'mfsroot'.
		  -s :  How much more do you need to check the availability of free disk space.
		        Supported suffixes are 'M' for MiB (by default) and 'G' for GiB.
	
	EOF
}

while getopts "a:hvi:H:m:p:s:" flags; do
	case "${flags}" in
	a)
		ISO_HASH="${OPTARG}"
		;;
	h)
		usage
		exit 0
		;;
	v)
		print_version
		exit 0
		;;
	H)	
		HOSTNAME="${OPTARG}"
		;;
	i)
		INTERFACE="${OPTARG}"
		;;
	m)
		MFSBSDISO="${OPTARG}"
		;;
	p)
		PASSWORD="${OPTARG}"
		;;
	s)
		NEED_FREE_SPACE="${OPTARG}"
		;;
	*)
		exit_error "$(usage)"
		;;
	esac
done
shift "$((OPTIND-1))"

FILENAME_ISO=${MFSBSDISO##*/}
domain=$(echo "$MFSBSDISO" | awk -F/ '{print $3;}')

case ${FILENAME_ISO} in
# standard
mfsbsd-12.2-RELEASE-amd64.iso) ISO_HASH=00eba73ac3a2940b533f2348da88d524 ;;
mfsbsd-13.0-RELEASE-amd64.iso) ISO_HASH=149ca4ecf9b39af7218481d13c3325b4 ;;
mfsbsd-13.1-RELEASE-amd64.iso) ISO_HASH=128ad6b7cc8cb0f163e293d570136e93 ;;
esac

[ -z "${ISO_HASH}" ] && exit_error "No checksum defined for ${FILENAME_ISO}. Use -a to provide one."

check_free_space_boot

apt-get update || yum makecache
apt-get -y install wget || yum -y install wget

mkdir -p "$DIR_ISO"
cd "$DIR_ISO" || exit 1

if [ ! -e "$FILENAME_ISO" ]; then
	if (ping -q -c3 "$domain" >/dev/null 2>&1); then
		wget --tries=3 --timeout=30 "$MFSBSDISO"
	else
		exit_error "Can't download Rescue ISO"
	fi
fi

[ ! -e "$FILENAME_ISO" ] && exit_error "ISO image not found"
if md5sum "$DIR_ISO"/"$FILENAME_ISO" | grep -q "${ISO_HASH}"; then
	echo "md5 OK"
else
	exit_error "md5 mismatch"
fi

# inserting network options
# http://zajtcev.org/other/freebsd/install-freebsd-to-ovh-with-mfsbsd.html

network_settings

# Remove previous MfsBSD entries if present
MFSBSD_MARKER="# --- BEGIN MFSBSD ---"
MFSBSD_MARKER_END="# --- END MFSBSD ---"
if grep -q "${MFSBSD_MARKER}" "${GRUB_CONFIG}" 2>/dev/null; then
	sed -i "/${MFSBSD_MARKER}/,/${MFSBSD_MARKER_END}/d" "${GRUB_CONFIG}"
fi

GRUB_TEMP=$(mktemp)

cat << EOF >"${GRUB_TEMP}"
${MFSBSD_MARKER}

	menuentry "${FILENAME_ISO}" {
		set isofile=${DIR_ISO}/${FILENAME_ISO}
		# (hd0,1) here may need to be adjusted of course depending where the partition is
		loopback loop (hd0,1)\$isofile
		kfreebsd (loop)/boot/kernel/kernel.gz -v
		# kfreebsd_loadenv (loop)/boot/device.hints
		# kfreebsd_module (loop)/boot/kernel/geom_uzip.ko
		kfreebsd_module (loop)/boot/kernel/ahci.ko
		kfreebsd_module (loop)/mfsroot.gz type=mfs_root
		set kFreeBSD.vfs.root.mountfrom="ufs:/dev/md0"
		set kFreeBSD.mfsbsd.hostname="$HOSTNAME"
EOF
if [ "$ip" = "127.0.0.1" ]; then
	echo "	set kFreeBSD.mfsbsd.autodhcp=\"YES\"" >>"${GRUB_TEMP}"
else
	echo "	set kFreeBSD.mfsbsd.autodhcp=\"NO\"" >>"${GRUB_TEMP}"
fi
cat << EOF >>"${GRUB_TEMP}"
	set kFreeBSD.mfsbsd.mac_interfaces="ext1"
EOF
# https://github.com/mmatuska/mfsbsd/blob/master/conf/interfaces.conf.sample
if [ "$ip" != "127.0.0.1" ]; then
	cat << EOF >>"${GRUB_TEMP}"
	set kFreeBSD.mfsbsd.interfaces="ext1"
	set kFreeBSD.mfsbsd.ifconfig_ext1="inet $ip/${ip_mask_short}"
	set kFreeBSD.mfsbsd.defaultrouter="${ip_default}"
EOF
fi
cat << EOF >>"${GRUB_TEMP}"
	set kFreeBSD.mfsbsd.nameservers="8.8.8.8 1.1.1.1"
	#	set kFreeBSD.mfsbsd.ifconfig_lo0="DHCP" #wtf?
	#	set kFreeBSD.mfsbsd.ipv6_defaultrouter="${ipv6_default}"
	# Define a new root password
	set kFreeBSD.mfsbsd.rootpw="${PASSWORD}"

	}

EOF

menuentry=$(grep -c '^menuentry ' /boot/grub/grub.cfg)
cat << EOF >>"${GRUB_TEMP}"
set default="$((menuentry + 1))"
set timeout=1

${MFSBSD_MARKER_END}
EOF

# Atomic append to GRUB config
cat "${GRUB_TEMP}" >>"${GRUB_CONFIG}"
rm -f "${GRUB_TEMP}"

# Generating the correct GRUB config
if command -v update-grub >/dev/null 2>&1; then
	update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1; then
	grub2-mkconfig -o /boot/grub2/grub.cfg
else
	exit_error "Neither update-grub nor grub2-mkconfig found"
fi

echo reboot!
