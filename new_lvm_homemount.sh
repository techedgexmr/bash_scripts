#!/bin/bash
set -e

VG_NAME="vg_stig"

# Detect the secondary disk (exclude root disk)
DISK=$(lsblk -nd --output NAME | grep -E 'nvme|xvd|sd' | grep -v $(lsblk -nd --output NAME,MOUNTPOINT | grep -w "/" | awk '{print $1}') | head -n 1)
DISK="/dev/$DISK"

if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "ERROR: No secondary disk found. Exiting."
    exit 1
fi

echo "Using secondary disk: $DISK"

# Ensure disk is available with a timeout
TIMEOUT=120
TIMER=0
while [[ ! -b $DISK && $TIMER -lt $TIMEOUT ]]; do
    echo "Waiting for $DISK to be available..."
    sleep 5
    ((TIMER+=5))
done

if [[ ! -b $DISK ]]; then
    echo "ERROR: Disk $DISK not available. Exiting."
    exit 1
fi

# Unmount all existing partitions
echo "Unmounting existing partitions on $DISK..."
lsblk -ln -o MOUNTPOINT $DISK | grep -v '^$' | while read MOUNT; do
    umount "$MOUNT" || true
done

# Wipe all old partitions and metadata
echo "Wiping all partitions on $DISK..."
wipefs -a $DISK || true
sgdisk --zap-all $DISK
partprobe $DISK
sleep 5  # Ensure disk updates

# Create LVM partition
echo "Creating LVM partition on $DISK..."
sgdisk -n 1:0:0 -t 1:8e00 $DISK
partprobe $DISK
sleep 5

# Setup LVM
echo "Initializing LVM on $DISK..."
pvcreate ${DISK}1
vgcreate $VG_NAME ${DISK}1

lvcreate -L 10G -n lv_var $VG_NAME
lvcreate -L 10G -n lv_var_log $VG_NAME
lvcreate -L 10G -n lv_var_log_audit $VG_NAME
lvcreate -L 10G -n lv_home $VG_NAME
lvcreate -L 10G -n lv_tmp $VG_NAME
lvcreate -L 10G -n lv_opt $VG_NAME
lvcreate -L 8G -n lv_swap $VG_NAME

# Format the new logical volumes
mkfs.xfs /dev/$VG_NAME/lv_var
mkfs.xfs /dev/$VG_NAME/lv_var_log
mkfs.xfs /dev/$VG_NAME/lv_var_log_audit
mkfs.xfs /dev/$VG_NAME/lv_home
mkfs.xfs /dev/$VG_NAME/lv_tmp
mkfs.xfs /dev/$VG_NAME/lv_opt
mkswap /dev/$VG_NAME/lv_swap

# Create mount points
mkdir -p /mnt/lv_home /var /var/log /var/log/audit /home /tmp /opt

# Mount the new LVM partition temporarily to /mnt/lv_home
mount /dev/$VG_NAME/lv_home /mnt/lv_home

# Preserve old /home content
rsync -avxH /home/ /mnt/lv_home/

# Unmount the temporary mount and mount it to /home
umount /mnt/lv_home
mount /dev/$VG_NAME/lv_home /home

# Mount the other logical volumes
mount /dev/$VG_NAME/lv_var /var
mount /dev/$VG_NAME/lv_var_log /var/log
mount /dev/$VG_NAME/lv_var_log_audit /var/log/audit
mount /dev/$VG_NAME/lv_tmp /tmp
mount /dev/$VG_NAME/lv_opt /opt
swapon /dev/$VG_NAME/lv_swap

# Persist mounts in /etc/fstab
echo "/dev/mapper/${VG_NAME}-lv_var /var xfs defaults,nodev 0 0" >> /etc/fstab
echo "/dev/mapper/${VG_NAME}-lv_var_log /var/log xfs defaults,nodev 0 0" >> /etc/fstab
echo "/dev/mapper/${VG_NAME}-lv_var_log_audit /var/log/audit xfs defaults,nodev 0 0" >> /etc/fstab
echo "/dev/mapper/${VG_NAME}-lv_home /home xfs defaults,nodev 0 0" >> /etc/fstab
echo "/dev/mapper/${VG_NAME}-lv_tmp /tmp xfs defaults,nodev,noexec,nosuid 0 0" >> /etc/fstab
echo "/dev/mapper/${VG_NAME}-lv_opt /opt xfs defaults,nodev 0 0" >> /etc/fstab
echo "/dev/mapper/${VG_NAME}-lv_swap swap swap defaults 0 0" >> /etc/fstab

# Restore SELinux contexts
restorecon -Rv /var /var/log /var/log/audit /home /tmp /opt

# Clean up before AMI creation
echo "Cleaning up before AMI creation..."
rm -rf /var/log/{wtmp,btmp,secure,messages} /root/.bash_history
truncate -s 0 /var/log/lastlog
history -c

echo "Bootstrap complete. Rebooting..."
reboot
