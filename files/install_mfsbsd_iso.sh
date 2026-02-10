#!/bin/sh

# Copyright
# Vladyslav V. Prodan <github.com/click0>
# https://support.od.ua
# 2018-2026

script_type="self-contained"
# shellcheck disable=SC2034
version_script="1.27"

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
MFSBSDISO="https://mfsbsd.vx.sk/files/iso/14/amd64/mfsbsd-14.0-RELEASE-amd64.iso"
INTERFACE="em0" # or vtnet0
NEED_FREE_SPACE="99" # in megabytes!
DIR_ISO=/boot/images
GRUB_CONFIG=/etc/grub.d/40_custom
BOOT_MODE=""
FORCE_UEFI=0
# url2=http://otrada.od.ua/FreeBSD/LiveCD/mfsbsd

detect_boot_mode() {

	if [ "${FORCE_UEFI}" -eq 1 ]; then
		BOOT_MODE="uefi"
		echo "Boot mode: UEFI (forced via -U)"
	elif [ -d /sys/firmware/efi ]; then
		BOOT_MODE="uefi"
		echo "Boot mode: UEFI (auto-detected)"
	else
		BOOT_MODE="bios"
		echo "Boot mode: Legacy BIOS"
	fi

}

detect_secure_boot() {

	if [ "${BOOT_MODE}" != "uefi" ]; then
		return 0
	fi

	sb_state=""
	if command -v mokutil >/dev/null 2>&1; then
		sb_state=$(mokutil --sb-state 2>/dev/null || true)
	elif [ -d /sys/firmware/efi/efivars ]; then
		# Check SecureBoot EFI variable directly
		sb_var=$(find /sys/firmware/efi/efivars -name 'SecureBoot-*' 2>/dev/null | head -1)
		if [ -n "${sb_var}" ]; then
			# Last byte: 01 = enabled, 00 = disabled
			sb_byte=$(od -An -tx1 -j4 -N1 "${sb_var}" 2>/dev/null | tr -d ' ')
			if [ "${sb_byte}" = "01" ]; then
				sb_state="SecureBoot enabled"
			fi
		fi
	fi

	case "${sb_state}" in
	*enabled*)
		echo "WARNING: Secure Boot is enabled."
		echo "FreeBSD loader.efi is not signed and will not boot with Secure Boot."
		if command -v mokutil >/dev/null 2>&1; then
			echo "Attempting to disable Secure Boot validation via mokutil..."
			echo "You will be prompted to create a password for MOK management."
			echo "After reboot, follow the MOK Manager prompts to confirm."
			mokutil --disable-validation || exit_error "Failed to disable Secure Boot validation"
			echo "Secure Boot validation disable scheduled. Will take effect after reboot."
		else
			exit_error "Secure Boot is enabled and mokutil is not available. Please disable Secure Boot in BIOS/UEFI settings."
		fi
		;;
	esac

}

find_esp_mount() {

	# Find the ESP (EFI System Partition) mount point
	ESP_DIR=""
	if grep -q ' /boot/efi ' /proc/mounts; then
		ESP_DIR="/boot/efi"
	elif grep -q ' /efi ' /proc/mounts; then
		ESP_DIR="/efi"
	else
		# Try to find ESP by partition type
		esp_part=$(lsblk -lno NAME,PARTTYPE 2>/dev/null | grep -i 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' | awk '{print $1}' | head -1)
		if [ -n "${esp_part}" ]; then
			esp_mount=$(lsblk -lno NAME,MOUNTPOINT "/dev/${esp_part}" 2>/dev/null | awk '{print $2}')
			if [ -n "${esp_mount}" ]; then
				ESP_DIR="${esp_mount}"
			else
				# ESP exists but not mounted, mount it
				mkdir -p /boot/efi
				mount "/dev/${esp_part}" /boot/efi
				ESP_DIR="/boot/efi"
				echo "Mounted ESP /dev/${esp_part} at /boot/efi"
			fi
		fi
	fi

	if [ -z "${ESP_DIR}" ]; then
		exit_error "EFI System Partition (ESP) not found. Is the system really UEFI?"
	fi

	echo "ESP mount point: ${ESP_DIR}"

}

get_grub_device() {
	# Get GRUB device notation for a given directory
	# Usage: get_grub_device /path
	_dir="$1"

	if command -v grub-probe >/dev/null 2>&1; then
		grub-probe --target=drive "${_dir}" 2>/dev/null && return 0
	elif command -v grub2-probe >/dev/null 2>&1; then
		grub2-probe --target=drive "${_dir}" 2>/dev/null && return 0
	fi

	# Fallback: detect manually
	_dev=$(df "${_dir}" 2>/dev/null | awk 'NR==2 {print $1}')
	if [ -z "${_dev}" ]; then
		echo "(hd0,1)"
		return 0
	fi

	# Extract disk and partition number
	_disk=$(echo "${_dev}" | sed 's/[0-9]*$//' | sed 's/p$//')
	_partnum=$(echo "${_dev}" | grep -o '[0-9]*$')
	_partnum=${_partnum:-1}

	# Determine partition scheme (GPT or MBR)
	_diskbase=$(basename "${_disk}")
	if [ -d "/sys/block/${_diskbase}" ]; then
		_pttype=$(cat "/sys/block/${_diskbase}/device/../../../../../../../type" 2>/dev/null || true)
	fi
	# Check via blkid or gdisk
	_scheme="msdos"
	if command -v blkid >/dev/null 2>&1; then
		_pt=$(blkid -o value -s PTTYPE "${_disk}" 2>/dev/null || true)
		if [ "${_pt}" = "gpt" ]; then
			_scheme="gpt"
		fi
	elif [ -e "/sys/block/${_diskbase}/$(basename "${_dev}")/partition" ]; then
		if [ -d "/sys/firmware/efi" ]; then
			_scheme="gpt"
		fi
	fi

	echo "(hd0,${_scheme}${_partnum})"

}

check_kfreebsd_module() {
	# Check if GRUB has kfreebsd module available
	# Returns 0 if available, 1 if not

	for _grubdir in \
		/usr/lib/grub/x86_64-efi \
		/usr/lib/grub/i386-efi \
		/boot/grub/x86_64-efi \
		/boot/grub2/x86_64-efi \
		/usr/share/grub/x86_64-efi \
		/usr/lib/grub/x86_64-pc \
		/boot/grub/i386-pc \
		/boot/grub2/i386-pc \
		/usr/share/grub/i386-pc; do
		if [ -f "${_grubdir}/kfreebsd.mod" ]; then
			echo "Found kfreebsd module in ${_grubdir}"
			return 0
		fi
	done

	# Also check if kfreebsd command is already available in GRUB
	if grep -rq 'insmod kfreebsd' /boot/grub/grub.cfg /boot/grub2/grub.cfg 2>/dev/null; then
		echo "kfreebsd module found in GRUB config"
		return 0
	fi

	return 1

}

install_kfreebsd_module() {
	# Try to install grub-kfreebsd package
	echo "Attempting to install grub-kfreebsd package..."

	if command -v apt-get >/dev/null 2>&1; then
		apt-get -y install grub-kfreebsd 2>/dev/null && return 0
	elif command -v yum >/dev/null 2>&1; then
		yum -y install grub2-kfreebsd 2>/dev/null && return 0
	fi

	return 1

}

extract_boot_files() {
	# Extract FreeBSD boot files from ISO for UEFI chainload
	# Usage: extract_boot_files /path/to/iso /destination
	_iso="$1"
	_dest="$2"

	_mnt=$(mktemp -d)

	echo "Extracting FreeBSD boot files from ISO..."

	mount -o loop,ro "${_iso}" "${_mnt}" || exit_error "Failed to mount ISO"

	# Check that loader.efi exists in the ISO
	if [ ! -f "${_mnt}/boot/loader.efi" ]; then
		umount "${_mnt}"
		rmdir "${_mnt}"
		exit_error "ISO does not contain /boot/loader.efi. This ISO may not support UEFI boot."
	fi

	mkdir -p "${_dest}/boot/kernel"

	# Copy essential boot files
	cp "${_mnt}/boot/loader.efi" "${_dest}/boot/"
	cp "${_mnt}/boot/kernel/kernel.gz" "${_dest}/boot/kernel/" 2>/dev/null || \
		cp "${_mnt}/boot/kernel/kernel" "${_dest}/boot/kernel/" 2>/dev/null || \
		exit_error "Failed to copy kernel from ISO"
	cp "${_mnt}/boot/kernel/ahci.ko" "${_dest}/boot/kernel/" 2>/dev/null || true
	cp "${_mnt}/mfsroot.gz" "${_dest}/boot/" 2>/dev/null || \
		cp "${_mnt}/boot/mfsroot.gz" "${_dest}/boot/" 2>/dev/null || true

	# Copy device.hints if present
	cp "${_mnt}/boot/device.hints" "${_dest}/boot/" 2>/dev/null || true

	umount "${_mnt}"
	rmdir "${_mnt}"

	echo "Boot files extracted to ${_dest}"

}

write_loader_conf() {
	# Generate FreeBSD loader.conf for UEFI chainload boot
	# Usage: write_loader_conf /destination
	_dest="$1"

	cat << LOADEREOF >"${_dest}/boot/loader.conf"
# Generated by install_mfsbsd_iso.sh v${version_script}
vfs.root.mountfrom="ufs:/dev/md0"
mfsbsd.hostname="${HOSTNAME}"
LOADEREOF

	if [ "$ip" = "127.0.0.1" ]; then
		echo 'mfsbsd.autodhcp="YES"' >>"${_dest}/boot/loader.conf"
	else
		cat << LOADEREOF >>"${_dest}/boot/loader.conf"
mfsbsd.autodhcp="NO"
mfsbsd.mac_interfaces="ext1"
mfsbsd.interfaces="ext1"
mfsbsd.ifconfig_ext1="inet ${ip}/${ip_mask_short}"
mfsbsd.defaultrouter="${ip_default}"
mfsbsd.nameservers="8.8.8.8 1.1.1.1"
LOADEREOF
	fi

	if [ -n "$ipv6" ] && [ "$ipv6" != "::1" ] && [ -n "${ipv6_default}" ]; then
		# Set interfaces if not already set by IPv4 block
		if [ "$ip" = "127.0.0.1" ]; then
			cat << LOADEREOF >>"${_dest}/boot/loader.conf"
mfsbsd.mac_interfaces="ext1"
mfsbsd.interfaces="ext1"
LOADEREOF
		fi
		cat << LOADEREOF >>"${_dest}/boot/loader.conf"
mfsbsd.ifconfig_ext1_ipv6="inet6 ${ipv6}"
mfsbsd.ipv6_defaultrouter="${ipv6_default}"
mfsbsd.nameservers="8.8.8.8 1.1.1.1 2001:4860:4860::8888 2606:4700:4700::1111"
LOADEREOF
	fi

	if [ -n "${PASSWORD}" ]; then
		echo "mfsbsd.rootpw=\"${PASSWORD}\"" >>"${_dest}/boot/loader.conf"
	fi

	# Tell loader to use mfsroot
	cat << LOADEREOF >>"${_dest}/boot/loader.conf"
mfsroot_load="YES"
mfsroot_type="md_image"
mfsroot_name="/boot/mfsroot.gz"
ahci_load="YES"
LOADEREOF

	echo "loader.conf written to ${_dest}/boot/loader.conf"

}

write_grub_kfreebsd() {
	# Write GRUB config using kfreebsd method (BIOS or UEFI with module)
	_grub_dev="$1"

	GRUB_TEMP=$(mktemp)

	cat << EOF >"${GRUB_TEMP}"
${MFSBSD_MARKER}

	menuentry "${FILENAME_ISO}" {
		set isofile=${DIR_ISO}/${FILENAME_ISO}
		loopback loop ${_grub_dev}\$isofile
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
	set kFreeBSD.mfsbsd.nameservers="8.8.8.8 1.1.1.1"
EOF
	fi
	if [ -n "$ipv6" ] && [ "$ipv6" != "::1" ] && [ -n "${ipv6_default}" ] ; then
		# Set interfaces if not already set by IPv4 block
		if [ "$ip" = "127.0.0.1" ]; then
			echo "	set kFreeBSD.mfsbsd.interfaces=\"ext1\"" >>"${GRUB_TEMP}"
		fi
		cat << EOF >>"${GRUB_TEMP}"
	set kFreeBSD.mfsbsd.ifconfig_ext1_ipv6="inet6 $ipv6"
	set kFreeBSD.mfsbsd.ipv6_defaultrouter="${ipv6_default}"
	# or
	# set kFreeBSD.mfsbsd.ipv6_defaultrouter="fe80::1%ext1"
	set kFreeBSD.mfsbsd.nameservers="8.8.8.8 1.1.1.1 2001:4860:4860::8888 2606:4700:4700::1111"
EOF
	fi
	cat << EOF >>"${GRUB_TEMP}"
	# Define a new root password
	set kFreeBSD.mfsbsd.rootpw="${PASSWORD}"

	}

EOF

	menuentry=$(grep -c '^menuentry ' /boot/grub/grub.cfg 2>/dev/null || \
		grep -c '^menuentry ' /boot/grub2/grub.cfg 2>/dev/null || echo "0")
	cat << EOF >>"${GRUB_TEMP}"
set default="$((menuentry + 1))"
set timeout=1

${MFSBSD_MARKER_END}
EOF

	# Atomic append to GRUB config
	cat "${GRUB_TEMP}" >>"${GRUB_CONFIG}"
	rm -f "${GRUB_TEMP}"

}

write_grub_chainload() {
	# Write GRUB config using chainload method (UEFI without kfreebsd)
	_efi_loader_path="$1"

	GRUB_TEMP=$(mktemp)

	cat << EOF >"${GRUB_TEMP}"
${MFSBSD_MARKER}

	menuentry "${FILENAME_ISO} (UEFI chainload)" {
		insmod part_gpt
		insmod fat
		insmod chain
		chainloader ${_efi_loader_path}
	}

EOF

	menuentry=$(grep -c '^menuentry ' /boot/grub/grub.cfg 2>/dev/null || \
		grep -c '^menuentry ' /boot/grub2/grub.cfg 2>/dev/null || echo "0")
	cat << EOF >>"${GRUB_TEMP}"
set default="$((menuentry + 1))"
set timeout=1

${MFSBSD_MARKER_END}
EOF

	# Atomic append to GRUB config
	cat "${GRUB_TEMP}" >>"${GRUB_CONFIG}"
	rm -f "${GRUB_TEMP}"

}

network_settings() {

	ip=$(ip addr show | grep "inet\b" | grep -v "\blo" | awk '{print $2}' | \
		grep -Ev "^(10\.|127\.0\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)" | cut -d/ -f1 | head -1)
	ip=${ip:-"127.0.0.1"}
	ipv6=$(ip addr show | grep "inet6\b" | grep -v "\bscope host" | awk '{print $2}' | grep -Ev '^::1|^fe' | head -1)
	ipv6=${ipv6:-"::1"}
	ip_mask_short=$(ip addr show | grep "inet\b" | grep -v "\blo" | awk '{print $2}' |
		grep -Ev "^(10\.|127\.0\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)" | cut -d/ -f2 | head -1)

	ip_default=$(ip route | grep default | awk '{print $3;}' | head -1)
	ip_mask=${ip_mask:-"255.255.255.0"}
	ip_mask_short=${ip_mask_short:-"24"}
	[ "${ip_mask_short}" = "32" ] && ip_mask_short=22
	ipv6_default=$(ip -6 route | grep default | awk '{print $3;}' | head -1)
	iface_mac=$(ip link show | grep ether | head -1 | awk '{print $2;}')

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
		Usage: $0 [-hUv] [-m url_iso -a md5_iso] [-H your_hostname] [-i network_iface] [-p 'myPassW0rD'] [-s need_free_space]

		  -a :  Md5 checksum rescue ISO
		  -h :  Show help
		  -H :  Set the hostname of the host. The default value is 'YOURHOSTNAME'.
		  -i :  Use a specific network interface if the machine has more than one.
		        By default, a network interfaces is $INTERFACE.
		  -m :  URL of mfsbsd image (defaults to image on https://mfsbsd.vx.sk)
		        For example, ISO $MFSBSDISO.
		        Some ISO images do not have ssh key access, so be aware of the risks.
		  -p :  The user password to set in the Rescue ISO.
		        By default, MfsBSD's password is 'mfsroot'.
		  -s :  How much more do you need to check the availability of free disk space.
		        Supported suffixes are 'M' for MiB (by default) and 'G' for GiB.
		  -U :  Force UEFI boot mode. By default, the boot mode is auto-detected.
		        In UEFI mode, the script uses the EFI System Partition (ESP) and
		        chainloads FreeBSD's loader.efi if GRUB kfreebsd module is unavailable.
		  -v :  Show version

	EOF
}

while getopts "a:hUvi:H:m:p:s:" flags; do
	case "${flags}" in
	a)
		ISO_HASH="${OPTARG}"
		;;
	h)
		usage
		exit 0
		;;
	U)
		FORCE_UEFI=1
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

# Detect boot mode (UEFI or BIOS)
detect_boot_mode

# Handle UEFI-specific setup
if [ "${BOOT_MODE}" = "uefi" ]; then
	find_esp_mount
	detect_secure_boot
	DIR_ISO="${ESP_DIR}/images"
fi

FILENAME_ISO=${MFSBSDISO##*/}
domain=$(echo "$MFSBSDISO" | awk -F/ '{print $3;}')

case ${FILENAME_ISO} in
# standard
mfsbsd-12.2-RELEASE-amd64.iso) ISO_HASH=00eba73ac3a2940b533f2348da88d524 ;;
mfsbsd-13.0-RELEASE-amd64.iso) ISO_HASH=149ca4ecf9b39af7218481d13c3325b4 ;;
mfsbsd-13.1-RELEASE-amd64.iso) ISO_HASH=128ad6b7cc8cb0f163e293d570136e93 ;;
mfsbsd-13.2-RELEASE-amd64.iso) ISO_HASH=def450bae216370b68d98759b2b9e331 ;;
mfsbsd-14.0-RELEASE-amd64.iso) ISO_HASH=bffaf11a441105b54823981416ae0166 ;;
esac

[ -z "${ISO_HASH}" ] && exit_error "No checksum defined for ${FILENAME_ISO}. Use -a to provide one."

check_free_space_boot

apt-get update || yum makecache
apt-get -y install wget || yum -y install wget
if [ "${BOOT_MODE}" = "uefi" ]; then
	apt-get -y install efibootmgr || yum -y install efibootmgr
fi

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

# Detect GRUB device for the ISO directory
GRUB_DEV=$(get_grub_device "$DIR_ISO")
echo "GRUB device for ${DIR_ISO}: ${GRUB_DEV}"

if [ "${BOOT_MODE}" = "bios" ]; then
	# Legacy BIOS: always use kfreebsd
	write_grub_kfreebsd "${GRUB_DEV}"
	echo "GRUB config written (kfreebsd, BIOS mode)"
else
	# UEFI mode: try kfreebsd first, fall back to chainload
	if check_kfreebsd_module; then
		echo "Using kfreebsd method for UEFI boot"
		write_grub_kfreebsd "${GRUB_DEV}"
		echo "GRUB config written (kfreebsd, UEFI mode)"
	else
		echo "kfreebsd module not found, trying to install..."
		if install_kfreebsd_module && check_kfreebsd_module; then
			echo "Using kfreebsd method for UEFI boot (after install)"
			write_grub_kfreebsd "${GRUB_DEV}"
			echo "GRUB config written (kfreebsd, UEFI mode)"
		else
			echo "kfreebsd unavailable, falling back to UEFI chainload method"
			# Extract boot files from ISO to ESP
			MFSBSD_EFI_DIR="${ESP_DIR}/mfsbsd"
			rm -rf "${MFSBSD_EFI_DIR}"
			extract_boot_files "${DIR_ISO}/${FILENAME_ISO}" "${MFSBSD_EFI_DIR}"
			write_loader_conf "${MFSBSD_EFI_DIR}"

			# Copy loader.efi to standard EFI location
			mkdir -p "${ESP_DIR}/EFI/FreeBSD"
			cp "${MFSBSD_EFI_DIR}/boot/loader.efi" "${ESP_DIR}/EFI/FreeBSD/loader.efi"

			# Determine chainloader path relative to ESP root
			EFI_LOADER_PATH="/EFI/FreeBSD/loader.efi"

			write_grub_chainload "${EFI_LOADER_PATH}"
			echo "GRUB config written (chainload, UEFI mode)"
			echo "Boot files extracted to ${MFSBSD_EFI_DIR}"
		fi
	fi
fi

# Generating the correct GRUB config
if command -v update-grub >/dev/null 2>&1; then
	update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1; then
	grub2-mkconfig -o /boot/grub2/grub.cfg
else
	exit_error "Neither update-grub nor grub2-mkconfig found"
fi

echo reboot!
