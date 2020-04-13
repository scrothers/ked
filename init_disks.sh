#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Variables for the script.
MOUNT_DIRECTORY=${MOUNT_DIRECTORY:-"/ephemeral"}
NVME_DISKS=($(/usr/sbin/nvme list | /usr/bin/grep "Amazon EC2 NVMe Instance Storage" | /usr/bin/awk '{print $1}'))
NVME_DISK_COUNT=${#NVME_DISKS[@]}

# Mount the disk to the local system.
function mount_block_device {
  local BLOCK_DEVICE=$1
  local UUID=$(blkid -s UUID -o value ${BLOCK_DEVICE})
  local UUID_STATUS=$?

  if test ${UUID_STATUS} -eq 0; then
    MOUNT_DESTINATION="${MOUNT_DIRECTORY}/${UUID}"
    echo "==> Mounting the device ${BLOCK_DEVICE} to ${MOUNT_DESTINATION}"
    /usr/bin/mount \
      -o defaults,noatime,discard,nobarrier \
      ${BLOCK_DEVICE} \
      ${MOUNT_DESTINATION}

    return $?
  else
  	echo "==> A device was attempted to be mounted, but doesn't appear to have a filesystem."
    echo "==> Exiting with error."
    exit 1
  fi
}

# Format a single block device.
function format_block_device {
  local BLOCK_DEVICE=$1
  local UUID=$(blkid -s UUID -o value ${BLOCK_DEVICE})
  local UUID_STATUS=$?

  if test ${UUID_STATUS} -eq 0; then
    echo "==> Filesystem already exists on the disk, continuing."

    return 0
  else
    echo "==> Creating filesystem on ${BLOCK_DEVICE} of type ext4."
    /usr/sbin/mkfs.ext4 \
      -m 0 \
      -b 4096 \
      ${BLOCK_DEVICE}

    return $?
  fi
}

# Format a RAID device.
function format_raid_device {
  local UUID=$(blkid -s UUID -o value ${BLOCK_DEVICE})
  local UUID_STATUS=$?

  if test ${UUID_STATUS} -eq 0; then
    echo "==> Filesystem already exists on the raid device, continuing."

    return 0
  else
    echo "==> Creating filesystem on /dev/md0 of type ext4."
    /usr/sbin/mkfs.ext4 \
      -m 0 \
      -b 4096 \
      -E stride=128,stripe-width=${NVME_DISK_COUNT} \
      /dev/md0

    return $?
  fi
}

# Create a RAID device from many disks.
function create_raid_device {
  if [ -b "/dev/md0" ]; then
    echo "==> RAID device already exists, continuing."

    return 0

  else
    echo "==> Creating RAID device..."
    /usr/sbin/mdadm \
      --create \
      --verbose \
      /dev/md0 \
      --level=0 \
      -c 512 \
      --raid-devices=${NVME_DISK_COUNT} \
      ${NVME_DISKS[*]}

    while [ -n "$(/usr/sbin/mdadm --detail /dev/md0 | /usr/bin/grep -ioE 'State :.*resyncing')" ]; do
      echo "==> RAID device is currently syncing..."
      sleep 1
    done

    return 0
  fi
}

# Perform provisioning based on nvme device count
case $NVME_DISK_COUNT in
  # No NVME disks are present, so sleep forever to prevent CrashLoopBackoff.
  "0")
    echo "==> No volumes to configure, sleeping forever."
    ;;

  # Single NVME disk is present,
  "1")
    echo "==> Detected a single NVME volume, preparing the disk."
    format_block_device ${NVME_DISKS[0]}
    mount_block_device ${NVME_DISKS[0]}
    ;;

  # Multiple NVME disks are present.
  *)
    echo "==> Detected multiple NVME volumes, preparing all the disks."
    create_raid_device
    format_raid_device
    mount_block_device "/dev/md0"
    ;;
esac

echo "==> Utility completed, sleeping for infinity now."
sleep infinity
