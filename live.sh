#!/bin/bash 

# set -e 

function init_networking() {
  timedatectl set-ntp true    
  echo "Setting dns/domain.."
  resolvectl dns wlan0 ${__ALI_DNS_SERVER}
  resolvectl dns eno1 ${__ALI_DNS_SERVER}
  resolvectl domain wlan0 ${__ALI_DNS_DOMAIN} 
  resolvectl domain eno1 ${__ALI_DNS_DOMAIN} 
  
  connect_wireless
}

# function set_wlan() {
#   echo "iwctl:"
#   iwctl 
#   station wlan0 connect ${__ALI_WIRELESS_SSID} 
# }

function connect_wireless() {
  INTERFACE=${1:="wlan0"}
  echo "Configuring ${INTERFACE}.."
  # -- archiso (live) or chroot
  echo "${__ALI_WIRELESS_PASSPHRASE}" | wpa_passphrase ${__ALI_WIRELESS_SSID} > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
  wpa_supplicant -B -D wext -i ${INTERFACE} -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
  systemctl enable wpa_supplicant@wlan0
}

####### FILESYSTEM #######

function create_volumes() {
  _partition \
    && _create_lvs 
}

function _partition() {
  if ! blkid ${__ALI_PV_PARTITION}; then 
    curl -o arch_partition_dump http://${__ALI_PXE_SERVER}/arch/arch_partition_dump
    sfdisk ${__ALI_TARGET_DEVICE} < arch_partition_dump
  fi 

#  fdisk ${__ALI_TARGET_DEVICE} 
#  n, enter, enter, +1M, enter 
#  t, 4
#  n, enter, enter, enter 
#  t, lvm 
#  w
}

function _lv_exists() {
  LV_NAME=$1
  lvs --noheaders | grep -E "^${LV_NAME}\s" 2>&1 > /dev/null
}

function _create_lvs() {

  if ! vgs ${__ALI_VG_NAME}; then 
    echo "VG ${__ALI_VG_NAME} doesn't exist, creating.."
    vgcreate ${__ALI_VG_NAME} ${__ALI_PV_PARTITION}
  else 
    echo "VG ${__ALI_VG_NAME} already exists"
  fi 
  
  if [[ ! $(_lv_exists root) ]]; then 
    echo "LV root doesn't exist, creating.."
    lvcreate -L ${__ALI_LV_ROOT_SIZE} -n root ${__ALI_VG_NAME}
    mkfs.ext4 /dev/${__ALI_VG_NAME}/root 
  else 
    echo "LV root already exists"
  fi 
  
  if [[ ! $(_lv_exists var) ]]; then 
    echo "LV var doesn't exist, creating.."
    lvcreate -L ${__ALI_LV_VAR_SIZE} -n var ${__ALI_VG_NAME}
    mkfs.ext4 /dev/${__ALI_VG_NAME}/var 
  else 
    echo "LV var already exists"
  fi 
  
  if [[ ! $(_lv_exists tmp) ]]; then 
    echo "LV tmp doesn't exist, creating.."
    lvcreate -L ${__ALI_LV_TMP_SIZE} -n tmp ${__ALI_VG_NAME}
    mkfs.ext4 /dev/${__ALI_VG_NAME}/tmp 
  else 
    echo "LV tmp already exists"
  fi 
  
  if [[ ! $(_lv_exists swap) ]]; then 
    echo "LV swap doesn't exist, creating.."
    lvcreate -L ${__ALI_LV_SWAP_SIZE} -n swap ${__ALI_VG_NAME}
    mkswap /dev/${__ALI_VG_NAME}/swap  
  else 
    echo "LV swap already exists"
  fi 
  
  if [[ ! $(_lv_exists home) ]]; then 
    echo "LV home doesn't exist, creating.."
    lvcreate -l ${__ALI_LV_HOME_SIZE} -n home ${__ALI_VG_NAME}
    mkfs.ext4 /dev/${__ALI_VG_NAME}/home 
  else 
    echo "LV home already exists"
  fi 
  
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
      LV_NAME=/dev/${__ALI_VG_NAME}/${LV}
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
      echo -n "No LVs detected. Remove PV ${__ALI_PV_PARTITION}? y/N "
      read DEL_PV
      if [[ "${DEL_PV}" = "y" ]]; then 
        echo "Deleting PV ${__ALI_PV_PARTITION}.."
        pvremove ${__ALI_PV_PARTITION} --force --force
      else 
        echo "Skipping PV ${__ALI_PV_PARTITION} delete.."
      fi 
    else 
      echo "LVs detected, not removing PV:"
      lvs 
    fi 
    
    echo "To remove the actual partition:"
    echo "fdisk ${__ALI_TARGET_DEVICE}"
    echo "d <enter> <enter> d <enter> w <enter>"  
 fi 
}

function mount_volumes() {
  echo "Mounting ${__ALI_VG_NAME}.."
  mount /dev/${__ALI_VG_NAME}/root /mnt
  sleep 3
  mkdir -vp /mnt/{var,tmp,home}
  echo "Mounting var.."
  mount /dev/${__ALI_VG_NAME}/var /mnt/var 
  echo "Mounting tmp.."
  mount /dev/${__ALI_VG_NAME}/tmp /mnt/tmp 
  echo "Mounting home.."
  mount /dev/${__ALI_VG_NAME}/home /mnt/home 
  echo "Mounting swap.."
  swapon /dev/${__ALI_VG_NAME}/swap 
}

function unmount_volumes() {
  echo "Unmounting ${__ALI_VG_NAME}.."
  umount /mnt/{tmp,var,home}
  umount /mnt
  swapoff /dev/${__ALI_VG_NAME}/swap
}

####### END FILESYSTEM #######

####### ARCH INSTALL #######

function chroot_configure() {
  
  _check_chroot || exit
    
  echo "Writing /etc/localtime.."
  ln -sf /usr/share/zoneinfo/${__ALI_TIMEZONE} /etc/localtime 
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
  echo "LANG=${__ALI_LOCALE_LANG}" > /etc/locale.conf 
  
  echo "Writing /etc/hostname.."
  echo "${__ALI_TARGET_HOSTNAME}" > /etc/hostname 
  
  echo "Writing /etc/hosts.."
  printf "127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t ${__ALI_TARGET_HOSTNAME}.localdomain ${__ALI_TARGET_HOSTNAME}\n" >> /etc/hosts 
  
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
  
  useradd -m -s /bin/bash ${__ALI_USER_USERNAME}
  printf "${__ALI_USER_PASSWORD}\n${__ALI_USER_PASSWORD}\n" | passwd ${__ALI_USER_USERNAME}
  
  useradd -m -s /bin/bash ${__ALI_DEPLOY_USERNAME} 
  printf "${__ALI_DEPLOY_PASSWORD}\n${__ALI_DEPLOY_PASSWORD}\n" | passwd ${__ALI_DEPLOY_USERNAME} 
}

function grub_install() {
  
  _check_chroot || exit
  
  echo "Installing grub to ${__ALI_TARGET_DEVICE}.."
  grub-install ${__ALI_TARGET_DEVICE} 
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
    echo "Then re-enter this script with \"curl -s https://raw.githubusercontent.com/tpalko/arch-live-install/main/live.sh | bash -\""    
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
}

function init_live() {
  init_networking && mount_volumes
}

function refresh() {
  if [[ ! -f ~/.alirc ]]; then 
    curl -o ~/.alirc https://raw.githubusercontent.com/tpalko/arch-live-install/main/.env.example
  else 
    echo "Not updating existing ~/.alirc"
  fi 
  curl -s https://raw.githubusercontent.com/tpalko/arch-live-install/main/live.sh | bash -
}

function instructions() {
  echo "Menu: "
  echo "$ menu"
}

function environment() {
  
  [[ ! -f ~/.alirc ]] && echo "Missing ~/.alirc" && exit 1

  export $(cat ~/.alirc | xargs)
  env | grep -E "^__ALI_"
}

function clear_environment() {
  while read STUF; do 
    unset ${STUF}
  done <<< $(env | grep -E "^__ALI_" | sed -E "s/^(.*)=.*$/\1/")
}

function menu() {

  # trap clear_environment SIGINT   
  # environment 

  echo "How you got here: "
  echo "$ curl -s https://raw.githubusercontent.com/tpalko/arch-live-install/main/live.sh | bash -"
  
  printf "live boot\n"
  printf "\t1. hard reset: init_networking, wipe_volumes, create_volumes, mount_volumes\n"
  printf "\t2. base install: pacstrap, genfstab\n"
  printf "\t3. core install: configuration, core packages, grub\n"
  printf "\t4. create users\n"
  printf "\t5. maintenance (LV management, boot repair, volume restore): init_networking, mount_volumes\n"
  printf "native boot\n"
  printf "\t6. backup restore: backup_init\n"
  printf "\t7. state management: state_init\n"
  printf "general\n"
  printf "\t8. refresh this script\n"
  # printf "\tCTRL-C to quit and clear environment\n"
  
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
    8) refresh && exit;;
    *)  menu;;
  esac 
}

environment 
menu 
