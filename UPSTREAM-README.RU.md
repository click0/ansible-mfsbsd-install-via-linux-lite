# Набор скриптов для установки FreeBSD
Тут находится набор скриптов, предназначенные для гарантированной установки ОС FreeBSD.

### Состав
***
- `gozfs_512b.sh` - скрипт для установки FreeBSD на диски с размером блока 512.
- `gozfs.sh` - скрипт для установки FreeBSD на диски с размером блока 4k или 8k.
- `install_mfsbsd_img_to_sda.sh` - скрипт для записи [MfsBSD](https://mfsbsd.vx.sk/) .img _на работающую_ систему Linux на первый HDD (с негарантированным результатом)
- `install_mfsbsd_iso.sh` - скрипт для записи [MfsBSD](https://mfsbsd.vx.sk/) ISO _на работающую_ систему Linux
- `mfsbsd_repack.sh` - скрипт для перепаковки образа MfsBSD с добавлением сетевых настроек.
- `archive/` - директория со старыми исходными скриптами.
- `untested/` - директория с нетестированными скриптами.

### Описание

Для установки используется стандартный образ MfsBSD, где есть приложение `tmux` и доступы `root/mfsroot`.  
Сами архивы FreeBSD нам в образе не нужны, мы их отдельно скачаем со своего или публичного http сервера.  
Доступы к новой системе, если в аргументах не задали новый пароль, после установки скриптами `gozfs.sh`/`gozfs_512b.sh` - `root/mfsroot123`.  
MfsBSD **НЕ** поддерживает IPv6.

### Стратегии использования
***

##### Если работает DHCP

1. есть rescue FreeBSD с ZFS ==> ставим через `gozfs.sh`
2. есть rescue FreeBSD без ZFS ==> пишем MfsBSD.img сразу на /dev/ada0
3. есть возможность грузить ISO ==> грузим MfsBSD и внутри него ставим через `gozfs.sh`
4. есть установленная Linux ==> то через GRUB, ISO MfsBSD, kFreeBSD
5. есть rescue Linux ==> тогда в vKVM (статически слинкованный qemu) грузим ISO MfsBSD, пробрасываем /dev/sda, через ssh или VNC клиент устанавливаем с ISO систему, потом правим сеть и пробуем перегрузить хост машину.

##### Если **НЕ** работает DHCP

6. есть установленная Linux ==> то через GRUB, ISO MfsBSD, kFreeBSD
7. есть rescue FreeBSD с ZFS ==> перепаковываем MfsBSD.img и потом пишем этот образ на /dev/ada0
8. есть возможность грузить ISO ==> модифицируем MfsBSD ISO, грузимся с нашего образа и с него ставим систему через `gozfs.sh`

### Синтаксис скриптов

- `gozfs.sh`/`gozfs_512b.sh`
  
        sh gozfs.sh -p vtbd0 -s4G -n zroot  
    или  
  
        sh gozfs.sh -p ada0 -p ada1 -s4G -n tank -m mirror -P "my_new_pass"   

    Полный синтаксис:
    ```
    # sh gozfs.sh -p <geom_provider> -s <swap_partition_size> -S <zfs_partition_size> -n <zpoolname> -f <ftphost>
    [ -m <zpool-raidmode> -d <distdir> -M <size_memory_disk> -o <offset_end_disk> -a <ashift_disk> -P <new_password>]
    [ -g <gateway> [-i <iface>] -I <IP_address/mask> ]
    ```

- `install_mfsbsd_iso.sh`

        sh install_mfsbsd_iso.sh
    или
 
        sh install_mfsbsd_iso.sh -m https://mfsbsd.vx.sk/files/iso/14/amd64/mfsbsd-14.0-RELEASE-amd64.iso -a bffaf11a441105b54823981416ae0166 -p 'my_new_pass'
    Полный синтаксис:
    ```
    # sh install_mfsbsd_iso.sh [-hv] [-m url_iso -a md5_iso] [-H your_hostname] [-i network_iface] [-p 'myPassW0rD'] [-s need_free_space]
    ```

- остальные скрипты без аргументов


###### Untested
    https://sysadmin.pm/takeover-sh/
    Convert_UFS_to_ZFS.sh

###### Исходные ресурсы:
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
