# mfsbsd_install_via_linux_lite

[Ansible Galaxy](https://galaxy.ansible.com/click0/mfsbsd_install_via_linux_lite/)

Boots [MfsBSD](https://mfsbsd.vx.sk) (FreeBSD that runs entirely from memory) on a server that is currently running Linux,
without a rescue system, a KVM console or a remote hands request.

Feel free to [share your feedback and report issues](https://github.com/click0/ansible-mfsbsd-install-via-linux-lite/issues).  
[Contributions are welcome](https://github.com/firstcontributions/first-contributions).  

## What it is for

A hosting provider gives you a server with Linux only, and you want FreeBSD on it.
This role is the first half of that way: it makes the running Linux start MfsBSD at the next boot.
MfsBSD keeps nothing on the disks, so after that the disks are free and FreeBSD can be installed on them,
for example with the role [`freebsd_install_on_zfs_lite`](https://galaxy.ansible.com/click0/freebsd_install_on_zfs_lite/).

The role is a thin runner (hence `lite`) for one shell script,
[`install_mfsbsd_iso.sh`](https://github.com/click0/FreeBSD-install-scripts/blob/master/install_mfsbsd_iso.sh), bundled as **v1.31**.
All the work on the host is done by that script; the role prepares the host, runs it, reboots and checks the result.

## What the role does

1. **Checks the variables** (`mil_network_mode`).
2. **Prepares the host**: installs `python3` if the host has none (so a minimal image is fine), then `ca-certificates` and `wget`.
3. **Uploads the script** to `/root/` and runs it. The script:
   - detects the boot mode (BIOS or UEFI) and stops if Secure Boot is on;
   - checks the free space on `/boot`;
   - downloads the MfsBSD ISO to `/boot/images` and verifies its MD5 sum;
   - reads the network settings of the running Linux (see [Network](#network));
   - adds a GRUB menu entry that starts MfsBSD with those settings and regenerates the GRUB configuration;
   - arms that entry for the next boot.
4. **Shows a summary**: boot mode, the interface and the addresses that MfsBSD will get, how it will be started.
5. **Reboots** the host.
6. **Waits for MfsBSD** from the control node: the ssh port must answer with a banner that contains `FreeBSD`.
   A server that came back into Linux does not pass this check, so the play fails instead of reporting a false success.

When the play is green, the host runs MfsBSD and answers on ssh at the same address as before.

## Requirements

**Control node**
- Ansible 2.16 or newer.
- Direct access to the ssh port of the host for the final check (or see `mil_reboot_wait*` for a bastion).

**Host**
- Linux on amd64 with GRUB 2: Debian, Ubuntu, RHEL-like (Rocky, Alma).
- Login as root (or `become`).
- Internet access: packages of the distribution and the MfsBSD ISO.
- About 100 MB free on `/boot` (on `/` if `/boot` is not a separate partition).
- Secure Boot is **off**.
- Enough memory for MfsBSD: the whole system lives in RAM.

A console of the server (IPMI, KVM, provider's VNC) is not needed, but it is the only way to see what happened
if MfsBSD does not come up with a working network.

## How MfsBSD is started

| Boot mode | Method | Notes |
| --- | --- | --- |
| BIOS | GRUB opens the ISO in `/boot/images` and starts the FreeBSD kernel itself. | Nothing is unpacked. |
| UEFI, ESP has about 100 MB free | FreeBSD's own `loader.efi`, the kernel and the memory disk are copied to the EFI System Partition, GRUB hands control to the loader. | A normal FreeBSD UEFI boot: console on the screen, `machdep.bootmethod: UEFI`. |
| UEFI, small ESP | The same as under BIOS. | MfsBSD reports `machdep.bootmethod: BIOS` and has no console on the screen (ssh works). The script leaves the hint `mfsbsd.bootmethod=UEFI` in the kernel environment; `gozfs.sh` 2.24+ reads it and still installs a UEFI system. |

**One boot only.** The MfsBSD entry is used for a single boot. The next reboot returns to Linux:
- if GRUB cannot even load MfsBSD, it falls back to Linux by itself;
- if MfsBSD starts but you cannot reach it, a power cycle from the provider's panel brings Linux back;
- if you reboot MfsBSD without installing anything, you are in Linux again and can run the role once more.

The exception: when the GRUB directory is on LVM, software RAID or a filesystem other than ext2/3/4, XFS or FAT (btrfs, ZFS),
GRUB cannot write its environment block.
MfsBSD then becomes the permanent default entry, and the script says so in its output.

## Network

MfsBSD must come up with the same address as Linux had, otherwise the server is lost.
The script takes the settings from the running system, not from the configuration files:

| Setting | Where it comes from |
| --- | --- |
| Interface | The one with the default route. `mil_iface` selects another one. |
| IPv4 address and mask | The first global address of that interface. |
| IPv4 mode | DHCP if Linux got the address from DHCP, otherwise static. `mil_network_mode` forces `dhcp` or `static`. |
| IPv4 gateway | The default route. A gateway outside the subnet (`/32` setups of some providers) gets a host route through the interface. |
| IPv6 address and prefix | The first global address of that interface; SLAAC or static, as in Linux. |
| IPv6 gateway | The default IPv6 route. |
| DNS servers | **Not** taken from Linux: `8.8.8.8`, `1.1.1.1` and their IPv6 counterparts. |
| Hostname | `mil_hostname`. |
| root password | `mil_mfsbsd_password`, default `mfsroot`. |

Things that are **not** carried over: other interfaces, additional addresses, VLANs, bonds, bridges, extra routes, firewall rules, ssh keys.

**Interface name.** Linux and FreeBSD name network cards differently (`ens3` and `vtnet0`).
IPv4 is bound to the card by its MAC address and does not depend on the name.
IPv6 and the route to an off-subnet gateway need the FreeBSD name. The script guesses it from the Linux driver and
the PCI order of the cards (`virtio_net` - `vtnet0`, `e1000e` - `em0`, `igb` - `igb0`, `ixgbe` - `ix0`, ...) and prints the result.
If the guess is wrong or the driver is unknown, set `mil_bsd_iface`.

## What is changed on the Linux host

The disks are not repartitioned and no existing file of the system is replaced. The role adds:

| Where | What |
| --- | --- |
| Packages | `python3` (and `python3-apt` on Debian-like systems), `ca-certificates`, `wget`. |
| `/root/install_mfsbsd_iso.sh` | The script. |
| `/boot/images/` | The MfsBSD ISO. With GRUB 2.06 under BIOS also a corrected copy of `relocator.mod` (see below). |
| `/etc/grub.d/40_custom` | A block between `# --- BEGIN MFSBSD ---` and `# --- END MFSBSD ---`. A second run replaces it. |
| GRUB configuration | Regenerated with `update-grub` or `grub2-mkconfig`. |
| GRUB environment block | The flag `mfsbsd_once=1`; GRUB clears it when it starts MfsBSD. |
| EFI System Partition (UEFI) | `/boot`, `/mfsroot.gz` and `/EFI/mfsbsd/loader.efi`. A second run replaces them. |

Linux stays bootable. To undo everything by hand: remove the block from `40_custom`, regenerate the GRUB configuration,
delete `/boot/images` and, under UEFI, the three items on the ESP.

## After the role

- The host runs MfsBSD from memory. Linux is still on the disks, untouched, until something overwrites them.
- Login: `root` with the password from `mil_mfsbsd_password` (default `mfsroot`). The ISO has no ssh keys of yours.
- The ssh host key is different: remove the old one from `known_hosts` or relax the host key checking for this host.
- MfsBSD has no Python. The next role or playbook must start with the `raw` module
  (`freebsd_install_on_zfs_lite` installs Python itself).
- Everything done inside MfsBSD is lost at reboot.

## If something goes wrong

| Symptom | Meaning | What to do |
| --- | --- | --- |
| The script stops with `Secure Boot is enabled` | Neither start method works with Secure Boot. Nothing was changed. | Turn Secure Boot off in the firmware setup, run again. |
| `No checksum defined for ...` | The ISO is not one of the known images. | Set `mil_mfsbsd_iso_hash`. |
| `md5 mismatch` | The download is damaged or the hash is wrong. The file stays in `/boot/images` and is not downloaded again. | Remove it, check `mil_mfsbsd_iso_hash`, run again. |
| `No space in partition /boot!` | Less free space than `mil_need_free_space`. | Free the space (old kernels). |
| `The gateway ... is outside ...` and the name could not be guessed | An off-subnet gateway needs the FreeBSD interface name. Nothing was changed. | Set `mil_bsd_iface`. |
| The wait fails, the host answers as Linux | MfsBSD did not start and GRUB fell back. | Look at the console; check the summary printed by the role. |
| The wait fails, the host does not answer | MfsBSD started with wrong network settings, or is still booting. | Power cycle the server: it returns to Linux. Check `mil_iface`, `mil_bsd_iface`, `mil_network_mode`. |

The role can be run again at any time: the previous GRUB entry and the files on the ESP are replaced, the ISO is reused.

## Things to know

- **GRUB 2.06 under BIOS** (Debian 12, Ubuntu 22.04, RHEL 9) has a bug that resets the machine when it starts a 64-bit FreeBSD kernel
  (fixed in GRUB 2.12). The script detects it and makes GRUB load a corrected copy of one module from `/boot/images`.
  The installed GRUB is not modified.
- **Password.** It is passed to MfsBSD as a SHA-512 hash, so it may contain any characters and
  is not stored in the GRUB configuration as plain text.
- **Built-in checksums** exist for the MfsBSD images 12.2 - 14.2 from `mfsbsd.vx.sk`. Any other ISO needs `mil_mfsbsd_iso_hash`.
- **Tested** in QEMU only: Debian 12, Ubuntu 22.04 and 24.04, Rocky Linux 9; BIOS and UEFI; MfsBSD 14.0 and 14.2;
  the ISO on an LVM volume and on software RAID 1. Not tested: real hardware, a real Secure Boot firmware,
  and the permanent-default case described above.

## Variables

All variables are optional; the defaults are in `defaults/main.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `mil_mfsbsd_iso_url` | MfsBSD 14.0 from `mfsbsd.vx.sk` | URL of the ISO. |
| `mil_mfsbsd_iso_hash` | built-in | MD5 sum of the ISO. Required for images the script does not know. |
| `mil_mfsbsd_password` | `mfsroot` | root password in MfsBSD. |
| `mil_hostname` | `mfsbsd-` | Hostname of MfsBSD. |
| `mil_iface` | interface with the default route | Linux name of the interface to take the settings from (`ens3`, `eth0`). |
| `mil_bsd_iface` | guessed | FreeBSD name of the same interface (`em0`, `igb0`, `vtnet0`). |
| `mil_network_mode` | as in Linux | `dhcp` or `static` to override the detected mode, for IPv4 and IPv6 at once. |
| `mil_force_uefi` | `false` | Treat the host as UEFI even if it was not detected. |
| `mil_need_free_space` | `99` | Free space required on `/boot`, in megabytes; suffixes `M` and `G` are accepted. |
| `mil_reboot_wait` | `true` | Wait for the ssh banner of MfsBSD after the reboot. Turn off when the control node has no direct access to the host. |
| `mil_reboot_timeout` | `600` | How long to wait, in seconds. |
| `mil_reboot_wait_host` | `ansible_host` | Address to wait for. |
| `mil_reboot_wait_port` | `ansible_port`, else `22` | Port to wait for. |

## Usage

Install the role:

```
ansible-galaxy role install click0.mfsbsd_install_via_linux_lite
```

A playbook. Facts are not needed, and gathering them fails on a host without Python:

```yaml
- hosts: linux_server
  gather_facts: false
  vars:
    mil_mfsbsd_iso_url: 'https://mfsbsd.vx.sk/files/iso/14/amd64/mfsbsd-14.2-RELEASE-amd64.iso'
    mil_mfsbsd_password: '{{ vault_mfsbsd_password }}'
    mil_hostname: 'rescue'
  roles:
    - click0.mfsbsd_install_via_linux_lite
```

An inventory:

```ini
[linux_server]
<linux_server-ip-or-fqdn>

[linux_server:vars]
ansible_user=root
# ansible_ssh_common_args='-o ProxyCommand="ssh -W %h:%p -q my-bastion-host"'
```

## Together with freebsd_install_on_zfs_lite

The two roles make the whole way from Linux to FreeBSD on ZFS, but they talk to two different systems at the same address,
so they need two inventory entries and two plays (or two runs):

| | This role | `freebsd_install_on_zfs_lite` |
| --- | --- | --- |
| System on the host | Linux | MfsBSD |
| Login | your key or password | `root` and the MfsBSD password (needs `sshpass` on the control node) |
| Host key | the known one | a new one |
| Shell, Python | `sh`, `/usr/bin/python3` | `csh`, `/usr/local/bin/python3` (installed by that role) |

The second role detects the boot mode by itself, including the case when MfsBSD was started by GRUB on a UEFI machine.

## Dependencies

None.

### License

BSD 3-Clause

### Author:

- Vladislav V. Prodan `<github.com/click0>`

### 🤝 Contributing

Contributions, issues and feature requests are welcome!<br>
Feel free to check [issues page](https://github.com/click0/ansible-mfsbsd-install-via-linux-lite/issues).

### Show your support

Give a ⭐ if this project helped you!

<a href="https://www.buymeacoffee.com/click0" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-orange.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
