# mfsbsd_install_via_linux_lite

[Ansible role.](https://galaxy.ansible.com/click0/mfsbsd_install_via_linux_lite/) MfsBSD. Installing and booting MfsBSD from running Linux, via grub.  
Feel free to [share your feedback and report issues](https://github.com/click0/ansible-mfsbsd_install_via_linux_lite/issues).  
[Contributions are welcome](https://github.com/firstcontributions/first-contributions).  

## Synopsis

This role acts as a runner for a single [`install_mfsbsd_iso.sh` script](https://github.com/click0/FreeBSD-install-scripts/blob/master/install_mfsbsd_iso.sh).  
(That's why there is `lite` in the role name too)  
This script to fetch [MfsBSD](https://mfsbsd.vx.sk) ISO to boot partition of Linux.  
It also modifies the grub settings so that the machine can start MfsBSD on its own after a reboot.  
The script itself determines the network settings of the machine and transfers them during the subsequent reboot.

## Variables

See the defaults and examples in vars.

## Workflow

1) Install the role

```
shell> ansible-galaxy role install click0.mfsbsd_install_via_linux_lite
```

2) Look variables, e.g. in defaults/main.yml

You can override them in the playbook and inventory.  

4) Create playbook and inventory

```
shell> cat install_mfsbsd_via_linux.yml

- hosts: linux_server
  gather_facts: false
  vars:
#  mil_mfsbsd_version: '12.2' # or 12
#  mil_hostname: 'YOURHOSTNAME'
#  mil_iface_list: 'vtnet0 fxp0 em0'
  
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

## Further use

You may need [another role](https://galaxy.ansible.com/click0/freebsd_install_on_zfs_lite/) to install FreeBSD on the root with ZFS.

### Author:

- Vladislav V. Prodan `<github.com/click0>`

### 🤝 Contributing

Contributions, issues and feature requests are welcome!<br />Feel free to check [issues page](https://github.com/click0/domain-check-2/issues).

### Show your support

Give a ⭐ if this project helped you!

<a href="https://www.buymeacoffee.com/click0" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-orange.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
