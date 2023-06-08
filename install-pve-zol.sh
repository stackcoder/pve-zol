#!/bin/bash
set -euo pipefail

# Require root permissions
if [[ $EUID != 0 ]]; then sudo "$0" "$@"; exit $?; fi

# PVE-ZOL Installer
# copied from: https://github.com/stackcoder/pve-zol

DISK_IDS=(
  "wwn-0x0000000000000001"
  "wwn-0x0000000000000002"
)

ZPOOL_TYPE="mirror"

BOOT_TYPE="EFI"

CRYPTSETUP_PASSPHRASE="password"
CRYPTSETUP_DEFAULTS=(
  --cipher "aes-xts-plain64"
  --key-size "512"
  --hash "sha256"
)

SWAP_SIZE="${SWAP_SIZE:-16G}"
ROOT_PASSWORD="root"

TARGET_HOSTNAME="${TARGET_HOSTNAME:-pve-zol}"
TARGET_IPADDRESS="${TARGET_IPADDRESS:-192.168.1.42/24}"
TARGET_GATEWAY="${TARGET_GATEWAY:-192.168.1.1}"
TARGET_DNS="${TARGET_DNS:-${TARGET_GATEWAY}}"

CMDLINE_LINUX=""

[[ -z "${ETHERNET_DEV:-}" ]] && ETHERNET_DEV="$(udevadm info -e | sed -n '/ID_NET_NAME_ONBOARD=/p' | head -n1 | cut -d= -f2)"
[[ -z "${ETHERNET_DEV:-}" ]] && ETHERNET_DEV="$(udevadm info -e | sed -n '/ID_NET_NAME_PATH=/p' | head -n1 | cut -d= -f2)"
[[ -z "${ETHERNET_DEV:-}" ]] && ETHERNET_DEV="enp0s1"

SSH_USER="user"
SSH_KEY=""

[[ "${#DISK_IDS[@]}" -lt 2 ]] && ZPOOL_TYPE=""

export LC_ALL="en_US.UTF-8"

echo_section() {
  echo -e "\n\n\e[0;94m===== ${*} =====\e[0m"
}

echo_section "Configure live system"
( set -x
  gsettings set org.gnome.desktop.media-handling automount false || true
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
)

echo_section "Install ZOL and dependencies"
if ! modinfo zfs &> /dev/null; then
( set -x
  echo "deb http://deb.debian.org/debian bullseye contrib" \
    > /etc/apt/sources.list.d/bullseye-contrib.list
  apt-get update
  apt-get install --yes cryptsetup curl debootstrap efibootmgr gdisk dpkg-dev parted rng-tools "linux-headers-$(uname -r)"
  apt-get install --yes zfsutils-linux
  modprobe zfs
)
else
  echo "Already satisfied"
fi

echo_section "Partition disks"
for id in "${DISK_IDS[@]}"; do
( set -x
  # Clear disk
  wipefs -af "/dev/disk/by-id/${id}"
  sgdisk --zap-all "/dev/disk/by-id/${id}"
  sync && partprobe "/dev/disk/by-id/${id}" && sleep 1

  # Discard device sectors
  blkdiscard -sv "/dev/disk/by-id/${id}" || blkdiscard -fv "/dev/disk/by-id/${id}" || true

  # Always use 4k alignment
  part_end=$(blockdev --getsize "/dev/disk/by-id/${id}")
  part_end=$(( part_end - (part_end + 1) % 4096 ))

  if [[ "${BOOT_TYPE}" == "BIOS" ]]; then
    # Run this if you need legacy (BIOS) booting:
    sgdisk -a 1    -n1:24K:+1000K -t1:EF02 -c1:"BIOS" "/dev/disk/by-id/${id}"
  else
    sgdisk -a 4096 -n2:1M:+512M   -t2:EF00 -c2:"EFI System" "/dev/disk/by-id/${id}"
  fi
  
  sgdisk -n3:0:+1G         -t3:BF01 -c3:"System Boot Pool" "/dev/disk/by-id/${id}"
  sgdisk -n4:0:${part_end} -t4:8300 -c4:"System Root Pool" "/dev/disk/by-id/${id}"

  # Let the kernel reread the partition table
  sync && partprobe "/dev/disk/by-id/${id}"
  while [[ ! -b "/dev/disk/by-id/${id}-part4" ]] || (sleep 3; false); do sleep 0.5; done
)
done

if [[ "${BOOT_TYPE}" != "BIOS" ]]; then
  echo_section "Format primary efi partition with fat32"
  ( set -x
    mkdosfs -F 32 -s 1 -n EFI "/dev/disk/by-id/${DISK_IDS[0]}-part2"
  )
fi

echo_section "Setup root pool cryptsetup partitions"
for i in "${!DISK_IDS[@]}"; do
  echo -n "${CRYPTSETUP_PASSPHRASE}" | \
    ( set -x; cryptsetup luksFormat --verbose "${CRYPTSETUP_DEFAULTS[@]}" "/dev/disk/by-id/${DISK_IDS[$i]}-part4" )
  echo -n "${CRYPTSETUP_PASSPHRASE}" | \
    ( set -x; cryptsetup luksOpen --verbose "/dev/disk/by-id/${DISK_IDS[$i]}-part4" "rpool${i}_crypt" )
done

echo_section "Create boot pool"
( 
  parts=()
  for id in "${DISK_IDS[@]}"; do
    parts+=( "/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "/dev/disk/by-id/${id}-part3")" )
  done

  set -x
  zpool create -o ashift=12 -d \
    -o autotrim=on \
    -o cachefile=/etc/zfs/zpool.cache \
    -o feature@async_destroy=enabled \
    -o feature@bookmarks=enabled \
    -o feature@embedded_data=enabled \
    -o feature@empty_bpobj=enabled \
    -o feature@enabled_txg=enabled \
    -o feature@extensible_dataset=enabled \
    -o feature@filesystem_limits=enabled \
    -o feature@hole_birth=enabled \
    -o feature@large_blocks=enabled \
    -o feature@livelist=enabled \
    -o feature@lz4_compress=enabled \
    -o feature@spacemap_histogram=enabled \
    -o feature@zpool_checkpoint=enabled \
    -O devices=off \
    -O acltype=posixacl -O xattr=sa \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/boot -R /target -f \
    "bpool" ${ZPOOL_TYPE} "${parts[@]}"
)

echo_section "Create root pool"
( set -x
  zpool create -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
    -O mountpoint=/ -R /target \
    "rpool" ${ZPOOL_TYPE} $(printf "/dev/mapper/rpool%s_crypt " "${!DISK_IDS[@]}")
)

echo_section "Create datasets"
( set -x
  # Create filesystem datasets to act as containers
  zfs create -o canmount=off -o mountpoint=none rpool/ROOT
  zfs create -o canmount=off -o mountpoint=none bpool/BOOT

  # Secure dataset
  zfs set setuid=off exec=off devices=off bpool

  # Enable discard
  zpool set autotrim=on rpool
  zpool set autotrim=on bpool

  # Create a filesystem datasets for the root and boot filesystems
  zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
  zfs mount rpool/ROOT/debian

  zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/debian
  zfs mount bpool/BOOT/debian

  # Create datasets
  zfs create                                            rpool/home
  zfs create -o mountpoint=/root                        rpool/home/root
  chmod 700 /target/root
  zfs create -o canmount=off                            rpool/var
  zfs create -o canmount=off                            rpool/var/lib
  zfs create                                            rpool/var/lib/vz
  zfs create                                            rpool/var/log
  zfs create                                            rpool/var/spool

  # If you wish to exclude these from snapshots:
  zfs create -o com.sun:auto-snapshot=false             rpool/var/cache
  zfs create -o com.sun:auto-snapshot=false             rpool/var/tmp
  chmod 1777 /target/var/tmp
)

echo_section "Mount a tmpfs at /run"
( set -x
  mkdir /target/run
  mount -t tmpfs tmpfs /target/run
  mkdir /target/run/lock
)

echo_section "Create swap zvol"
( set -x
  zfs create \
    -V "${SWAP_SIZE}" \
    -b "$(getconf PAGESIZE)" \
    -o compression=zle \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o com.sun:auto-snapshot=false \
    -o logbias=throughput \
    -o sync=always \
    rpool/swap
  mkswap -f /dev/zvol/rpool/swap
)

echo_section "Install the minimal system"
( set -x
  debootstrap --arch amd64 bullseye /target http://deb.debian.org/debian
)

echo_section "Setup chroot environment"
( set -x
  mount --make-private --rbind /dev  /target/dev
  mount --make-private --rbind /proc /target/proc
  mount --make-private --rbind /sys  /target/sys
)

cat <<END_OF_CHROOT >/target/var/tmp/chroot-commands.sh
#!/bin/bash
set -euxo pipefail

# array variables are not exported
DISK_IDS=( $(printf "\"%s\" " "${DISK_IDS[@]}") )

echo_section() {
  echo -e "\n\n\e[0;35m===== \${*} =====\e[0m"
}

export DEBIAN_FRONTEND=noninteractive
export GRUB_DISABLE_OS_PROBER=true

echo_section "Configure hostname"
echo "${TARGET_HOSTNAME}" > /etc/hostname
echo "${TARGET_IPADDRESS%/*}       ${TARGET_HOSTNAME}" >> /etc/hosts

echo_section "Configure package sources"
cat <<EOF > /etc/apt/sources.list
deb http://deb.debian.org/debian bullseye main contrib
#deb-src http://deb.debian.org/debian bullseye main contrib

deb http://security.debian.org/debian-security bullseye-security main contrib
#deb-src http://security.debian.org/debian-security bullseye-security main contrib

deb http://deb.debian.org/debian bullseye-updates main contrib
#deb-src http://deb.debian.org/debian bullseye-updates main contrib
EOF

echo_section "Configure proxmox pve repository"
echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bullseye pve-no-subscription" \
  > /etc/apt/sources.list.d/proxmox.list

base64 -d <<EOF > /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg
mQINBF+o6NQBEADdEeL7hTwBlX9kbRwf3ESa+H/LOjEUGEvpZkk5kMysIi+4DTXL79LoZwQZXGKM
3W6it7kF/YkE8hcGnHrFYKCcfmu3rGpQSF8v867xR6km0bzIRvLQXYYO3SL3SBDOlp4OuGwbcb+E
9/oacVhfZY6d94AhGx2rueDW+YcUDC/nQrDnIJfd+yurm1sHoZMG4cx43Y9Q5BlckyZN1Gt7KFSE
To9seayxJ47+IOMCw3s1nOyXWtUD7YrihSjQmhLd4jOJgLy7sSwOHnkrVfvvhIz6JfFn/ccGvPqK
72dddgX2aF/VT5LkSF9d6yi5Ea4/AENMLqljnw74b+uvOa6wT4zjqQHTu7Wj3xLr711o9VsSbGSu
RBP3Stwj2z6Xy8fTKChN8DkUal6HEtIVBvCs1jtioqdigoUY0cnHwGor1/yKMWsKjt5tqWjGMnBD
dLWngTM61yh4WtvxDh1zLK5Q0xGaIYDPrgcRhnO456+8JIGVoQVg6bu5g5m9ua1KRTsr+TaqctDw
DMqhhzqDAZpGuNgpHF7ycDYrof7sYFgQ1n3S/+yCpYJxTJOIvAdmkUTuHwDRkXqGvR4eyGy8/RZ0
KMQ7oVJbMyZextOZBbUE95FbE7EB8iOt9NZHH2pgBZojYhD9P4+xwSyTymR2t/SdpvmOROjOtIDx
bQqdBvmDUy33DQARAQABtDpQcm94bW94IEJ1bGxzZXllIFJlbGVhc2UgS2V5IDxwcm94bW94LXJl
bGVhc2VAcHJveG1veC5jb20+iQJUBBMBCgA+FiEEKBOaL4ML1oR4oaAf3UujkX4jv1kFAl+o6NQC
GwMFCRLMAwAFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQ3UujkX4jv1k3qxAAq5ggmp54L/LC
dfqNlMlloqiWerxhEYDZ+bBq6IFJtOcctm4kyrRUizRo2SUiO1wmPLjWcfQ1gUYP9ZgECNTzOGi7
o9z+lk76tQiH6GeckLOxTqvilOaxwfpJrvKDBOp8e0yl7BSyNtnbMpaX5+vH9gNl+pWpzFuNmBMz
85jkuI1qaoMDAbzY7Tg4YmkRO6Z/6Mj1F0vyQldTIB45hUtdzOkNaE/Pa4jBhb8jZ2DPGbz7QqEU
vsdbR06FaiFLtZmLBQ6/yTXtUy/SbyIr+LlNmThkifohqzP9VGFy3DYuLskL/GF9w1Jb4TE5vobc
U6DdY1nF5j4BbfwdaiOOm5n3dIy7QtqCZ0apDXTpn211GszjCL4AfdhsfvovBUYWLAE6bEZImJUq
iyTW/a96zDbc1zulAtDvuZNWH05nlrdNomTk70HDEth/GQ02O4jKbZxwWe/CWB0e9CvAssEFJZ5j
Id7guA0WsIz689tBJGYVMPc0WFL9Kuw3gweMd3TT/r/lqy0eDgsxT2ym1/Jg9Kj6Ko2rAfX/Sr9O
dXwE2X8e745Z9HTABtxgSnFwCnfv/9QHrlfnn1C4e7QEcTuoen8JSOKlTYzoeFGDRuVi5uI+lFfI
F1DZiWPnnvSmyYp3DPj7a1gXa3vX3EiIHWNYZzGEhyblqT9Oj7HFiFRGK2gWh5M=
EOF

chmod +r /etc/apt/trusted.gpg.d/proxmox-release-bullseye.gpg

echo_section "Configure a basic system environment"
ln -s /proc/self/mounts /etc/mtab
apt-get update
apt-get upgrade --yes
apt-get install --yes locales keyboard-configuration console-setup

echo_section "Setup locale"
perl -i -pe 's/# (en_US.UTF-8)/\$1/' /etc/locale.gen
echo 'LANG="en_US.UTF-8"' > /etc/default/locale
ln -fs /usr/share/zoneinfo/Europe/Berlin /etc/localtime
locale-gen
dpkg-reconfigure -f noninteractive tzdata keyboard-configuration console-setup debconf

echo_section "Mount a tmpfs to /tmp"
cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount

echo_section "Install required packages"
apt-get install --yes \
  bridge-utils \
  cryptsetup \
  keyutils \
  openssh-server \
  rng-tools \
  rsync \
  sudo \
  tmux \
  "\$(apt-cache -q0 depends proxmox-ve | sed -rn 's/.*(pve-kernel-[0-9]+\.[0-9]+).*/\1/p')" \
  zfsutils-linux \
  zfs-initramfs \
  zfs-zed

echo_section "Configure crypttab"
for i in "\${!DISK_IDS[@]}"; do
  uuid=\$(blkid -s UUID -o value "/dev/disk/by-id/\${DISK_IDS[\$i]}-part4")
  line="rpool\${i}_crypt UUID=\${uuid} system_crypt luks,initramfs,keyscript=decrypt_keyctl"
  if [[ \$(lsblk -dnro rota "/dev/disk/by-id/\${DISK_IDS[\$i]}") == "0" ]]; then
    # device is a non rotational device (aka. SSD)
    line="\${line},discard"
  fi
  echo "\${line}" >> /etc/crypttab
done

echo_section "Install grub packages"
if [[ "${BOOT_TYPE}" != "BIOS" ]]; then
  for i in "\${!DISK_IDS[@]}"; do
    mkdir /boot/efi\${i/0/}
    efi_uuid=\$(blkid -s UUID -o value "/dev/disk/by-id/\${DISK_IDS[\$i]}-part2")
    echo "UUID=\${efi_uuid} /boot/efi\${i/0/} vfat nofail,x-systemd.device-timeout=1 0 1" >> /etc/fstab
  done

  mount /boot/efi

  apt-get install --yes grub-efi-amd64 shim-signed
else
  apt-get install --yes grub-pc
fi

echo_section "Configure swap"
echo "/dev/zvol/rpool/swap none swap discard 0 0" >> /etc/fstab
echo "RESUME=none" > /etc/initramfs-tools/conf.d/resume

echo_section "Enable importing bpool"
cat <<EOF >/etc/systemd/system/zfs-import-bpool.service
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none "bpool"
# Work-around to preserve zpool cache:
ExecStartPre=-/bin/mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache
ExecStartPost=-/bin/mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache
[Install]
WantedBy=zfs-import.target
EOF

systemctl enable zfs-import-bpool.service

echo_section "Verify that the ZFS root filesystem is recognized"
if ! [ \`grub-probe /boot\` == "zfs" ];then
  echo "grub-probe != zfs"
  exit 1
fi

echo_section "Refresh the initramfs"
update-initramfs -u -k all

echo_section "Configure grub"
# Workaround GRUB's missing zpool-features support:
sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"luks.crypttab=no root=ZFS=rpool/ROOT/debian ${CMDLINE_LINUX:+${CMDLINE_LINUX} }|" \
  /etc/default/grub

# Make debugging GRUB easier
sed -i "s/quiet//" /etc/default/grub
sed -i "s/#GRUB_TERMINAL/GRUB_TERMINAL/" /etc/default/grub

# Update the boot configuration
update-grub

# Install the boot loader
if [[ "${BOOT_TYPE}" != "BIOS" ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=debian --recheck --no-floppy --no-nvram
  umount /boot/efi
else
  for id in "\${DISK_IDS[@]}"; do
    grub-install --target=i386-pc "/dev/disk/by-id/\${id}"
  done
fi

# Verify that the ZFS module is installed
ls /boot/grub/*/zfs.mod

echo_section "Fix filesystem mount ordering"

zfs set mountpoint=legacy bpool/BOOT/debian
echo "bpool/BOOT/debian /boot zfs nodev,relatime,x-systemd.requires=zfs-import-bpool.service 0 0" >> /etc/fstab

mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/rpool
[[ ! -e /etc/zfs/zed.d/history_event-zfs-list-cacher.sh ]] && \
  ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d

zed -F &
ZED_PID=\$!

# Loop while zed does its thing
while ! ( [ -f /etc/zfs/zfs-list.cache/rpool ] && \
          [ -s /etc/zfs/zfs-list.cache/rpool ] )
do
  sleep 3
  # If it is empty, force a cache update and check again:
  zfs set canmount=noauto rpool/ROOT/debian
done

# Delay one more time to avoid race condition
sleep 3
kill \$ZED_PID

# Fix the paths to eliminate /target:
sed -Ei "s|/target/?|/|" /etc/zfs/zfs-list.cache/rpool

echo_section "Tasksel"
tasksel install standard

echo_section "Configure sshd"
sed -i "s/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_\*/" /etc/ssh/sshd_config

echo_section "Configure network"
cat <<EOF >> "/etc/network/interfaces"
auto ${ETHERNET_DEV}
allow-hotplug ${ETHERNET_DEV}
iface ${ETHERNET_DEV} inet manual

auto vmbr0
iface vmbr0 inet static
  bridge-ports ${ETHERNET_DEV}
  bridge-stp off
  bridge-fd 0
  address ${TARGET_IPADDRESS}
  gateway ${TARGET_GATEWAY}
  dns-nameservers ${TARGET_DNS}
EOF

echo_section "Set root password"
echo "root:${ROOT_PASSWORD}" | chpasswd

echo_section "Enroll ssh user"
adduser --disabled-login --disabled-password --gecos "" "${SSH_USER}"
mkdir "/home/${SSH_USER}/.ssh"
echo "${SSH_KEY}" > "/home/${SSH_USER}/.ssh/authorized_keys"
chown -R "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh"
chmod 700 "/home/${SSH_USER}/.ssh"
chmod 600 "/home/${SSH_USER}/.ssh/authorized_keys"
echo "${SSH_USER}    ALL= NOPASSWD: ALL" > "/etc/sudoers.d/${SSH_USER}"

echo_section "Self delete chroot commands script"
rm "\${0}"

echo_section "Snapshot the initial installation"
zfs snapshot rpool/ROOT/debian@install
zfs snapshot bpool/BOOT/debian@install
END_OF_CHROOT

echo_section "Run generated chroot script"
( set -x
  chmod +x /target/var/tmp/chroot-commands.sh
  chroot /target /var/tmp/chroot-commands.sh
)

if [[ "${BOOT_TYPE}" != "BIOS" ]]; then
  # "This is arguably a mis-design in the UEFI specification - the ESP is a single point of failure on one disk."
  # https://wiki.debian.org/UEFI#RAID_for_the_EFI_System_Partition
  # https://pve.proxmox.com/wiki/Host_Bootloader
  echo_section "Mirror ESP partition"
  for i in "${!DISK_IDS[@]}"; do
    if [[ "${i}" -gt "0" ]]; then
      ( set -x; dd if="/dev/disk/by-id/${DISK_IDS[0]}-part2" of="/dev/disk/by-id/${DISK_IDS[$i]}-part2" )

      printf "%s\n" \
        "!/bin/sh" \
        "set -e" \
        "" \
        "if mount | grep -q '/boot/efi$i'; then" \
        "  rsync -t --recursive --delete /boot/efi/ /boot/efi$i/" \
        "fi" \
        > "/target/etc/grub.d/90_copy_to_boot_efi$i"
    fi
    efibootmgr \
      --create \
      --label "PVE-ZOL (RAID disk ${i})" \
      --loader "\EFI\debian\grubx64.efi" \
      --disk "/dev/disk/by-id/${DISK_IDS[$i]}" --part 2
  done
fi

echo_section "DONE"

read -ep "Umount target system? [Y/n]" choice

if [[ "${choice}" =~ ^[nN](o)?$ ]]; then
  exit 0
fi

( set -x
  umount -lf /target/run
  umount -lf /target/dev
  umount -lf /target/proc
  umount -lf /target/sys
  zfs umount -a
  zpool export -a
  for i in "${!DISK_IDS[@]}"; do
    cryptsetup luksClose "rpool${i}_crypt"
  done
  sync
)
