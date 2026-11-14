# mfsbsd_install_via_linux_lite

[Ansible Galaxy](https://galaxy.ansible.com/click0/mfsbsd_install_via_linux_lite/)

MfsBSD. Installing and booting MfsBSD from running Linux, via grub.
Feel free to [share your feedback and report issues](https://github.com/click0/ansible-mfsbsd-install-via-linux-lite/issues).  
[Contributions are welcome](https://github.com/firstcontributions/first-contributions).  

## Synopsis

This role acts as a runner for a single [`install_mfsbsd_iso.sh` script](https://github.com/click0/FreeBSD-install-scripts/blob/master/install_mfsbsd_iso.sh).
(That's why there is `lite` in the role name too)
This script to fetch [MfsBSD](https://mfsbsd.vx.sk) ISO to boot partition of Linux.
It also modifies the grub settings so that the machine can start MfsBSD on its own after a reboot.
The script itself determines the network settings of the machine and transfers them during the subsequent reboot.

Both **Legacy BIOS** and **UEFI** boot modes are supported.
The boot mode is auto-detected; use `mil_force_uefi: true` to force UEFI mode.
After the reboot the role waits until sshd of MfsBSD answers (see `mil_reboot_wait`).

The bundled script is **v1.31**. It was run in QEMU on Debian 12, Ubuntu 22.04 / 24.04 and Rocky Linux 9,
under BIOS and UEFI, with MfsBSD 14.0 and 14.2.

## How MfsBSD is started

- **BIOS**: GRUB starts the FreeBSD kernel from the ISO itself (`loopback` + `kfreebsd`); the ISO is stored in `/boot/images`.
- **UEFI**: FreeBSD's own `loader.efi`, the kernel and the memory disk are copied to the EFI System Partition and GRUB chainloads the loader.
  This is a normal FreeBSD UEFI boot (console on the screen, `machdep.bootmethod: UEFI`). It needs about 100 MB on the ESP.
  If the ESP is smaller, GRUB starts the kernel as under BIOS; MfsBSD then reports `machdep.bootmethod: BIOS` and has no console on the screen,
  so the script leaves the hint `mfsbsd.bootmethod=UEFI`, which `gozfs.sh` 2.24+ (role `freebsd_install_on_zfs_lite`) reads.
- **Once**: MfsBSD is started for one boot only. If it does not come up (or is rebooted), the server returns to Linux,
  and the role reports that MfsBSD did not answer. When GRUB cannot write its environment block
  (`/boot` on LVM, software RAID or btrfs), MfsBSD becomes the permanent default entry instead.

## Things to know

- **Secure Boot** must be off: neither way of starting MfsBSD works with it. The script stops before it changes anything.
- **GRUB 2.06 on BIOS** (Debian 12, Ubuntu 22.04, RHEL 9) has a bug that resets the machine when a 64-bit FreeBSD kernel is started (fixed in GRUB 2.12).
  The script detects it and loads a corrected copy of `relocator.mod` from `/boot/images`; the installed GRUB is not modified.
- **Network**: address, mask, gateway and the DHCP/static mode are taken from the running Linux (`mil_network_mode` overrides the mode).
  IPv4 is bound to the card by its MAC address. IPv6 and a gateway outside the subnet (`/32`) need the FreeBSD name of the card:
  it is guessed from the Linux driver and the PCI order (`virtio_net` - `vtnet0`, `e1000e` - `em0`, `igb` - `igb0`, `ixgbe` - `ix0`, ...)
  and shown in the output; set `mil_bsd_iface` if the guess is wrong or the driver is not known.
- **ISO checksum**: MD5 sums of MfsBSD 12.2 - 14.2 are built in; for any other ISO set `mil_mfsbsd_iso_hash`.
- **Password**: `mil_mfsbsd_password` is passed to MfsBSD as a SHA-512 hash, so it can contain any characters and is not stored in the GRUB configuration as plain text.
- **Not tested**: real hardware and a real Secure Boot firmware setup; everything above was checked in QEMU only.

## Variables

See the `defaults/main.yml` and examples in vars.

## Workflow

1) Install the role

```
shell> ansible-galaxy role install click0.mfsbsd_install_via_linux_lite
```

2) Look variables, e.g. in `defaults/main.yml`

You can override them in the playbook and inventory.  

3) Create playbook and inventory

```
shell> cat install_mfsbsd_via_linux.yml

- hosts: linux_server
  gather_facts: false
  vars:
#   mil_mfsbsd_iso_url: '' # 'https://mfsbsd.vx.sk/files/iso/14/amd64/mfsbsd-14.0-RELEASE-amd64.iso'
#   mil_mfsbsd_iso_hash: '' # 'bffaf11a441105b54823981416ae0166'
#   mil_mfsbsd_password: '' # default - 'mfsroot'
#   mil_iface: '' # Linux interface to take the settings from (ens3, eth0); default - the one with the default route
#   mil_bsd_iface: '' # FreeBSD name of that interface (em0, igb0, vtnet0); default - guessed from the Linux driver
#   mil_need_free_space: '' # default '99'	# in megabytes! Suffixes M and G are accepted
#   mil_hostname: 'mfsbsd-' # 'YOURHOSTNAME'
#   mil_force_uefi: false # force UEFI boot mode (auto-detected by default)
#   mil_network_mode: '' # '' - as in Linux (auto-detect) | dhcp | static
#   mil_reboot_wait: true # wait (from the controller) for sshd of MfsBSD after the reboot
#   mil_reboot_timeout: '600' # seconds
#   mil_reboot_wait_host: '' # default - ansible_host
#   mil_reboot_wait_port: '' # default - ansible_port, else 22
  
  roles:
    - click0.mfsbsd_install_via_linux_lite
```

Commented options you may need.

```
shell> cat hosts
[linux_server]
<linux_server-ip-or-fqdn>
[linux_server:vars]
# ansible_python_interpreter=/usr/bin/python3
# ansible_ssh_common_args='-o ProxyCommand="ssh -W %h:%p -q my-bastion-host"'
# or
# ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
```

## Dependencies

None.

## Further use

You may need [another role](https://galaxy.ansible.com/click0/freebsd_install_on_zfs_lite/) to install FreeBSD on the root with ZFS.

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
