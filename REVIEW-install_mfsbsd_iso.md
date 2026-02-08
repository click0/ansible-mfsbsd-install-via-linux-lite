# Code Review: install_mfsbsd_iso.sh

**Reviewed file:** https://github.com/click0/FreeBSD-install-scripts/blob/master/install_mfsbsd_iso.sh
**Upstream version:** 1.25 (self-contained)
**Local repo version:** 1.21 (ansible)
**Date:** 2026-02-08

---

## 1. Critical Bugs

### 1.1 `set -eo` is broken (line 12)

`set -eo` sets `-e` (exit on error) but `-o` requires an option name argument (e.g., `pipefail`). Without it, the behavior is undefined — silently ignored or error depending on the shell. Since shebang is `#!/bin/sh`, `pipefail` is not POSIX-portable anyway.

**Fix:** Change to `set -e`.

### 1.2 Empty `ISO_HASH` silently passes checksum verification (lines 129–157)

If the ISO filename doesn't match any hardcoded `case` branch and `-a` was not provided, `ISO_HASH` remains unset. Then:
```sh
md5sum "$DIR_ISO"/"$FILENAME_ISO" | grep -q ${ISO_HASH}
```
becomes `grep -q ""` which matches **any string** — checksum verification silently passes for any file, including corrupted or malicious ones.

**Fix:** Add a check before verification:
```sh
[ -z "${ISO_HASH}" ] && exit_error "No MD5 hash defined for ${FILENAME_ISO}. Use -a to provide one."
```

### 1.3 `-i` flag appends instead of replacing (line 108)

```sh
INTERFACE="$INTERFACE ${OPTARG}"
```
This appends the user value to the default, producing e.g. `"em0 vtnet0"`.

**Fix:** `INTERFACE="${OPTARG}"`

### 1.4 `INTERFACE` variable is never used in GRUB config

The GRUB config always hardcodes `"ext1"` as the MfsBSD interface alias. The `-i` option has zero effect on the output. The `INTERFACE` variable should either be used in the GRUB config or the `-i` option should be removed/repurposed.

### 1.5 `grep '/ '` not silent in `check_free_space_boot` (line 60)

```sh
if grep '/ ' /proc/mounts; then
```
Missing `-q` — prints matched lines to stdout. Also, `grep -q /boot` on line 54 matches `/boot/efi` and other paths.

**Fix:** Use `grep -q ' /boot '` (with surrounding spaces) and add `-q` to the root mount check.

### 1.6 Hardcoded `(hd0,1)` in GRUB loopback

```
loopback loop (hd0,1)$isofile
```
Assumes the first partition of the first disk. Incorrect for GPT with EFI, LVM, multi-disk, or any non-standard partition layout. Boot will fail silently.

**Fix:** Detect the GRUB device and partition dynamically, or document the assumption prominently and provide a `-d` option to override.

### 1.7 IPv4 config overwritten by IPv6 (upstream v1.25 only)

When both IPv4 and IPv6 are configured, the script writes `set kFreeBSD.mfsbsd.ifconfig_ext1` twice:
```
set kFreeBSD.mfsbsd.ifconfig_ext1="inet $ip/${ip_mask_short}"
...
set kFreeBSD.mfsbsd.ifconfig_ext1="inet6 $ipv6"
```
The second `set` overwrites the first in GRUB environment. IPv4 configuration is lost.

**Fix:** Combine both or use separate interface aliases for IPv4 and IPv6.

---

## 2. Security Issues

### 2.1 MD5 for integrity verification

MD5 is cryptographically broken. An attacker performing a MITM on the ISO download could provide a file with a matching MD5. SHA-256 should be used.

### 2.2 Password visible in process list

The `-p` option passes the password as a command-line argument, visible to all users via `ps aux`. The Ansible role also passes it in the shell command line (`tasks/1-install_mfsbsd_iso.yml`).

**Fix:** Read password from a file or stdin.

### 2.3 Password in plaintext in GRUB config

`kFreeBSD.mfsbsd.rootpw` is written in clear text to `/etc/grub.d/40_custom`. Anyone with read access to the file can see the password.

### 2.4 `yum update -y` is destructive (line 138)

```sh
apt-get update || yum update -y
```
On RHEL/CentOS, `apt-get update` fails, then `yum update -y` runs — this **upgrades all installed packages**, not just refreshing the package index. This is potentially destructive and time-consuming.

**Fix:** `apt-get update || yum makecache`

### 2.5 No atomic writes to GRUB config

The script appends to `40_custom` in multiple separate `cat << EOF >>` operations. If the script is interrupted mid-way (power loss, Ctrl+C, `set -e` trigger), a partial/broken GRUB config remains, potentially making the system unbootable.

**Fix:** Write to a temporary file first, then atomically move it:
```sh
GRUB_TEMP=$(mktemp)
# ... write to $GRUB_TEMP ...
mv "$GRUB_TEMP" "${GRUB_CONFIG}"
```

---

## 3. Logic Errors

### 3.1 Private IP range filter is incomplete (lines 34–35)

```sh
egrep -v "^(10|127\.0|192\.168|172\.16)\."
```
RFC 1918 defines `172.16.0.0/12` (172.16.0.0–172.31.255.255). This regex only filters `172.16.x.x`. Addresses `172.17.x.x` through `172.31.x.x` pass through and are incorrectly treated as public IPs.

**Fix:**
```sh
grep -Ev "^(10\.|127\.0\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)"
```

### 3.2 `ping` for connectivity check (line 145)

ICMP is often blocked by firewalls. A failed ping doesn't mean HTTP download would fail.

**Fix:** Use `wget --spider "$MFSBSDISO"` or `curl -sI "$MFSBSDISO"`.

### 3.3 Naive `wget` retry (line 146)

```sh
wget "$MFSBSDISO" || wget "$MFSBSDISO"
```

**Fix:** `wget --tries=3 --timeout=30 "$MFSBSDISO"`

### 3.4 No idempotency

Running the script twice appends duplicate menuentry blocks and conflicting `set default`/`set timeout` directives.

**Fix:** Check if entry already exists, or clean up old entries before appending.

### 3.5 `ip_mask_short=22` override for `/32` (line 44)

```sh
[ "${ip_mask_short}" = "32" ] && ip_mask_short=22
```
Many hosting providers (OVH, Hetzner) use /32 with point-to-point routing. Silently changing to /22 will produce incorrect network configuration.

**Fix:** At minimum, warn the user. Better: detect the actual routing setup.

---

## 4. Code Quality

### 4.1 `egrep` is deprecated

`egrep` is deprecated in favor of `grep -E` (POSIX compliant).

### 4.2 Unused variables

- `ip_mask` — set with default but never read
- `iface_mac` — set but never read
- `INTERFACE` — set and modified by `-i` but never used in output

### 4.3 `update-grub` is Debian/Ubuntu-specific

The script supports `yum` as a fallback for RHEL/CentOS, but `update-grub` does not exist there. The equivalent is `grub2-mkconfig -o /boot/grub2/grub.cfg`.

### 4.4 1-second GRUB timeout

`set timeout=1` gives almost no time to intervene if the configuration is wrong. Combined with the new entry being set as default, a misconfigured GRUB will immediately boot into a broken MfsBSD with no recovery window.

### 4.5 Unquoted variables

Multiple places lack proper quoting:
- `mkdir -p $DIR_ISO` → `mkdir -p "$DIR_ISO"`
- `cd $DIR_ISO` → `cd "$DIR_ISO"`
- `grep -q ${ISO_HASH}` → `grep -q "${ISO_HASH}"`

### 4.6 Hardcoded DNS servers

Google (8.8.8.8) and Cloudflare (1.1.1.1) are hardcoded. Should read from `/etc/resolv.conf` or provide a `-n` option.

### 4.7 Script modifies `40_custom` directly

Would be safer to write to a dedicated file (e.g., `/etc/grub.d/41_mfsbsd`) to avoid conflicts with existing custom entries and enable easy cleanup.

---

## 5. Local Repo vs Upstream Differences

| Aspect | Local (v1.21) | Upstream (v1.25) |
|---|---|---|
| Default ISO | 12.2-RELEASE | 14.0-RELEASE |
| script_type | `ansible` | `self-contained` |
| Copyright | 2018–2022 | 2018–2025 |
| NEED_FREE_SPACE | 90 | 99 |
| Known ISO hashes | 12.2, 13.0, 13.1 | 12.2, 13.0, 13.1, 13.2, 14.0 |
| IPv6 default | missing (`$ipv6` can be empty) | `ipv6=${ipv6:-"::1"}` |
| IPv6 GRUB config | commented out | active (but buggy — see 1.7) |
| IPv6 nameservers | absent | present |
| Usage help | less complete | all options documented |

The local copy is significantly outdated. It's missing IPv6 support and newer FreeBSD release hashes.

---

## 6. Ansible Role Issues (`tasks/1-install_mfsbsd_iso.yml`)

```yaml
- name: Run the script {{ mil_script_name }}
  ansible.builtin.shell:
    cmd: "bash {{ mil_script_name }} {{ mil_script_options }} > /dev/null"
  ignore_errors: true
```

- `ignore_errors: true` silently swallows all failures — the playbook continues even if ISO download, checksum, or GRUB config fails.
- Output redirected to `/dev/null` — no diagnostics available.
- No `chdir` specified — the script path depends on the upload task.
- Password passed via command-line argument (visible in `ps`).

---

## 7. Priority Fixes

1. **P0:** Fail when `ISO_HASH` is empty (silent checksum bypass)
2. **P0:** Fix `set -eo` → `set -e`
3. **P0:** Fix non-atomic GRUB config writes (risk of unbootable system)
4. **P1:** Fix RFC 1918 range for `172.16.0.0/12`
5. **P1:** Fix IPv4/IPv6 `ifconfig_ext1` overwrite
6. **P1:** Remove `ignore_errors: true` from Ansible task
7. **P1:** Fix `INTERFACE` handling (append bug + unused variable)
8. **P2:** Replace MD5 with SHA-256
9. **P2:** Fix `yum update -y` → `yum makecache`
10. **P2:** Handle `update-grub` vs `grub2-mkconfig`
11. **P2:** Add idempotency (prevent duplicate GRUB entries)
12. **P3:** Replace `egrep` with `grep -E`
13. **P3:** Remove unused variables
14. **P3:** Quote all variable expansions
