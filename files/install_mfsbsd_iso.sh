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
	printf '\t\tsearch --no-floppy --fs-uuid --set=root %s\n' "${_uuid}"
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
		# The "kfreebsd" command is provided by bsd.mod
		if [ -f "${_grubdir}/bsd.mod" ]; then
			echo "Found GRUB module bsd.mod (kfreebsd) in ${_grubdir}"
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
# Reads globals: ip, ip_mask_short, ip_default, ip_mode,
#                ipv6, ipv6_prefix, ipv6_default, ipv6_mode,
#                iface_mac, HOSTNAME, PASSWORD, DNS_SERVERS_V4, DNS_SERVERS_V6
#
# MfsBSD (/etc/rc.d/mfsbsd) reads only these variables: hostname,
# mac_interfaces, ifconfig_<name>_mac, interfaces, ifconfig_<name>, autodhcp,
# defaultrouter, static_routes, route_<name>, nameservers, rootpw, rootpwhash,
# cloned_interfaces. It has nothing for IPv6: the IPv6 lines below are passed
# to the kernel environment, but a stock MfsBSD image does not apply them.
emit_mfsbsd_net() {
	_out="$1"
	_p="$2"

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
		# /32 host mask = point-to-point (e.g. Hetzner-style where the
		# gateway lives outside the host's subnet). FreeBSD ifconfig
		# accepts "inet <ip> <peer> netmask 255.255.255.255".
		if [ "${ip_mask_short}" = "32" ] && [ -n "${ip_default}" ]; then
			ifcfg="inet ${ip} ${ip_default} netmask 255.255.255.255"
		else
			ifcfg="inet ${ip}/${ip_mask_short}"
		fi
		emit_var mfsbsd.autodhcp "NO"
		emit_var mfsbsd.ifconfig_ext1 "${ifcfg}"
		if [ -n "${ip_default}" ]; then
			emit_var mfsbsd.defaultrouter "${ip_default}"
		fi
	fi

	# IPv6: slaac, static, or none (see the note above: not applied by stock MfsBSD)
	case "${ipv6_mode}" in
	slaac)
		emit_var mfsbsd.ifconfig_ext1_ipv6 "inet6 accept_rtadv"
		emit_var mfsbsd.rtsold_enable "YES"
		emit_var mfsbsd.ipv6_activate_all_interfaces "YES"
		;;
	static)
		if [ -n "${ipv6}" ] && [ "${ipv6}" != "::1" ]; then
			emit_var mfsbsd.ifconfig_ext1_ipv6 "inet6 ${ipv6}/${ipv6_prefix}"
			if [ -n "${ipv6_default}" ]; then
				emit_var mfsbsd.ipv6_defaultrouter "${ipv6_default}"
			fi
		fi
		;;
	esac

	# DNS — append IPv6 servers if IPv6 is configured at all
	if [ "${ipv6_mode}" != "none" ]; then
		emit_var mfsbsd.nameservers "${DNS_SERVERS_V4} ${DNS_SERVERS_V6}"
	else
		emit_var mfsbsd.nameservers "${DNS_SERVERS_V4}"
	fi

	# MfsBSD started by GRUB on a UEFI machine reports machdep.bootmethod=BIOS
	# (GRUB does not pass the EFI system table). Leave a hint for the
	# installer (gozfs.sh reads it) so it does not install BIOS-only boot code.
	if [ "${BOOT_MODE}" = "uefi" ]; then
		emit_var mfsbsd.bootmethod "UEFI"
	fi

	if [ -n "${PASSWORD}" ]; then
		emit_var mfsbsd.rootpw "${PASSWORD}"
	fi
}

write_loader_conf() {
	# Generate FreeBSD loader.conf for UEFI chainload boot
	# Usage: write_loader_conf /destination
	_dest="$1"

	cat << LOADEREOF >"${_dest}/boot/loader.conf"
# Generated by install_mfsbsd_iso.sh v${version_script}
vfs.root.mountfrom="ufs:/dev/md0"
LOADEREOF

	emit_mfsbsd_net "${_dest}/boot/loader.conf" ""

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

	cat << EOF >>"${GRUB_TEMP}"
	}

set default="mfsbsd"
set timeout=1

${MFSBSD_MARKER_END}
EOF

	# Atomic append to GRUB config
	cat "${GRUB_TEMP}" >>"${GRUB_CONFIG}"
	rm -f "${GRUB_TEMP}"

}

write_grub_chainload() {
	# Write GRUB config using chainload method (UEFI without kfreebsd)
	# Usage: write_grub_chainload /EFI/path/of/loader.efi   (relative to the ESP)
	_efi_loader_path="$1"

	GRUB_TEMP=$(mktemp)

	cat << EOF >"${GRUB_TEMP}"
${MFSBSD_MARKER}

	menuentry "${FILENAME_ISO} (UEFI chainload)" --id mfsbsd {
EOF
	grub_access_lines "${ESP_DIR}" >>"${GRUB_TEMP}"
	cat << EOF >>"${GRUB_TEMP}"
		insmod chain
		chainloader ${_efi_loader_path}
	}

set default="mfsbsd"
set timeout=1

${MFSBSD_MARKER_END}
EOF

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
	# Link-local gateway must carry scope ID in FreeBSD (e.g. fe80::1%ext1)
	case "${ipv6_default}" in
	fe80:*)
		ipv6_default="${ipv6_default}%ext1"
		;;
	esac

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
		Usage: $0 [-DhSUv] [-m url_iso -a md5_iso] [-H your_hostname] [-i network_iface] [-p 'myPassW0rD'] [-s need_free_space]

		  -a :  Md5 checksum rescue ISO
		  -D :  Force DHCP/SLAAC for both IPv4 and IPv6 (override auto-detection).
		        Useful when Linux uses static config but mfsbsd should DHCP
		        (e.g. cloud images where DHCP is the canonical configuration).
		  -h :  Show help
		  -H :  Set the hostname of the host. The default value is 'YOURHOSTNAME'.
		  -i :  Use a specific network interface to bind mfsbsd's "ext1" to.
		        By default, the script auto-detects the interface that carries
		        the default route under Linux. Use -i to override.
		  -m :  URL of mfsbsd image (defaults to image on https://mfsbsd.vx.sk)
		        For example, ISO $MFSBSDISO.
		        Some ISO images do not have ssh key access, so be aware of the risks.
		  -p :  The user password to set in the Rescue ISO.
		        By default, MfsBSD's password is 'mfsroot'.
		  -s :  How much more do you need to check the availability of free disk space.
		        Supported suffixes are 'M' for MiB (by default) and 'G' for GiB.
		  -S :  Force static config for both IPv4 and IPv6 (override auto-detection).
		        Useful when Linux DHCP-leased the address but you want mfsbsd
		        to keep it pinned across the reboot.
		  -U :  Force UEFI boot mode. By default, the boot mode is auto-detected.
		        In UEFI mode the kernel is started by GRUB as well ("kfreebsd");
		        Secure Boot must be off. If GRUB has no bsd module, the script
		        falls back to chainloading loader.efi from the ESP, which needs
		        an ISO that contains /boot/loader.efi (stock MfsBSD ISOs do not).
		  -v :  Show version

	EOF
}

while getopts "a:DhSUvi:H:m:p:s:" flags; do
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

# The ISO always goes to /boot/images: GRUB reads it from there in both
# BIOS and UEFI mode ("loopback" + "kfreebsd"). The ESP is usually too small
# for the ISO and is only needed for the chainload fallback.
if [ "${BOOT_MODE}" = "uefi" ]; then
	detect_secure_boot
fi

FILENAME_ISO=${MFSBSDISO##*/}

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

echo "================ mfsbsd network config ================"
echo "  interface  : ${net_iface}"
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
if [ "${ipv6_mode}" != "none" ]; then
	echo "NOTE: a stock MfsBSD image does not apply IPv6 settings, it will come up with IPv4 only."
fi

# Remove previous MfsBSD entries if present
MFSBSD_MARKER="# --- BEGIN MFSBSD ---"
MFSBSD_MARKER_END="# --- END MFSBSD ---"
if grep -q "${MFSBSD_MARKER}" "${GRUB_CONFIG}" 2>/dev/null; then
	sed -i "/${MFSBSD_MARKER}/,/${MFSBSD_MARKER_END}/d" "${GRUB_CONFIG}"
fi


RELOCATOR_FIX=""
if [ "${BOOT_MODE}" = "bios" ]; then
	# Legacy BIOS: always use kfreebsd
	make_fixed_relocator "${DIR_ISO}"
	write_grub_kfreebsd "${DIR_ISO}/${FILENAME_ISO}"
	echo "GRUB config written (kfreebsd, BIOS mode)"
else
	# UEFI mode: try kfreebsd first, fall back to chainload
	if check_kfreebsd_module; then
		echo "Using kfreebsd method for UEFI boot"
		write_grub_kfreebsd "${DIR_ISO}/${FILENAME_ISO}"
		echo "GRUB config written (kfreebsd, UEFI mode)"
	else
		echo "kfreebsd module not found, trying to install..."
		if install_kfreebsd_module && check_kfreebsd_module; then
			echo "Using kfreebsd method for UEFI boot (after install)"
			write_grub_kfreebsd "${DIR_ISO}/${FILENAME_ISO}"
			echo "GRUB config written (kfreebsd, UEFI mode)"
		else
			echo "kfreebsd unavailable, falling back to UEFI chainload method"
			find_esp_mount
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
