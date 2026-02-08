# A set of scripts for installing FreeBSD
Here is a set of scripts intended for a guaranteed installation of the FreeBSD OS.

### Set composition
***
- `gozfs_512b.sh` - script to install FreeBSD on disks with block size 512 bytes.
- `gozfs.sh` - script to install FreeBSD on disks with block size 4k or 8k bytes.
- `install_mfsbsd_img_to_sda.sh` - script to write [MfsBSD](https://mfsbsd.vx.sk) .img _to a running_ Linux system on the first HDD (with non-guaranteed results)
- `install_mfsbsd_iso.sh` - script to write [MfsBSD](https://mfsbsd.vx.sk) ISO _on a running_ Linux system
- `mfsbsd_repack.sh` - script for repacking the MfsBSD image with the addition of network settings.
- `archive/` - directory with old source scripts.
- `untested/` - directory with untested scripts.

### Description

For installation, a standard MfsBSD image is used, where there is a `tmux` application and `root/mfsroot` accesses.  
We do not need the FreeBSD archives in the image, we will download them separately from our own or public http server.  
Access to the new system, if no new password was specified in the arguments, after setting the scripts `gozfs.sh`/`gozfs_512b.sh` - `rootmfsroot123`.  
MfsBSD does **NOT** support IPv6.

### Usage strategies
***

##### If DHCP works

1. there is rescue FreeBSD with ZFS ==> install via `gozfs.sh`
2. there is rescue FreeBSD without ZFS ==> write MfsBSD.img directly to /dev/ada0
3. it is possible to load ISO ==> load MfsBSD and install inside it via `gozfs.sh`
4. there is Linux installed ==> then via GRUB, ISO MfsBSD, kFreeBSD
5. there is rescue Linux ==> then in vKVM (statically linked qemu) we load ISO MfsBSD, we forward /dev/sda, through ssh or VNC the client install with ISO system, then we correct a network and we try to reboot a host machine.

##### If DHCP is **NOT** working

6. there is Linux installed ==> then via GRUB, ISO MfsBSD, kFreeBSD
7. there is rescue FreeBSD with ZFS ==> repack MfsBSD.img and then write this image to /dev/ada0
8. it is possible to load ISO ==> modify MfsBSD ISO, boot from our image and install the system from it via `gozfs.sh`

### Script syntax

- `gozfs.sh`/`gozfs_512b.sh`
  
        sh gozfs.sh -p vtbd0 -s4G -n zroot
  or
  
        sh gozfs.sh -p ada0 -p ada1 -s4G -n tank -m mirror -P "my_new_pass"   

    Full syntax:
    ```
    # sh gozfs.sh -p <geom_provider> -s <swap_partition_size> -S <zfs_partition_size> -n <zpoolname> -f <ftphost>
    [ -m <zpool-raidmode> -d <distribution_dir> -D <destination_dir> -M <size_memory_disk> -o <offset_end_disk> -a <ashift_disk> -P <new_password> -t <timezone> -k <url_ssh_key_file> -K <url_ssh_key_dir>
    -z <file_zfs_skeleton> -Z <url_file_zfs_skeleton> ]
    [ -g <gateway> [-i <iface>] -I <IP_address/mask> ]
    ```

- `install_mfsbsd_iso.sh`

        sh install_mfsbsd_iso.sh 
    or
 
        sh install_mfsbsd_iso.sh -m https://mfsbsd.vx.sk/files/iso/14/amd64/mfsbsd-14.0-RELEASE-amd64.iso -a bffaf11a441105b54823981416ae0166 -p 'my_new_pass'
    Full syntax:
    ```
    # sh install_mfsbsd_iso.sh [-hv] [-m url_iso -a md5_iso] [-H your_hostname] [-i network_iface] [-p 'myPassW0rD'] [-s need_free_space]
    ```

- other scripts without arguments


###### Untested
    https://sysadmin.pm/takeover-sh/
    Convert_UFS_to_ZFS.sh

###### Source resources:
- [freebsd_81_zfs_install.sh](https://github.com/clickbg/scripts/blob/c5c90b8475ba32337de9fdb8808113d32f922454/FreeBSD/freebsd_81_zfs_install.sh)  
- [MfsBSD and kFreeBSD](https://forums.freebsd.org/threads/tip-booting-mfsbsd-iso-file-from-grub2-depenguination.46480/)

###### Deprecated:
- `gozfs_512b.sh`
- `mfsbsd_repack.sh`

#### Author:

- Vladislav V. Prodan `<github.com/click0>`

### 🤝 Contributing

Contributions, issues and feature requests are welcome!<br />Feel free to check [issues page](https://github.com/click0/FreeBSD-install-scripts/issues).

### Show your support

Give a ⭐ if this project helped you!

<a href="https://www.buymeacoffee.com/click0" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-orange.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
