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
In both modes GRUB itself starts the FreeBSD kernel from the ISO (`loopback` + `kfreebsd`); the ISO is stored in `/boot/images`.
After the reboot the role waits until sshd of MfsBSD answers (see `mil_reboot_wait`).

The bundled script is **v1.31**. It was run in QEMU on Debian 12 (GRUB 2.06) and Ubuntu 24.04 (GRUB 2.12), each under BIOS and UEFI, with MfsBSD 14.0 and 14.2.

## Things to know

- **GRUB 2.06 on BIOS** (Debian 12, Ubuntu 22.04) has a bug that resets the machine when a 64-bit FreeBSD kernel is started (fixed in GRUB 2.12).
  The script detects it and loads a corrected copy of `relocator.mod` from `/boot/images`; the installed GRUB is not modified.
- **UEFI**: Secure Boot must be off. MfsBSD started this way reports `machdep.bootmethod: BIOS`.
  The script leaves the hint `mfsbsd.bootmethod=UEFI` in the kernel environment; `gozfs.sh` 2.24 and newer
  (role `freebsd_install_on_zfs_lite`) reads it. With an older installer set the boot mode to `uefi` explicitly.
- **Network**: the IPv4 address, mask, gateway and the DHCP/static mode are taken from the running Linux
  (`mil_network_mode` overrides the mode). MfsBSD does not apply IPv6 settings passed this way: it comes up with IPv4 only.
- **ISO checksum**: MD5 sums of MfsBSD 12.2 - 14.0 are built in; for any other ISO set `mil_mfsbsd_iso_hash`.
- **Password**: avoid spaces and `* ? [` in `mil_mfsbsd_password` - MfsBSD passes it through an unquoted `echo`.

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
