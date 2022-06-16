#!/bin/bash 

function init_networking() {
  timedatectl set-ntp true    
  echo "Setting dns/domain.."
  resolvectl dns wlan0 ${DNS_SERVER}
  resolvectl dns eno1 ${DNS_SERVER}
  resolvectl domain wlan0 ${DNS_DOMAIN} 
  resolvectl domain eno1 ${DNS_DOMAIN} 
  
  connect_wireless
}

# function set_wlan() {
#   echo "iwctl:"
#   iwctl 
#   station wlan0 connect ${WIRELESS_SSID} 
# }

function connect_wireless() {
  INTERFACE=${1:="wlan0"}
  echo "Configuring ${INTERFACE}.."
  # -- archiso (live) or chroot
  echo "${WIRELESS_PASSPHRASE}" | wpa_passphrase ${WIRELESS_SSID} > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
  wpa_supplicant -B -D wext -i ${INTERFACE} -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
  systemctl enable wpa_supplicant@wlan0
}

####### FILESYSTEM #######

function create_volumes() {
  _partition \
    && _create_lvs \
    && _make_fs    
}

function _partition() {
  curl -o arch_partition_dump http://${PXE_SERVER}/arch/arch_partition_dump
  sfdisk ${TARGET_DEVICE} < arch_partition_dump

#  fdisk ${TARGET_DEVICE} 
#  n, enter, enter, +1M, enter 
#  t, 4
#  n, enter, enter, enter 
#  t, lvm 
#  w
}

function _create_lvs() {  
  vgcreate ${VG_NAME} ${PV_PARTITION}
  lvcreate -L ${LV_ROOT_SIZE} -n root ${VG_NAME}
  lvcreate -L ${LV_VAR_SIZE} -n var ${VG_NAME}
  lvcreate -L ${LV_TMP_SIZE} -n tmp ${VG_NAME}
  lvcreate -L ${LV_SWAP_SIZE} -n swap ${VG_NAME}
  lvcreate -l ${LV_HOME_SIZE} -n home ${VG_NAME}
}

function _make_fs() {
  mkfs.ext4 /dev/${VG_NAME}/root 
  mkfs.ext4 /dev/${VG_NAME}/var 
  mkfs.ext4 /dev/${VG_NAME}/tmp 
  mkfs.ext4 /dev/${VG_NAME}/home 
  mkswap /dev/${VG_NAME}/swap  
}

function wipe_volumes() {
  echo -n "Are you really damn sure? y/N "
  read SURE 
  ([[ "${SURE}" = "y" ]] && echo -n "Really, this will TRASH your logical volumes. y/N ") || return 
  read SURE 
  ([[ "${SURE}" = "y" ]] && echo -n "Please type \"FORCE\": ") || return 
  read FORCE 
  [[ ! "${FORCE}" = "FORCE" ]] && return 
  if [[ "${FORCE}" = "FORCE" ]]; then 
    unmount_volumes
    for LV in root tmp var swap home; do 
      LV_NAME=/dev/${VG_NAME}/${LV}
      echo -n "Delete logical volume ${LV_NAME}? y/N "
      read DEL_LV
      if [[ ${DEL_LV} = "y" ]]; then 
        echo "Deleting ${LV_NAME}.."
        lvremove ${LV_NAME}
      else 
        echo "Skipping ${LV_NAME} delete.."
      fi 
    done 
    if [[ $(lvs --noheadings | wc -l) -eq 0 ]]; then 
      echo -n "No LVs detected. Remove PV ${PV_PARTITION}? y/N "
      read DEL_PV
      if [[ "${DEL_PV}" = "y" ]]; then 
        echo "Deleting PV ${PV_PARTITION}.."
        pvremove ${PV_PARTITION} --force --force
      else 
        echo "Skipping PV ${PV_PARTITION} delete.."
      fi 
    else 
      echo "LVs detected, not removing PV:"
      lvs 
    fi 
    
    echo "To remove the actual partition:"
    echo "fdisk ${TARGET_DEVICE}"
    echo "d <enter> <enter> d <enter> w <enter>"  
 fi 
}

function mount_volumes() {
  echo "Mounting ${VG_NAME}.."
  mount /dev/${VG_NAME}/root /mnt
  sleep 3
  mkdir -vp /mnt/{var,tmp,home}
  echo "Mounting var.."
  mount /dev/${VG_NAME}/var /mnt/var 
  echo "Mounting tmp.."
  mount /dev/${VG_NAME}/tmp /mnt/tmp 
  echo "Mounting home.."
  mount /dev/${VG_NAME}/home /mnt/home 
  echo "Mounting swap.."
  swapon /dev/${VG_NAME}/swap 
}

function unmount_volumes() {
  echo "Unmounting ${VG_NAME}.."
  umount /mnt/{tmp,var,home}
  umount /mnt
  swapoff /dev/${VG_NAME}/swap
}

####### END FILESYSTEM #######

####### ARCH INSTALL #######

function chroot_configure() {
  
  _check_chroot || exit
    
  echo "Writing /etc/localtime.."
  ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime 
  echo "Setting hwclock.."
  hwclock --systohc 
  echo "Editing /etc/locale.gen"
  echo -n "Enter when ready "
  read 
  vim /etc/locale.gen 
  # sed -i "s/^.?en_US(.*)$/en_US\1/g" /etc/locale.gen 
  echo "Generating locale.."
  locale-gen 

  echo "Writing /etc/locale.conf.."
  echo "LANG=${LOCALE_LANG}" > /etc/locale.conf 
  
  echo "Writing /etc/hostname.."
  echo "${TARGET_HOSTNAME}" > /etc/hostname 
  
  echo "Writing /etc/hosts.."
  printf "127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t ${TARGET_HOSTNAME}.localdomain ${TARGET_HOSTNAME}\n" >> /etc/hosts 
  
  echo "Editing /etc/mkinitcpio.conf"
  echo "Add lvm2 to HOOKS as shown in examples"
  echo -n "Enter when ready "
  read 
  vim /etc/mkinitcpio.conf 
  echo "Creating initial ramdisk environment.."
  mkinitcpio -P

  echo "Setting root password"
  passwd
}

function chroot_install() {
  
  _check_chroot || exit
  
  pacman -Fy core 
  pacman -Syu dosfstools exfatprogs f2fs-tools e2fsprogs ntfs-3g xfsprogs 
  pacman -Syu lvm2 
  pacman -Syu resolvconf openssh wpa_supplicant iw iwd dhcpcd
  # pacman -Syu iproute2 dhcpcd systemd-resolvconf systemd-networkd iwd openssh netctl
  pacman -Syu vim # emacs
  # pacman -Syu dialog wpa_supplicant
  pacman -Syu man-db man-pages texinfo
  pacman -Syu intel-ucode 
  pacman -Syu grub 
  pacman -Syu lynx
  pacman -Syu --needed base-devel git 
  
  systemctl enable sshd 
  systemctl enable dhcpcd
  systemctl enable iptables 
 
  # -- can't do this in chroot? 
  #systemctl enable iwd
}

function create_users() {
  
  _check_chroot || exit
  
  useradd -m -s /bin/bash ${USER_USERNAME}
  printf "${USER_PASSWORD}\n${USER_PASSWORD}\n" | passwd ${USER_USERNAME}
  
  useradd -m -s /bin/bash ${DEPLOY_USERNAME} 
  printf "${DEPLOY_PASSWORD}\n${DEPLOY_PASSWORD}\n" | passwd ${DEPLOY_USERNAME} 
}

function grub_install() {
  
  _check_chroot || exit
  
  echo "Installing grub to ${TARGET_DEVICE}.."
  grub-install ${TARGET_DEVICE} 
  echo "Creating grub.cfg.."
  grub-mkconfig -o /boot/grub/grub.cfg 
}

####### END ARCH INSTALL #######

function install_x() {
  pacman -Syu xorg-server xorg-xinit xterm xlockmore xscreensaver xf86-video-intel xclip
}

function install_windowing_and_desktop() {
  #pacman -Syu sugar sugar-runner 
  pacman -Syu spectrwm
  echo "bar_font = xos4 Terminus:pixelsize=14" > ~/.spectrwm.conf
  cat /etc/spectrwm/spectrwm_us.conf >> ~/.spectrwm.conf 
}

function install_display_manager() {
  cd ~
  mkdir -p builds 
  cd builds 
  git clone https://github.com/loh-tar/tbsm 
  cd tbsm 
  make install 
  echo "[[ ${XDG_VTNR} -lt 2 ]] && tbsm" >> ~/.bash_profile 
}

function install_chrome() {
  cd ~
  mkdir -p builds
  git clone https://aur.archlinux.org/google-chrome.git 
  cd google-chrome 
  pacman -Syu alsa-lib gtk3 libxss libxtst nss
  makepkg -si
  pacman -U google-chrome*.zst
}

function audio() {
  pacman -Syu alsa-utils pavucontrol pulseaudio bluez bluez-utils
  pulseaudio --start 
  systemctl enable bluetooth
  systemctl start bluetooth
}

function multimedia() {
  pacman -Syu kdenlive
}

function catchall() {
  pacman -Syu mariadb-clients
}

function _check_chroot() {
  ROOT_MOUNT=$(lsblk | grep vg-root | awk '{ print $7 }')
  if [[ "${ROOT_MOUNT}" = "/mnt" ]]; then 
    echo "Please run \"arch-chroot /mnt\""
    echo "Then re-source live.sh with \"source <(curl -s http://${PXE_SERVER}/arch/live.sh)\""    
    return 1
  fi 
  
  return 0
}

######################################

function core_install() {
  
  _check_chroot || exit 
  
  chroot_install && chroot_configure && grub_install
  echo "You may restart into your new system now!"
  echo "$ exit"
  echo "$ unmount_volumes"
  echo "$ shutdown -r now"
  instructions
}

function base_install() {
  pacstrap /mnt base linux linux-firmware 
  genfstab -U /mnt >> /mnt/etc/fstab 
  _check_chroot
  echo "Then, proceed with configuration, core packages, and grub with "
  echo "$ core_install" 
  echo "$ create_users"  
}

function hard_reset() {
  init_networking && wipe_volumes && create_volumes && mount_volumes
  instructions
}

function init_live() {
  init_networking && mount_volumes
}

function refresh() {
  source <(curl -s http://${PXE_SERVER_IP}/arch/live.sh)
}

function instructions() {
  echo "How you got here: "
  echo "$ source <(curl -s http://${PXE_SERVER_IP}/arch/live.sh)"

  echo "Menu: "
  echo "$ menu"
}

function menu() {
  
  instructions 
  
  printf "-- live boot"
  printf "\t1. hard reset: init_networking, wipe_volumes, create_volumes, mount_volumes"
  printf "\t2. base install: pacstrap, genfstab"
  printf "\t3. core install: configuration, core packages, grub"
  printf "\t4. create users"
  printf "\t5. maintenance (LV management, boot repair, volume restore): init_networking, mount_volumes"
  printf "-- native boot"
  printf "\t6. backup restore: backup_init"
  printf "\t7. state management: state_init"
  
  # -- init_networking: init live system: wireless, DNS, etc. networking 
  # -- wipe_volumes: umount all, cycle through LV, PV, prompt to delete, prompt to delete partition 
  # -- create_volumes: create partition if missing, cycle through PV, LV, create if missing, genfstab 
  # -- mount_volumes: mount LVs 
  # -- base_install: base install
  # -- backup_init: install bckt, pull state 
  # -- state_init: install ansible, pull playbooks 
  printf "? "
  read ACTION 
  case ${ACTION} in
    1) hard_reset;;
    2) base_install;;
    3) core_install;;
    4) create_users;;
    5) init_live;;
    6) echo "not implemented" && exit;;
    7) echo "not implemented" && exit;;
    *)  menu;;
  esac 
}

instructions
