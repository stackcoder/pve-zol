PVE-ZOL
=======
Install Proxmox PVE with cryptsetup on ZFS.

1. Download and boot [debian live install image](https://www.debian.org/CD/live/)
2. Change variables in the installer script `install-pve-zol.sh`
3. Copy installer script to the live system
4. Execute installer script
5. Reboot system twice

## Reset system during development
```bash
#!/bin/bash
set -x
umount /targer/run
umount /target/boot/efi/
umount -lf /target/dev
umount -lf /target/proc
umount -lf /target/sys
zfs umount -a
zpool destroy bpool
zpool destroy rpool
zpool export -a
cryptsetup luksClose /dev/mapper/rpool0_crypt
cryptsetup luksClose /dev/mapper/rpool1_crypt
```

## Inspired by 
- https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Buster%20Root%20on%20ZFS.html
- https://github.com/hn/debian-buster-zfs-root/blob/master/debian-buster-zfs-root.sh
- https://github.com/HankB/Linux_ZFS_Root/blob/master/Debian/install_Debian_to_ZFS_root.sh
