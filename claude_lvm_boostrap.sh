#!/bin/bash
# Enhanced LVM Setup Script for AWS AMI with STIG compliance
# This script should be run during initial system setup (userdata)

# Enable logging
exec > >(tee /var/log/lvm-setup.log) 2>&1
echo "Starting LVM setup at $(date)"

# Better error handling
set -e
trap 'echo "Error occurred at line $LINENO. Exiting."; exit 1' ERR

# Configuration
VG_NAME="vg_stig"
DISK="/dev/nvme1n1"
BACKUP_DIR="/tmp/data_backup"

# Ensure we're running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

# Check if we're running during first boot or system setup
if [ -f /var/lib/cloud/instance/boot-finished ]; then
    echo "WARNING: This script appears to be running on an already initialized system."
    echo "For safety, this script should ideally run during initial instance launch."
    echo "Continuing anyway, but be aware of potential service disruption."
    sleep 5
fi

# Ensure the disk is available with timeout
MAX_WAIT=60
WAIT_TIME=0
while [[ ! -b $DISK && $WAIT_TIME -lt $MAX_WAIT ]]; do
    echo "Waiting for disk $DISK to be available... ($WAIT_TIME/$MAX_WAIT seconds)"
    sleep 5
    WAIT_TIME=$((WAIT_TIME + 5))
done

if [[ ! -b $DISK ]]; then
    echo "ERROR: Disk $DISK not available after $MAX_WAIT seconds. Falling back to instance store if available."
    # Try to find an alternative disk
    ALT_DISK=$(lsblk -dpno NAME | grep -v "$(df -h / | awk 'NR==2 {print $1}' | sed 's/[0-9]*$//g')" | head -1)
    if [[ -n $ALT_DISK ]]; then
        echo "Found alternative disk: $ALT_DISK"
        DISK=$ALT_DISK
    else
        echo "No alternative disk found. Exiting."
        exit 1
    fi
fi

echo "Using disk: $DISK"

# Check if the disk already has partitions
if lsblk -no FSTYPE $DISK | grep -qv '^$'; then
    echo "Detected existing partitions on $DISK:"
    lsblk $DISK
    echo "Checking for LVM..."
    
    # If it's already an LVM physical volume, just continue setup
    if pvs $DISK &>/dev/null; then
        echo "Disk $DISK is already an LVM physical volume. Continuing..."
    else
        echo "Disk $DISK has non-LVM partitions."
        echo "WARNING: Automated conversion to LVM requires wiping the disk!"
        echo "Continuing with disk wipe as this is an automated AMI build..."
        
        # Wipe the disk forcefully since this is an AMI build
        wipefs -af $DISK
        pvcreate -ff $DISK
        vgcreate $VG_NAME $DISK || {
            echo "Failed to create volume group. Attempting to f
