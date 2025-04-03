#!/bin/bash
set -e

VG_NAME="vg_stig"
DISK="/dev/nvme1n1"

echo "Starting LVM setup..."

# Ensure the disk is available before proceeding
while [[ ! -b $DISK ]]; do
    echo "Waiting for $DISK to be available..."
    sleep 5
done

# Check if LVM already exists
if pvs $DISK &>/dev/null; then
    echo "LVM is already configured on $DISK. Skipping setup."
else
    echo "Setting up LVM on $DISK..."

    # Unmount any existing partitions
    for PART in $(lsblk -ln -o MOUNTPOINT $DISK | grep -v '^$'); do
        echo "Unmounting $PART..."
        umount "$PART" || true
    done

    # Wipe existing partitions
    echo "Wiping existing partitions..."
    wipefs -a $DISK
    sgdisk --zap-all $DISK

    # Create LVM structure
    pvcreate $DISK
    vgcreate $VG_NAME $DISK

    # Create required STIG-compliant partitions
    lvcreate -L 10G -n lv_var $VG_NAME
    lvcreate -L 10G -n lv_var_log $VG_NAME
    lvcreate -L 10G -n lv_var_log_audit $VG_NAME
    lvcreate -L 10G -n lv_home $VG_NAME
    lvcreate -L 10G -n lv_tmp $VG_NAME
    lvcreate -L 10G -n lv_opt $VG_NAME
    lvcreate -L 8G -n lv_swap $VG_NAME

    # Format partitions
    mkfs.xfs /dev/$VG_NAME/lv_var
    mkfs.xfs /dev/$VG_NAME/lv_var_log
    mkfs.xfs /dev/$VG_NAME/lv_var_log_audit
    mkfs.xfs /dev/$VG_NAME/lv_home
    mkfs.xfs /dev/$VG_NAME/lv_tmp
    mkfs.xfs /dev/$VG_NAME/lv_opt
    mkswap /dev/$VG_NAME/lv_swap

    # Create mount points
    mkdir -p /var /var/log /var/log/audit /home /tmp /opt

    # Mount partitions
    mount /dev/$VG_NAME/lv_var /var
    mount /dev/$VG_NAME/lv_var_log /var/log
    mount /dev/$VG_NAME/lv_var_log_audit /var/log/audit
    mount /dev/$VG_NAME/lv_home /home
    mount /dev/$VG_NAME/lv_tmp /tmp
    mount /dev/$VG_NAME/lv_opt /opt
    swapon /dev/$VG_NAME/lv_swap

    # Add to fstab
    echo "/dev/mapper/${VG_NAME}-lv_var /var xfs defaults,nodev 0 0" >> /etc/fstab
    echo "/dev/mapper/${VG_NAME}-lv_var_log /var/log xfs defaults,nodev 0 0" >> /etc/fstab
    echo "/dev/mapper/${VG_NAME}-lv_var_log_audit /var/log/audit xfs defaults,nodev 0 0" >> /etc/fstab
    echo "/dev/mapper/${VG_NAME}-lv_home /home xfs defaults,nodev 0 0" >> /etc/fstab
    echo "/dev/mapper/${VG_NAME}-lv_tmp /tmp xfs defaults,nodev,noexec,nosuid 0 0" >> /etc/fstab
    echo "/dev/mapper/${VG_NAME}-lv_opt /opt xfs defaults,nodev 0 0" >> /etc/fstab
    echo "/dev/mapper/${VG_NAME}-lv_swap swap swap defaults 0 0" >> /etc/fstab

    # Apply SELinux labels
    restorecon -Rv /var /var/log /var/log/audit /home /tmp /opt

    echo "LVM setup complete."
fi

# Clean up before AMI snapshot
echo "Cleaning up before AMI creation..."
rm -rf /var/log/{wtmp,btmp,secure,messages} /root/.bash_history
truncate -s 0 /var/log/lastlog
history -c

echo "Bootstrap complete. Rebooting..."
reboot
