#!/bin/sh

# Copyright
# Vladyslav V. Prodan <github.com/click0>
# https://support.od.ua
# 2018-2026

script_type="self-contained"
# shellcheck disable=SC2034
version_script="1.31"

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
INTERFACE="em0" # default placeholder; only used if -i is given
INTERFACE_USER_SET=0
BSD_IFACE="" # FreeBSD name of that interface (-I); guessed from the Linux driver when empty
NEED_FREE_SPACE="99" # in megabytes!
DIR_ISO=/boot/images
GRUB_CONFIG=/etc/grub.d/40_custom
BOOT_MODE=""
FORCE_UEFI=0
FORCE_DHCP=0
FORCE_STATIC=0
DNS_SERVERS_V4="8.8.8.8 1.1.1.1"
DNS_SERVERS_V6="2001:4860:4860::8888 2606:4700:4700::1111"
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
	*"validation is disabled"*)
		# shim does not verify anything: the same as Secure Boot off
		;;
	*enabled*)
		echo "Secure Boot is enabled." >&2
		echo "Neither GRUB's kfreebsd nor FreeBSD's loader.efi (both unsigned) start with Secure Boot on." >&2
		# mokutil asks for a password here and needs somebody at the console
		# after the reboot (MOK Manager), so it is tried on a terminal only.
		if [ -t 0 ] && command -v mokutil >/dev/null 2>&1; then
			echo "Attempting to disable Secure Boot validation via mokutil..."
			echo "You will be prompted to create a password for MOK management."
			echo "After reboot, follow the MOK Manager prompts to confirm."
			mokutil --disable-validation || exit_error "Failed to disable Secure Boot validation"
			echo "Secure Boot validation disable scheduled. Will take effect after reboot."
		else
			exit_error "Disable Secure Boot in the firmware setup and run the script again. Nothing was changed."
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
				mount "/dev/${esp_part}" /boot/efi || return 1
				ESP_DIR="/boot/efi"
				echo "Mounted ESP /dev/${esp_part} at /boot/efi"
			fi
		fi
	fi

	if [ -z "${ESP_DIR}" ]; then
		echo "EFI System Partition (ESP) not found"
		return 1
	fi

	echo "ESP mount point: ${ESP_DIR}"

}

grub_tool() {
	# Print the path of a GRUB userland tool: grub-<name> or grub2-<name>
	command -v "grub-$1" 2>/dev/null || command -v "grub2-$1" 2>/dev/null
}

grub_access_lines() {
	# Print GRUB commands that make the filesystem holding directory $1
	# the current GRUB root.
	# Device names like (hd0,1) are not stable, and without device.map
	# "grub-probe --target=drive" returns (hostdisk//dev/...), which GRUB
	# does not understand at boot time. So the filesystem is found by UUID.
	_dir="$1"
	_probe=$(grub_tool probe) || exit_error "grub-probe not found"
	_uuid=$("${_probe}" --target=fs_uuid "${_dir}") || exit_error "Cannot determine the filesystem UUID of ${_dir}"
	for _m in $("${_probe}" --target=abstraction "${_dir}" 2>/dev/null); do
		printf '\t\tinsmod %s\n' "${_m}"
	done
	for _m in $("${_probe}" --target=partmap "${_dir}" 2>/dev/null); do
		printf '\t\tinsmod part_%s\n' "${_m}"
	done
	for _m in $("${_probe}" --target=fs "${_dir}" 2>/dev/null); do
		printf '\t\tinsmod %s\n' "${_m}"
	done
	# The same as grub-mkconfig writes: the device as GRUB most likely sees it,
	# then a search by UUID with that device as a hint. Without the hint
	# GRUB does not find a filesystem on LVM or software RAID at all.
	_hint=$("${_probe}" --target=compatibility_hint "${_dir}" 2>/dev/null || true)
	if [ -n "${_hint}" ]; then
		printf "\t\tset root='%s'\n" "${_hint}"
	fi
	_hints=$("${_probe}" --target=hints_string "${_dir}" 2>/dev/null || true)
	if [ -n "${_hints}" ]; then
		printf '\t\tif [ x$feature_platform_search_hint = xy ]; then\n'
		printf '\t\t\tsearch --no-floppy --fs-uuid --set=root %s %s\n' "${_hints}" "${_uuid}"
		printf '\t\telse\n'
		printf '\t\t\tsearch --no-floppy --fs-uuid --set=root %s\n' "${_uuid}"
		printf '\t\tfi\n'
	else
		printf '\t\tsearch --no-floppy --fs-uuid --set=root %s\n' "${_uuid}"
	fi
}

grub_rel_path() {
	# Print path $1 relative to the root of its filesystem
	# (separate /boot, ESP, btrfs subvolume, ...)
	_mkrelpath=$(grub_tool mkrelpath) || exit_error "grub-mkrelpath not found"
	"${_mkrelpath}" "$1"
}

make_fixed_relocator() {
	# GRUB 2.06 built for i386-pc (BIOS) jumps to a wrong address when it
	# starts a 64-bit kernel: relocator64.S emits "jmp *0(%rip)" followed by
	# 8 bytes instead of 4, so "kfreebsd" resets the machine right after
	# "Booting ...". Fixed upstream in GRUB 2.12; Debian 12 and Ubuntu 22.04
	# ship 2.06.
	# The installed GRUB is left alone: a corrected copy of relocator.mod
	# (one byte: the displacement of that jump, 0 -> 4) is put next to the
	# ISO and the menu entry loads it by path before "kfreebsd" would pull
	# in the broken one.
	# Usage: make_fixed_relocator /directory/for/the/copy
	RELOCATOR_FIX=""
	for _mod in /boot/grub/i386-pc/relocator.mod /boot/grub2/i386-pc/relocator.mod; do
		[ -f "${_mod}" ] || continue
		_off=$(od -An -v -tx1 "${_mod}" | tr -d ' \n' | awk '{
			sig = "48ba0000000000000000fcff2500000000000000000000000000000000"
			i = index($0, sig)
			if (i > 0 && i % 2 == 1) print (i - 1) / 2 + 13
		}')
		[ -n "${_off}" ] || continue
		cp "${_mod}" "$1/relocator.mod"
		printf '\004' | dd of="$1/relocator.mod" bs=1 seek="${_off}" conv=notrunc 2>/dev/null
		RELOCATOR_FIX="$1/relocator.mod"
		echo "GRUB relocator bug found in ${_mod} (GRUB 2.06): using the corrected copy ${RELOCATOR_FIX}"
		return 0
	done
	return 0
}

ensure_efi_grub_modules() {
	# "kfreebsd" (bsd.mod) under UEFI: the running GRUB loads its modules
	# from <grub directory>/x86_64-efi. Debian and Ubuntu keep them there,
	# RHEL-like systems install them under /usr/lib/grub only.
	_gd=$(grub_dir) || return 1
	if [ -f "${_gd}/x86_64-efi/bsd.mod" ]; then
		return 0
	fi
	for _src in /usr/lib/grub/x86_64-efi /usr/share/grub/x86_64-efi; do
		if [ -f "${_src}/bsd.mod" ]; then
			mkdir -p "${_gd}/x86_64-efi"
			cp "${_src}"/*.mod "${_src}"/*.lst "${_gd}/x86_64-efi/" || return 1
			echo "GRUB modules copied from ${_src} to ${_gd}/x86_64-efi"
			return 0
		fi
	done
	return 1
}

grub_dir() {
	# Print the directory of the GRUB configuration in use
	for _d in /boot/grub /boot/grub2; do
		if [ -f "${_d}/grub.cfg" ]; then
			echo "${_d}"
			return 0
		fi
	done
	return 1
}

can_boot_once() {
	# MfsBSD is started once: GRUB clears a flag in its environment block
	# before it starts MfsBSD, so a machine on which MfsBSD does not come up
	# (or is rebooted) returns to Linux instead of looping. If GRUB cannot
	# even start the entry, it falls back to the entry that was the default.
	# GRUB can write the environment block only on a plain filesystem.
	GRUB_DIR=$(grub_dir) || return 1
	_probe=$(grub_tool probe) || return 1
	grub_tool editenv >/dev/null || return 1
	[ -z "$("${_probe}" --target=abstraction "${GRUB_DIR}" 2>/dev/null)" ] || return 1
	case "$("${_probe}" --target=fs "${GRUB_DIR}" 2>/dev/null)" in
	ext2 | xfs | fat) return 0 ;;
	esac
	return 1
}

grub_default_lines() {
	# Print the GRUB commands that select the "mfsbsd" menu entry
	if [ "${BOOT_ONCE}" = "1" ]; then
		cat << 'EOF'
if [ "${mfsbsd_once}" = "1" ]; then
	set mfsbsd_once=
	save_env mfsbsd_once
	set fallback="${default}"
	set default="mfsbsd"
	set timeout=1
fi
EOF
	else
		cat << 'EOF'
set fallback="${default}"
set default="mfsbsd"
set timeout=1
EOF
	fi
}

extract_efi_loader() {
	# Copy FreeBSD's loader.efi out of the ISO.
	# Usage: extract_efi_loader /mounted/iso /path/to/iso /destination/loader.efi
	# Stock MfsBSD ISOs have no /boot/loader.efi: the loader is only inside
	# the El Torito EFI boot image (a FAT image), found via the boot catalog.
	if [ -f "$1/boot/loader.efi" ]; then
		cp "$1/boot/loader.efi" "$3"
		return $?
	fi

	# Boot Record Volume Descriptor is sector 17, the catalog LBA is at +71
	_cat=$(od -An -tu4 -j $((17 * 2048 + 71)) -N4 "$2" | tr -d ' ')
	[ -n "${_cat}" ] || return 1
	_platform=""
	_lba=""
	_i=0
	while [ "${_i}" -lt 64 ]; do
		_off=$((_cat * 2048 + _i * 32))
		_b0=$(od -An -tu1 -j "${_off}" -N1 "$2" | tr -d ' ')
		_b1=$(od -An -tu1 -j $((_off + 1)) -N1 "$2" | tr -d ' ')
		case "${_b0}" in
		1 | 144 | 145)
			# validation entry / section header: platform id (239 = EFI)
			_platform="${_b1}"
			;;
		136)
			# bootable entry: start of the image in 2048-byte sectors at +8
			if [ "${_platform}" = "239" ]; then
				_lba=$(od -An -tu4 -j $((_off + 8)) -N4 "$2" | tr -d ' ')
				break
			fi
			;;
		esac
		_i=$((_i + 1))
	done
	[ -n "${_lba}" ] || return 1

	# The image is a FAT filesystem; its size is in its own boot sector.
	# It is copied out first: the ISO is already attached to a loop device,
	# and Linux refuses a second, overlapping one.
	_base=$((_lba * 2048))
	_bps=$(od -An -tu2 -j $((_base + 11)) -N2 "$2" | tr -d ' ')
	_secs=$(od -An -tu2 -j $((_base + 19)) -N2 "$2" | tr -d ' ')
	if [ "${_secs:-0}" -eq 0 ]; then
		_secs=$(od -An -tu4 -j $((_base + 32)) -N4 "$2" | tr -d ' ')
	fi
	_size=$((${_bps:-0} * ${_secs:-0}))
	if [ "${_size}" -le 0 ] || [ "${_size}" -gt 268435456 ]; then
		return 1
	fi
	_efiimg=$(mktemp)
	_efimnt=$(mktemp -d)
	_rc=1
	if dd if="$2" of="${_efiimg}" bs=2048 skip="${_lba}" count=$(((_size + 2047) / 2048)) 2>/dev/null &&
		mount -t vfat -o loop,ro "${_efiimg}" "${_efimnt}" 2>/dev/null; then
		for _f in EFI/BOOT/BOOTX64.EFI efi/boot/bootx64.efi; do
			if [ -f "${_efimnt}/${_f}" ]; then
				cp "${_efimnt}/${_f}" "$3" && _rc=0
				break
			fi
		done
		umount "${_efimnt}"
	fi
	rmdir "${_efimnt}"
	rm -f "${_efiimg}"
	return ${_rc}
}

remove_efi_boot_files() {
	[ -n "${ESP_DIR}" ] || return 0
	# Remove what install_efi_boot_files left on the ESP (only our own files)
	if [ -f "${ESP_DIR}/boot/.mfsbsd" ]; then
		rm -rf "${ESP_DIR:?}/boot" "${ESP_DIR:?}/mfsroot.gz" "${ESP_DIR:?}/EFI/mfsbsd"
	fi
}

install_efi_boot_files() {
	# Put FreeBSD's loader.efi, the kernel and the memory disk on the ESP, so
	# the firmware side of the boot is a normal FreeBSD UEFI boot (console on
	# the screen, EFI runtime services, machdep.bootmethod=UEFI).
	# Usage: install_efi_boot_files /path/to/iso      (needs ESP_DIR)
	# Returns 1 when that is not possible; the ESP is left as it was.
	_iso="$1"

	remove_efi_boot_files
	if [ -e "${ESP_DIR}/boot" ] || [ -e "${ESP_DIR}/mfsroot.gz" ]; then
		echo "The ESP already has /boot or /mfsroot.gz that are not ours"
		return 1
	fi

	_mnt=$(mktemp -d)
	if ! mount -o loop,ro "${_iso}" "${_mnt}" 2>/dev/null; then
		rmdir "${_mnt}"
		echo "Cannot mount the ISO"
		return 1
	fi

	_ok=1
	if [ ! -f "${_mnt}/mfsroot.gz" ] || [ ! -d "${_mnt}/boot/kernel" ]; then
		echo "Unexpected ISO layout (no /mfsroot.gz or /boot/kernel)"
		_ok=0
	fi

	if [ "${_ok}" = "1" ]; then
		# everything but the BIOS loader; if the estimate is too low, the
		# copy fails and the ESP is cleaned up again
		_need=$(du -sk "${_mnt}/boot" "${_mnt}/mfsroot.gz" | awk '{ n += $1 } END { print n }')
		if [ -f "${_mnt}/boot/loader" ]; then
			_need=$((_need - $(du -sk "${_mnt}/boot/loader" | awk '{ print $1 }')))
		fi
		_need=$((_need + 512))
		_free=$(df -Pk "${ESP_DIR}" | awk 'NR == 2 { print $4 }')
		if [ "${_free:-0}" -lt "${_need}" ]; then
			echo "Not enough room on the ESP: ${_free:-0} kB free, ${_need} kB needed"
			_ok=0
		fi
	fi

	if [ "${_ok}" = "1" ]; then
		mkdir -p "${ESP_DIR}/boot" "${ESP_DIR}/EFI/mfsbsd"
		touch "${ESP_DIR}/boot/.mfsbsd"
		# the BIOS loader is of no use here
		if cp -r "${_mnt}/boot/." "${ESP_DIR}/boot/" &&
			rm -f "${ESP_DIR}/boot/loader" &&
			extract_efi_loader "${_mnt}" "${_iso}" "${ESP_DIR}/EFI/mfsbsd/loader.efi" &&
			cp "${_mnt}/mfsroot.gz" "${ESP_DIR}/mfsroot.gz"; then
			{
				echo "# Added by install_mfsbsd_iso.sh v${version_script}"
				echo 'autoboot_delay="2"'
			} >>"${ESP_DIR}/boot/loader.conf"
			emit_mfsbsd_net "${ESP_DIR}/boot/loader.conf" ""
		else
			echo "Cannot copy the boot files to the ESP or find loader.efi in the ISO"
			_ok=0
		fi
	fi

	umount "${_mnt}"
	rmdir "${_mnt}"

	if [ "${_ok}" != "1" ]; then
		remove_efi_boot_files
		return 1
	fi
	echo "FreeBSD boot files are on the ESP (${ESP_DIR}/boot, ${ESP_DIR}/mfsroot.gz, ${ESP_DIR}/EFI/mfsbsd)"
	return 0
}

linux_to_bsd_driver() {
	# Print the FreeBSD driver name for a Linux network driver
	case "$1" in
	virtio_net) echo vtnet ;;
	e1000 | e1000e) echo em ;;
	igb) echo igb ;;
	igc) echo igc ;;
	ixgbe) echo ix ;;
	ixgbevf) echo ixv ;;
	i40e) echo ixl ;;
	iavf) echo iavf ;;
	ice) echo ice ;;
	tg3) echo bge ;;
	bnx2) echo bce ;;
	bnx2x) echo bxe ;;
	bnxt_en) echo bnxt ;;
	r8169) echo re ;;
	mlx4_en | mlx4_core) echo mlxen ;;
	mlx5_core) echo mce ;;
	vmxnet3) echo vmx ;;
	hv_netvsc) echo hn ;;
	ena) echo ena ;;
	gve) echo gve ;;
	xen_netfront | vif) echo xn ;;
	esac
}

guess_bsd_iface() {
	# Print the name FreeBSD will most likely give to Linux interface $1:
	# <driver><unit>, where the unit is the position among the cards of the
	# same driver in PCI order. Prints nothing for an unknown driver.
	[ -e "/sys/class/net/$1/device/driver" ] || return 0
	_bsd=$(linux_to_bsd_driver "$(basename "$(readlink -f "/sys/class/net/$1/device/driver")")")
	[ -n "${_bsd}" ] || return 0
	_self=$(readlink -f "/sys/class/net/$1/device")
	_unit=0
	for _n in /sys/class/net/*; do
		[ -e "${_n}/device/driver" ] || continue
		_d=$(linux_to_bsd_driver "$(basename "$(readlink -f "${_n}/device/driver")")")
		[ "${_d}" = "${_bsd}" ] || continue
		_path=$(readlink -f "${_n}/device")
		[ "${_path}" != "${_self}" ] || continue
		if [ "$(printf '%s\n%s\n' "${_path}" "${_self}" | sort | head -1)" = "${_path}" ]; then
			_unit=$((_unit + 1))
		fi
	done
	echo "${_bsd}${_unit}"
}

ip4_same_net() {
	# Usage: ip4_same_net <ip> <ip> <prefix length>; true if both are in one network
	[ "$3" -gt 0 ] || return 0
	_a=$(echo "$1" | awk -F. '{ printf "%.0f", $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }')
	_b=$(echo "$2" | awk -F. '{ printf "%.0f", $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }')
	[ $((_a >> (32 - $3))) -eq $((_b >> (32 - $3))) ]
}

hash_password() {
	# Print the SHA-512 crypt hash of $1, or nothing if no tool can make one
	if command -v openssl >/dev/null 2>&1; then
		printf '%s\n' "$1" | openssl passwd -6 -stdin 2>/dev/null && return 0
	fi
	if command -v mkpasswd >/dev/null 2>&1; then
		printf '%s\n' "$1" | mkpasswd -m sha-512 -s 2>/dev/null && return 0
	fi
	return 0
}

emit_var() {
	# Write one variable of the MfsBSD configuration.
	# Usage: emit_var <name> <value>   (uses _out and _p of emit_mfsbsd_net)
	if [ -n "${_p}" ]; then
		# GRUB: inside single quotes everything is literal ($, ", \ ...);
		# a single quote itself is written as '\''
		printf "%s%s='%s'\n" "${_p}" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")" >>"${_out}"
	else
		# loader.conf: double quotes, \ and " are escaped
		printf '%s="%s"\n' "$1" "$(printf '%s' "$2" | sed 's/[\\"]/\\&/g')" >>"${_out}"
	fi
}

# Emit mfsbsd network configuration to a destination file.
# Usage: emit_mfsbsd_net <output_file> <line_prefix>
#   <line_prefix> = "\t\tset kFreeBSD." for GRUB env, "" for loader.conf
# Reads globals: ip, ip_mask_short, ip_default, ip_mode, ip_gw_onlink,
#                ipv6, ipv6_prefix, ipv6_default, ipv6_mode, bsd_iface,
#                iface_mac, HOSTNAME, PASSWORD, DNS_SERVERS_V4, DNS_SERVERS_V6
#
# MfsBSD (/etc/rc.d/mfsbsd) reads only these variables: hostname,
# mac_interfaces, ifconfig_<name>_mac, interfaces, ifconfig_<name>, autodhcp,
# defaultrouter, static_routes, route_<name>, nameservers, rootpw, rootpwhash,
# cloned_interfaces. IPv4 is bound to the card by its MAC address ("ext1").
# There is no such binding for IPv6 and for routes through an interface:
# these need the FreeBSD name of the card (bsd_iface).
emit_mfsbsd_net() {
	_out="$1"
	_p="$2"
	_ifaces=""
	_routes=""

	# hostname always
	emit_var mfsbsd.hostname "${HOSTNAME}"

	# Bind logical "ext1" to a specific physical NIC by MAC.
	# Without ifconfig_ext1_mac, mfsbsd binds to the first probed NIC,
	# which is unreliable on multi-interface hosts.
	if [ -n "${iface_mac}" ]; then
		emit_var mfsbsd.mac_interfaces "ext1"
		emit_var mfsbsd.ifconfig_ext1_mac "${iface_mac}"
	fi

	# IPv4: dhcp or static (mode is decided in network_settings)
	if [ "${ip_mode}" = "dhcp" ]; then
		emit_var mfsbsd.autodhcp "YES"
	else
		emit_var mfsbsd.autodhcp "NO"
		emit_var mfsbsd.ifconfig_ext1 "inet ${ip}/${ip_mask_short}"
		if [ -n "${ip_default}" ]; then
			if [ "${ip_gw_onlink}" = "1" ]; then
				emit_var mfsbsd.defaultrouter "${ip_default}"
			else
				# The gateway is outside the subnet (/32 at Hetzner, OVH, ...):
				# first a host route to it through the interface, then the
				# default route. "inet <ip> <gw> netmask 255.255.255.255" does
				# not do that on Ethernet.
				emit_var mfsbsd.route_gw4 "-host ${ip_default} -interface ${bsd_iface}"
				emit_var mfsbsd.route_def4 "default ${ip_default}"
				_routes="gw4 def4"
			fi
		fi
	fi

	# IPv6: slaac, static, or none
	case "${ipv6_mode}" in
	slaac)
		# rc(8) sends the router solicitation itself for accept_rtadv
		emit_var "mfsbsd.ifconfig_${bsd_iface}_ipv6" "inet6 accept_rtadv"
		_ifaces="${bsd_iface}_ipv6"
		;;
	static)
		emit_var "mfsbsd.ifconfig_${bsd_iface}_ipv6" "inet6 ${ipv6}/${ipv6_prefix}"
		_ifaces="${bsd_iface}_ipv6"
		if [ -n "${ipv6_default}" ]; then
			case "${ipv6_default}" in
			fe80:*)
				# a link-local gateway needs the interface as its scope
				emit_var mfsbsd.route_def6 "-inet6 default ${ipv6_default}%${bsd_iface}"
				_routes="${_routes} def6"
				;;
			*)
				# works for a gateway outside the prefix as well
				emit_var mfsbsd.route_gw6 "-inet6 -host ${ipv6_default} -interface ${bsd_iface}"
				emit_var mfsbsd.route_def6 "-inet6 default ${ipv6_default}"
				_routes="${_routes} gw6 def6"
				;;
			esac
		fi
		;;
	esac

	if [ -n "${_ifaces}" ]; then
		emit_var mfsbsd.interfaces "${_ifaces}"
	fi
	if [ -n "${_routes}" ]; then
		emit_var mfsbsd.static_routes "${_routes# }"
	fi

	# DNS — append IPv6 servers if IPv6 is configured at all
	if [ "${ipv6_mode}" != "none" ]; then
		emit_var mfsbsd.nameservers "${DNS_SERVERS_V4} ${DNS_SERVERS_V6}"
	else
		emit_var mfsbsd.nameservers "${DNS_SERVERS_V4}"
	fi

	# MfsBSD started by GRUB's kfreebsd on a UEFI machine reports
	# machdep.bootmethod=BIOS (GRUB does not pass the EFI system table). Leave
	# a hint for the installer (gozfs.sh reads it) so it does not install
	# BIOS-only boot code.
	if [ "${BOOT_MODE}" = "uefi" ]; then
		emit_var mfsbsd.bootmethod "UEFI"
	fi

	# The password goes as a hash: no plain text in the GRUB configuration,
	# and MfsBSD's unquoted "echo" cannot mangle spaces or * ? [ in it.
	# MfsBSD wants '%' in place of '$' in the hash.
	if [ -n "${PASSWORD_HASH}" ]; then
		emit_var mfsbsd.rootpwhash "$(printf '%s' "${PASSWORD_HASH}" | tr '$' '%')"
	elif [ -n "${PASSWORD}" ]; then
		emit_var mfsbsd.rootpw "${PASSWORD}"
	fi
}

write_grub_kfreebsd() {
	# Write GRUB config using kfreebsd method (BIOS or UEFI with module)
	# Usage: write_grub_kfreebsd /path/to/iso

	GRUB_TEMP=$(mktemp)
	_grub_prefix=$(printf '\t\tset kFreeBSD.')
	_iso_rel=$(grub_rel_path "$1")

	cat << EOF >"${GRUB_TEMP}"
${MFSBSD_MARKER}

	menuentry "${FILENAME_ISO}" --id mfsbsd {
EOF
	grub_access_lines "$(dirname "$1")" >>"${GRUB_TEMP}"
	if [ -n "${RELOCATOR_FIX}" ]; then
		printf '\t\tinsmod %s\n' "$(grub_rel_path "${RELOCATOR_FIX}")" >>"${GRUB_TEMP}"
	fi
	cat << EOF >>"${GRUB_TEMP}"
		set isofile="${_iso_rel}"
		loopback loop \$isofile
		kfreebsd (loop)/boot/kernel/kernel.gz -v
		# kfreebsd_loadenv (loop)/boot/device.hints
		# kfreebsd_module (loop)/boot/kernel/geom_uzip.ko
		kfreebsd_module (loop)/boot/kernel/ahci.ko
		kfreebsd_module (loop)/mfsroot.gz type=mfs_root
		set kFreeBSD.vfs.root.mountfrom="ufs:/dev/md0"
EOF

	# Under UEFI, GRUB does not hand the EFI system table to the kernel, so
	# the kernel cannot find the ACPI tables and panics ("running without
	# device atpic requires a local APIC"). Tell it where the RSDP is.
	if [ "${BOOT_MODE}" = "uefi" ] && [ -d /sys/firmware/efi ]; then
		_rsdp=$(awk -F= '$1 == "ACPI20" { print $2; exit }' /sys/firmware/efi/systab 2>/dev/null || true)
		if [ -z "${_rsdp}" ]; then
			_rsdp=$(awk -F= '$1 == "ACPI" { print $2; exit }' /sys/firmware/efi/systab 2>/dev/null || true)
		fi
		if [ -z "${_rsdp}" ]; then
			# newer kernels may not have systab; the boot log has the address too
			_rsdp=$(dmesg 2>/dev/null | sed -n 's/.*ACPI: RSDP 0x0*\([0-9A-Fa-f][0-9A-Fa-f]*\).*/0x\1/p' | head -1)
		fi
		if [ -n "${_rsdp}" ]; then
			printf '\t\tset kFreeBSD.acpi.rsdp="%s"\n' "${_rsdp}" >>"${GRUB_TEMP}"
		else
			echo "WARNING: ACPI RSDP address not found, MfsBSD may not boot" >&2
		fi
	fi

	emit_mfsbsd_net "${GRUB_TEMP}" "${_grub_prefix}"

	{
		printf '\t}\n\n'
		grub_default_lines
		printf '\n%s\n' "${MFSBSD_MARKER_END}"
	} >>"${GRUB_TEMP}"

	# Atomic append to GRUB config
	cat "${GRUB_TEMP}" >>"${GRUB_CONFIG}"
	rm -f "${GRUB_TEMP}"

}

write_grub_chainload() {
	# Write GRUB config that chainloads FreeBSD's loader.efi from the ESP (UEFI)
	# Usage: write_grub_chainload /EFI/path/of/loader.efi   (relative to the ESP)
	_efi_loader_path="$1"

	GRUB_TEMP=$(mktemp)

	cat << EOF >"${GRUB_TEMP}"
${MFSBSD_MARKER}

	menuentry "${FILENAME_ISO} (loader.efi)" --id mfsbsd {
EOF
	grub_access_lines "${ESP_DIR}" >>"${GRUB_TEMP}"
	cat << EOF >>"${GRUB_TEMP}"
		insmod chain
		chainloader ${_efi_loader_path}
EOF
	{
		printf '\t}\n\n'
		grub_default_lines
		printf '\n%s\n' "${MFSBSD_MARKER_END}"
	} >>"${GRUB_TEMP}"

	# Atomic append to GRUB config
	cat "${GRUB_TEMP}" >>"${GRUB_CONFIG}"
	rm -f "${GRUB_TEMP}"

}

network_settings() {

	# 1. Choose interface: explicit -i takes priority; otherwise the one
	#    carrying the default route under Linux; last resort - first non-lo up.
	if [ "${INTERFACE_USER_SET}" = "1" ] && \
	   ip -o link show dev "${INTERFACE}" >/dev/null 2>&1; then
		net_iface="${INTERFACE}"
		echo "Using user-specified interface: ${net_iface}"
	else
		net_iface=$(ip -4 route get 8.8.8.8 2>/dev/null \
			| awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
		[ -z "${net_iface}" ] && net_iface=$(ip -4 route show default 2>/dev/null \
			| awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
		[ -z "${net_iface}" ] && net_iface=$(ip -o link show up 2>/dev/null \
			| awk -F': ' '$2 != "lo" {print $2; exit}')
		echo "Auto-detected interface: ${net_iface:-<none>}"
	fi
	[ -z "${net_iface}" ] && exit_error "Cannot determine network interface"

	# 2. IPv4 address / mask / gateway from chosen interface only
	ip=$(ip -4 -o addr show dev "${net_iface}" scope global \
		| awk '{print $4}' | cut -d/ -f1 | head -1)
	ip=${ip:-"127.0.0.1"}
	ip_mask_short=$(ip -4 -o addr show dev "${net_iface}" scope global \
		| awk '{print $4}' | cut -d/ -f2 | head -1)
	ip_mask_short=${ip_mask_short:-"24"}
	ip_default=$(ip -4 route show default dev "${net_iface}" 2>/dev/null \
		| awk '{print $3; exit}')
	[ -z "${ip_default}" ] && ip_default=$(ip -4 route show default 2>/dev/null \
		| awk '{print $3; exit}')

	# 3. IPv4 mode auto-detect (DHCP vs static)
	ip_mode="static"
	if ip -4 -o addr show dev "${net_iface}" 2>/dev/null | grep -q 'dynamic'; then
		ip_mode="dhcp"
	elif ip -4 route show default dev "${net_iface}" 2>/dev/null | grep -q 'proto dhcp'; then
		ip_mode="dhcp"
	fi
	[ "${FORCE_DHCP}" = "1" ] && ip_mode="dhcp"
	[ "${FORCE_STATIC}" = "1" ] && ip_mode="static"

	# 4. IPv6 address (preserve prefix length!) + gateway
	ipv6_full=$(ip -6 -o addr show dev "${net_iface}" scope global \
		| awk '{print $4}' | head -1)
	ipv6=${ipv6_full%%/*}
	ipv6=${ipv6:-"::1"}
	if [ -n "${ipv6_full}" ] && [ "${ipv6_full}" != "${ipv6_full##*/}" ]; then
		ipv6_prefix=${ipv6_full##*/}
	else
		ipv6_prefix="64"
	fi

	ipv6_default=$(ip -6 route show default dev "${net_iface}" 2>/dev/null \
		| awk '{print $3; exit}')
	[ -z "${ipv6_default}" ] && ipv6_default=$(ip -6 route show default 2>/dev/null \
		| awk '{print $3; exit}')
	# 5. IPv6 mode auto-detect (SLAAC vs static)
	ipv6_mode="none"
	if [ -n "${ipv6_full}" ] && [ "${ipv6}" != "::1" ]; then
		ipv6_mode="static"
		if ip -6 -o addr show dev "${net_iface}" 2>/dev/null \
			| grep -qE 'dynamic|mngtmpaddr|noprefixroute'; then
			ipv6_mode="slaac"
		elif ip -6 route show default dev "${net_iface}" 2>/dev/null | grep -q 'proto ra'; then
			ipv6_mode="slaac"
		fi
		[ "${FORCE_DHCP}" = "1" ] && ipv6_mode="slaac"
		[ "${FORCE_STATIC}" = "1" ] && ipv6_mode="static"
	fi

	# 6. MAC of the chosen interface (used for ifconfig_ext1_mac in mfsbsd)
	iface_mac=$(ip -o link show dev "${net_iface}" \
		| awk -F'link/ether ' '/link\/ether/{print $2}' | awk '{print $1}')
	[ -z "${iface_mac}" ] && exit_error "Cannot determine MAC of ${net_iface}"

	# 7. Sanity warnings
	if [ "$ip" = "127.0.0.1" ] && [ "${ip_mode}" != "dhcp" ]; then
		cat >&2 <<__WARN__
WARNING: no global IPv4 found on ${net_iface}.
Mfsbsd will fall back to DHCP. If your network has no DHCP server,
you will lose connectivity. Press Ctrl+C now to abort (10s).
__WARN__
		sleep 10
		ip_mode="dhcp"
	fi

	case "${ip}" in
	10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
		if [ "${ip_mode}" = "static" ]; then
			cat >&2 <<__WARN__
NOTE: detected RFC1918 (private) address ${ip} on ${net_iface}.
Mfsbsd will be configured with static IP ${ip}/${ip_mask_short} via gw ${ip_default}.
Make sure this network is reachable from your console / management host.
__WARN__
		fi
		;;
	esac

	if [ -z "${ip_default}" ] && [ "${ip_mode}" = "static" ]; then
		echo "WARNING: no default IPv4 route. Mfsbsd will boot without a gateway." >&2
	fi

	# 8. FreeBSD name of the interface. IPv4 does not need it (MAC binding),
	#    IPv6 and a gateway outside the subnet do.
	if [ -n "${BSD_IFACE}" ]; then
		bsd_iface="${BSD_IFACE}"
		bsd_iface_src="given with -I"
	else
		bsd_iface=$(guess_bsd_iface "${net_iface}")
		bsd_iface_src="guessed from the Linux driver, override with -I"
	fi

	ip_gw_onlink=1
	if [ "${ip_mode}" = "static" ] && [ -n "${ip_default}" ] &&
		! ip4_same_net "${ip}" "${ip_default}" "${ip_mask_short}"; then
		ip_gw_onlink=0
		if [ -z "${bsd_iface}" ]; then
			exit_error "The gateway ${ip_default} is outside ${ip}/${ip_mask_short}: MfsBSD needs a route through the interface for it.
The FreeBSD name of ${net_iface} could not be guessed, pass it with -I (em0, igb0, ix0, vtnet0, ...). Nothing was changed."
		fi
	fi

	if [ "${ipv6_mode}" != "none" ] && [ -z "${bsd_iface}" ]; then
		echo "WARNING: the FreeBSD name of ${net_iface} could not be guessed, IPv6 will not be configured in MfsBSD. Pass the name with -I." >&2
		ipv6_mode="none"
	fi

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
		Usage: $0 [-DhSUv] [-m url_iso -a md5_iso] [-H your_hostname] [-i network_iface] [-I freebsd_iface] [-p 'myPassW0rD'] [-s need_free_space]

		  -a :  Md5 checksum rescue ISO
		  -D :  Force DHCP/SLAAC for both IPv4 and IPv6 (override auto-detection).
		        Useful when Linux uses static config but mfsbsd should DHCP
		        (e.g. cloud images where DHCP is the canonical configuration).
		  -h :  Show help
		  -H :  Set the hostname of the host. The default value is 'YOURHOSTNAME'.
		  -i :  Use a specific network interface to bind mfsbsd's "ext1" to.
		        By default, the script auto-detects the interface that carries
		        the default route under Linux. Use -i to override.
		        This is the Linux name of the interface (ens3, eth0, ...).
		  -I :  FreeBSD name of that interface (em0, igb0, ix0, vtnet0, ...).
		        IPv4 is bound to the card by its MAC address and does not need
		        it. IPv6 and a gateway outside the subnet (/32) do: by default
		        the name is guessed from the Linux driver and the PCI order.
		  -m :  URL of mfsbsd image (defaults to image on https://mfsbsd.vx.sk)
		        For example, ISO $MFSBSDISO.
		        Some ISO images do not have ssh key access, so be aware of the risks.
		  -p :  The user password to set in the Rescue ISO.
		        By default, MfsBSD's password is 'mfsroot'.
		        It is passed as a SHA-512 hash (needs openssl or mkpasswd).
		  -s :  How much more do you need to check the availability of free disk space.
		        Supported suffixes are 'M' for MiB (by default) and 'G' for GiB.
		  -S :  Force static config for both IPv4 and IPv6 (override auto-detection).
		        Useful when Linux DHCP-leased the address but you want mfsbsd
		        to keep it pinned across the reboot.
		  -U :  Force UEFI boot mode. By default, the boot mode is auto-detected.
		        Under UEFI the script puts FreeBSD's loader.efi, the kernel and
		        the memory disk on the EFI System Partition and GRUB chainloads
		        the loader. If the ESP has no room for that (about 100 MB), GRUB
		        starts the kernel itself, as under BIOS ("kfreebsd").
		        Secure Boot must be off in both cases.
		  -v :  Show version

	EOF
}

while getopts "a:DhSUvi:I:H:m:p:s:" flags; do
	case "${flags}" in
	a)
		ISO_HASH="${OPTARG}"
		;;
	D)
		FORCE_DHCP=1
		;;
	h)
		usage
		exit 0
		;;
	S)
		FORCE_STATIC=1
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
		INTERFACE_USER_SET=1
		;;
	I)
		BSD_IFACE="${OPTARG}"
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

if [ "${FORCE_DHCP}" = "1" ] && [ "${FORCE_STATIC}" = "1" ]; then
	exit_error "-D and -S are mutually exclusive"
fi

# -s: megabytes by default, 'M' and 'G' suffixes are accepted
case "${NEED_FREE_SPACE}" in
*[Gg]) NEED_FREE_SPACE="${NEED_FREE_SPACE%[Gg]}"; _space_mult=1024 ;;
*[Mm]) NEED_FREE_SPACE="${NEED_FREE_SPACE%[Mm]}"; _space_mult=1 ;;
*) _space_mult=1 ;;
esac
case "${NEED_FREE_SPACE}" in
'' | *[!0-9]*) exit_error "Invalid free space value for -s. Use a number with an optional M or G suffix." ;;
esac
NEED_FREE_SPACE=$((NEED_FREE_SPACE * _space_mult))

# Detect boot mode (UEFI or BIOS)
detect_boot_mode

# Stop before anything is changed if MfsBSD cannot be started at all
if [ "${BOOT_MODE}" = "uefi" ]; then
	detect_secure_boot
fi

case "${BSD_IFACE}" in
*[!a-z0-9]*) exit_error "Invalid FreeBSD interface name for -I: ${BSD_IFACE}" ;;
esac

FILENAME_ISO=${MFSBSDISO##*/}

# Checksums of the standard images (https://mfsbsd.vx.sk/files/iso/); -a wins
if [ -z "${ISO_HASH}" ]; then
	case ${FILENAME_ISO} in
	mfsbsd-12.2-RELEASE-amd64.iso) ISO_HASH=00eba73ac3a2940b533f2348da88d524 ;;
	mfsbsd-13.0-RELEASE-amd64.iso) ISO_HASH=149ca4ecf9b39af7218481d13c3325b4 ;;
	mfsbsd-13.1-RELEASE-amd64.iso) ISO_HASH=128ad6b7cc8cb0f163e293d570136e93 ;;
	mfsbsd-13.2-RELEASE-amd64.iso) ISO_HASH=def450bae216370b68d98759b2b9e331 ;;
	mfsbsd-14.0-RELEASE-amd64.iso) ISO_HASH=bffaf11a441105b54823981416ae0166 ;;
	mfsbsd-14.1-RELEASE-amd64.iso) ISO_HASH=97aea6b90dc85fbcdb31d068a9ae5d27 ;;
	mfsbsd-14.2-RELEASE-amd64.iso) ISO_HASH=fa759413318fedb911054bbc1c119a57 ;;
	esac
fi

[ -z "${ISO_HASH}" ] && exit_error "No checksum defined for ${FILENAME_ISO}. Use -a to provide one."

check_free_space_boot

apt-get update || yum makecache
apt-get -y install wget || yum -y install wget

mkdir -p "$DIR_ISO"
cd "$DIR_ISO" || exit 1

if [ ! -e "$FILENAME_ISO" ]; then
	# No ping probe here: ICMP is often filtered, and the host part of the URL
	# may carry a port. A partial download must not be left behind either.
	wget --tries=3 --timeout=30 -O "${FILENAME_ISO}.part" "$MFSBSDISO" || {
		rm -f "${FILENAME_ISO}.part"
		exit_error "Can't download Rescue ISO from ${MFSBSDISO}"
	}
	mv "${FILENAME_ISO}.part" "$FILENAME_ISO"
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

PASSWORD_HASH=""
if [ -n "${PASSWORD}" ]; then
	PASSWORD_HASH=$(hash_password "${PASSWORD}")
	if [ -z "${PASSWORD_HASH}" ]; then
		echo "WARNING: neither openssl nor mkpasswd can make a SHA-512 hash: the password goes to the GRUB configuration as plain text." >&2
	fi
fi

echo "================ mfsbsd network config ================"
echo "  interface  : ${net_iface}"
echo "  FreeBSD if : ${bsd_iface:-<unknown>} (${bsd_iface_src})"
echo "  MAC        : ${iface_mac}"
echo "  IPv4       : ${ip}/${ip_mask_short}"
echo "  IPv4 gw    : ${ip_default:-<none>}"
echo "  IPv4 mode  : ${ip_mode}"
echo "  IPv6       : ${ipv6_full:-<none>}"
echo "  IPv6 gw    : ${ipv6_default:-<none>}"
echo "  IPv6 mode  : ${ipv6_mode}"
echo "  DNS v4     : ${DNS_SERVERS_V4}"
echo "  DNS v6     : ${DNS_SERVERS_V6}"
echo "======================================================="
if [ "${ip_gw_onlink}" = "0" ]; then
	echo "NOTE: the IPv4 gateway is outside the subnet, the route to it goes through ${bsd_iface}."
fi

# Remove previous MfsBSD entries if present
MFSBSD_MARKER="# --- BEGIN MFSBSD ---"
MFSBSD_MARKER_END="# --- END MFSBSD ---"
if grep -q "${MFSBSD_MARKER}" "${GRUB_CONFIG}" 2>/dev/null; then
	sed -i "/${MFSBSD_MARKER}/,/${MFSBSD_MARKER_END}/d" "${GRUB_CONFIG}"
fi


BOOT_ONCE=0
if can_boot_once; then
	BOOT_ONCE=1
fi

RELOCATOR_FIX=""
ESP_DIR=""
if [ "${BOOT_MODE}" = "bios" ]; then
	# Legacy BIOS: GRUB starts the kernel itself
	make_fixed_relocator "${DIR_ISO}"
	write_grub_kfreebsd "${DIR_ISO}/${FILENAME_ISO}"
	echo "GRUB config written (kfreebsd, BIOS mode)"
elif [ -d /sys/firmware/efi ] && find_esp_mount &&
	install_efi_boot_files "${DIR_ISO}/${FILENAME_ISO}"; then
	# UEFI: FreeBSD's own loader from the ESP
	write_grub_chainload "/EFI/mfsbsd/loader.efi"
	echo "GRUB config written (loader.efi, UEFI mode)"
elif ensure_efi_grub_modules; then
	# UEFI without room on the ESP: GRUB starts the kernel itself
	echo "Using kfreebsd method for UEFI boot"
	write_grub_kfreebsd "${DIR_ISO}/${FILENAME_ISO}"
	echo "GRUB config written (kfreebsd, UEFI mode)"
else
	exit_error "MfsBSD cannot be started under UEFI here: the boot files do not fit on the ESP and GRUB has no bsd module (kfreebsd). Nothing was changed."
fi

# Generating the correct GRUB config
if command -v update-grub >/dev/null 2>&1; then
	update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1; then
	grub2-mkconfig -o /boot/grub2/grub.cfg
else
	exit_error "Neither update-grub nor grub2-mkconfig found"
fi

if [ "${BOOT_ONCE}" = "1" ]; then
	"$(grub_tool editenv)" "${GRUB_DIR}/grubenv" set mfsbsd_once=1
	echo "MfsBSD will be started once: the boot after that returns to Linux."
else
	echo "MfsBSD is now the default GRUB entry (GRUB cannot write its environment block here, so not just once)."
fi

echo reboot!
