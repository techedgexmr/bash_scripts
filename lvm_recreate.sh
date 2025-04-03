#!/bin/bash
set -e

VG_NAME="vg_stig"
DISK="/dev/nvme1n1"

# Ensure the disk is available
while [[ ! -b $DISK ]]; do
    echo "Waiting for disk $DISK to be available..."
    sleep 5
done

# Check if the disk already has partitions
if lsblk -no FSTYPE $DISK | grep -qv '^$'; then
    echo "Detected existing partitions on $DISK:"
    lsblk $DISK
    echo "Checking for LVM..."
    
    if pvs $DISK &>/dev/null; then
        echo "Disk $DISK is already an LVM physical volume. Continuing..."
    else
        echo "Disk $DISK has non-LVM partitions and will be converted."
        echo "WARNING: This will erase all existing data!"
        sleep 5  # Give some time before proceeding

        # Unmount existing partitions
        for PART in $(lsblk -ln -o MOUNTPOINT $DISK | grep -v '^$'); do
            echo "Unmounting $PART..."
            umount "$PART" || true
        done

        # Remove partitions
        echo "Wiping existing partitions on $DISK..."
        wipefs -a $DISK
        sgdisk --zap-all $DISK

        # Create LVM structure
        echo "Creating LVM setup..."
        pvcreate $DISK
        vgcreate $VG_NAME $DISK
    fi
else
    echo "No existing partitions found on $DISK. Proceeding with LVM setup..."
    wipefs -a $DISK
    pvcreate $DISK
    vgcreate $VG_NAME $DISK
fi

# Function to create a logical volume if it does not exist
create_lv() {
    LV_NAME=$1
    SIZE=$2
    if ! lvdisplay /dev/$VG_NAME/$LV_NAME &>/dev/null; then
        echo "Creating logical volume $LV_NAME..."
        lvcreate -L $SIZE -n $LV_NAME $VG_NAME
    else
        echo "Logical volume $LV_NAME already exists."
    fi
}

# Create required STIG-compliant partitions
create_lv lv_var 10G
create_lv lv_var_log 10G
create_lv lv_var_log_audit 10G
create_lv lv_home 10G
create_lv lv_tmp 10G
create_lv lv_opt 10G
create_lv lv_swap 8G

# Function to format if the filesystem is not already created
format_fs() {
    LV_NAME=$1
    MOUNT_POINT=$2
    FS_TYPE="xfs"

    if ! blkid /dev/$VG_NAME/$LV_NAME &>/dev/null; then
        echo "Formatting /dev/$VG_NAME/$LV_NAME with $FS_TYPE..."
        mkfs.$FS_TYPE /dev/$VG_NAME/$LV_NAME
    else
        echo "/dev/$VG_NAME/$LV_NAME already has a filesystem. Skipping format."
    fi

    mkdir -p $MOUNT_POINT
    mount /dev/$VG_NAME/$LV_NAME $MOUNT_POINT
}

# Format and mount filesystems
format_fs lv_var /var
format_fs lv_var_log /var/log
format_fs lv_var_log_audit /var/log/audit
format_fs lv_home /home

# Ensure the new /home volume is mounted temporarily for data transfer
mkdir -p /mnt/lv_home
mount /dev/$VG_NAME/lv_home /mnt/lv_home

# Preserve old /home content, including hidden files like .ssh
echo "Copying existing /home content..."
rsync -avxH --progress --stats /home/ /mnt/lv_home/

# Ensure the ec2-user directory and SSH keys are copied
mkdir -p /mnt/lv_home/ec2-user
rsync -avxH --progress --stats /home/ec2-user/ /mnt/lv_home/ec2-user/
chown -R ec2-user:ec2-user /mnt/lv_home/ec2-user
chmod 700 /mnt/lv_home/ec2-user/.ssh
chmod 600 /mnt/lv_home/ec2-user/.ssh/authorized_keys

# Unmount the temporary mount and mount it properly as /home
umount /mnt/lv_home
mount /dev/$VG_NAME/lv_home /home

# Handle swap separately
if ! swapon --show | grep -q "/dev/$VG_NAME/lv_swap"; then
    echo "Setting up swap..."
    mkswap /dev/$VG_NAME/lv_swap
    swapon /dev/$VG_NAME/lv_swap
else
    echo "Swap already enabled."
fi

# Ensure entries exist in fstab
grep -q "/dev/mapper/${VG_NAME}-lv_var" /etc/fstab || echo "/dev/mapper/${VG_NAME}-lv_var /var xfs defaults,nodev 0 0" >> /etc/fstab
grep -q "/dev/mapper/${VG_NAME}-lv_var_log" /etc/fstab || echo "/dev/mapper/${VG_NAME}-lv_var_log /var/log xfs defaults,nodev 0 0" >> /etc/fstab
grep -q "/dev/mapper/${VG_NAME}-lv_var_log_audit" /etc/fstab || echo "/dev/mapper/${VG_NAME}-lv_var_log_audit /var/log/audit xfs defaults,nodev 0 0" >> /etc/fstab
grep -q "/dev/mapper/${VG_NAME}-lv_home" /etc/fstab || echo "/dev/mapper/${VG_NAME}-lv_home /home xfs defaults,nodev 0 0" >> /etc/fstab
grep -q "/dev/mapper/${VG_NAME}-lv_tmp" /etc/fstab || echo "/dev/mapper/${VG_NAME}-lv_tmp /tmp xfs defaults,nodev,noexec,nosuid 0 0" >> /etc/fstab
grep -q "/dev/mapper/${VG_NAME}-lv_opt" /etc/fstab || echo "/dev/mapper/${VG_NAME}-lv_opt /opt xfs defaults,nodev 0 0" >> /etc/fstab
grep -q "/dev/mapper/${VG_NAME}-lv_swap" /etc/fstab || echo "/dev/mapper/${VG_NAME}-lv_swap swap swap defaults 0 0" >> /etc/fstab

# Apply SELinux labels
restorecon -Rv /var /var/log /var/log/audit /home /tmp /opt

echo "Partitioning and LVM conversion complete."
