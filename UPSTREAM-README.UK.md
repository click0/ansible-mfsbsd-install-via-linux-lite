# Набір скриптів для встановлення FreeBSD
Тут знаходиться набір скриптів, призначених для гарантованого встановлення ОС FreeBSD.

### Склад
***
- `gozfs_512b.sh` - скрипт для встановлення FreeBSD на диски з розміром блоку 512.
- `gozfs.sh` - скрипт для встановлення FreeBSD на диски з розміром блоку 4k або 8k.
- `install_mfsbsd_img_to_sda.sh` - скрипт для запису [MfsBSD](https://mfsbsd.vx.sk/) .img _на працюючу_ систему Linux на перший HDD (з негарантованим результатом)
- `install_mfsbsd_iso.sh` - скрипт для запису [MfsBSD](https://mfsbsd.vx.sk/) ISO _на працюючу_ систему Linux
- `mfsbsd_repack.sh` - скрипт для перепакування образу MfsBSD з додаванням мережевих налаштувань.
- `archive/` - директорія зі старими вихідними скриптами.
- `untested/` - директорія з нетестованими скриптами.

### Опис

Для встановлення використовується стандартний образ MfsBSD, де є застосунок `tmux` та доступи `root/mfsroot`.
Самі архіви FreeBSD нам в образі не потрібні, ми їх окремо завантажимо зі свого або публічного http сервера.
Доступи до нової системи, якщо в аргументах не задали новий пароль, після встановлення скриптами `gozfs.sh`/`gozfs_512b.sh` - `root/mfsroot123`.
MfsBSD **НЕ** підтримує IPv6.

### Стратегії використання
***

##### Якщо працює DHCP

1. є rescue FreeBSD з ZFS ==> ставимо через `gozfs.sh`
2. є rescue FreeBSD без ZFS ==> пишемо MfsBSD.img одразу на /dev/ada0
3. є можливість завантажити ISO ==> завантажуємо MfsBSD і всередині нього ставимо через `gozfs.sh`
4. є встановлена Linux ==> то через GRUB, ISO MfsBSD, kFreeBSD
5. є rescue Linux ==> тоді у vKVM (статично злінкований qemu) завантажуємо ISO MfsBSD, прокидаємо /dev/sda, через ssh або VNC клієнт встановлюємо з ISO систему, потім правимо мережу і пробуємо перезавантажити хост машину.

##### Якщо **НЕ** працює DHCP

6. є встановлена Linux ==> то через GRUB, ISO MfsBSD, kFreeBSD
7. є rescue FreeBSD з ZFS ==> перепаковуємо MfsBSD.img і потім пишемо цей образ на /dev/ada0
8. є можливість завантажити ISO ==> модифікуємо MfsBSD ISO, завантажуємось з нашого образу і з нього ставимо систему через `gozfs.sh`

### Синтаксис скриптів

- `gozfs.sh`/`gozfs_512b.sh`

        sh gozfs.sh -p vtbd0 -s4G -n zroot
    або

        sh gozfs.sh -p ada0 -p ada1 -s4G -n tank -m mirror -P "my_new_pass"

    Повний синтаксис:
    ```
    # sh gozfs.sh -p <geom_provider> -s <swap_partition_size> -S <zfs_partition_size> -n <zpoolname> -f <ftphost>
    [ -m <zpool-raidmode> -d <distdir> -M <size_memory_disk> -o <offset_end_disk> -a <ashift_disk> -P <new_password>]
    [ -g <gateway> [-i <iface>] -I <IP_address/mask> ]
    ```

- `install_mfsbsd_iso.sh`

        sh install_mfsbsd_iso.sh
    або

        sh install_mfsbsd_iso.sh -m https://mfsbsd.vx.sk/files/iso/14/amd64/mfsbsd-14.0-RELEASE-amd64.iso -a bffaf11a441105b54823981416ae0166 -p 'my_new_pass'
    Повний синтаксис:
    ```
    # sh install_mfsbsd_iso.sh [-hv] [-m url_iso -a md5_iso] [-H your_hostname] [-i network_iface] [-p 'myPassW0rD'] [-s need_free_space]
    ```

- решта скриптів без аргументів


###### Untested
    https://sysadmin.pm/takeover-sh/
    Convert_UFS_to_ZFS.sh

###### Вихідні ресурси:
- [freebsd_81_zfs_install.sh](https://github.com/clickbg/scripts/blob/c5c90b8475ba32337de9fdb8808113d32f922454/FreeBSD/freebsd_81_zfs_install.sh)
- [MfsBSD and kFreeBSD](https://forums.freebsd.org/threads/tip-booting-mfsbsd-iso-file-from-grub2-depenguination.46480/)

###### Deprecated:
- `gozfs_512b.sh`
- `mfsbsd_repack.sh`

#### Автор:

- Vladislav V. Prodan `<github.com/click0>`

### 🤝 Contributing

Contributions, issues and feature requests are welcome!<br />Feel free to check [issues page](https://github.com/click0/FreeBSD-install-scripts/issues).

### Show your support

Give a ⭐ if this project helped you!

<a href="https://www.buymeacoffee.com/click0" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-orange.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
