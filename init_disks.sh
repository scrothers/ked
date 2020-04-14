#!/bin/bash

set -o nounset
set -o pipefail

# Variables for the script.
MOUNT_DIRECTORY=${MOUNT_DIRECTORY:-"/ephemeral"}
NVME_DISKS=($(/usr/sbin/nvme list | /usr/bin/grep "Amazon EC2 NVMe Instance Storage" | /usr/bin/awk '{print $1}'))
NVME_DISK_COUNT=${#NVME_DISKS[@]}

# Console printing method for when we're aggregating logs.
function write_console {
  printf "%-30s ==> %s\r\n" "[${HOSTNAME}]" "${*}"
}

# Mount the disk to the local system.
function mount_block_device {
  local BLOCK_DEVICE=$1
  local UUID=$(blkid -s UUID -o value ${BLOCK_DEVICE})
  local UUID_STATUS=$?

  if test ${UUID_STATUS} -eq 0; then
    MOUNT_DESTINATION="${MOUNT_DIRECTORY}/${UUID}"
    write_console "Mounting the device ${BLOCK_DEVICE} to ${MOUNT_DESTINATION}"
    /usr/bin/mkdir -p ${MOUNT_DESTINATION}
    /usr/bin/mount \
      -o defaults,noatime,discard,nobarrier \
      ${BLOCK_DEVICE} \
      ${MOUNT_DESTINATION}

    return $?
  else
  	write_console "A device was attempted to be mounted, but doesn't appear to have a filesystem."
    write_console "Exiting with error."
    exit 1
  fi
}

# Format a single block device.
function format_block_device {
  local BLOCK_DEVICE=$1

  /usr/sbin/blkid -s UUID -o value ${BLOCK_DEVICE} 2>&1 > /dev/null
  if test $? -eq 0; then
    write_console "Filesystem already exists on the disk, continuing."

    return 0
  else
    write_console "Creating filesystem on ${BLOCK_DEVICE} of type ext4."
    /usr/sbin/mkfs.ext4 \
      -m 0 \
      -b 4096 \
      ${BLOCK_DEVICE}

    return $?
  fi
}

# Format a RAID device.
function format_raid_device {
  /usr/sbin/blkid -s UUID -o value /dev/md0 2>&1 > /dev/null
  if test $? -eq 0; then
    write_console "Filesystem already exists on the raid device, continuing."

    return 0
  else
    write_console "Creating filesystem on /dev/md0 of type ext4."
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
  write_console "Probing for RAID arrays that already exist."
  /usr/sbin/mdadm --assemble --scan

  if [ -b "/dev/md0" ]; then
    /usr/sbin/blkid -s UUID -o value /dev/md0 2>&1 > /dev/null
    if test $? -eq 0; then
      write_console "RAID exists, and appears to have a filesystem."
    else
      write_console "RAID exists, and does not appear to have a filesystem."
    fi

    return 0

  else
    write_console "Creating RAID device..."
    /usr/bin/yes no | /usr/sbin/mdadm \
      --create \
      --verbose \
      /dev/md0 \
      --level=0 \
      -c 512 \
      --raid-devices=${NVME_DISK_COUNT} \
      ${NVME_DISKS[*]}

    while [ -n "$(/usr/sbin/mdadm --detail /dev/md0 | /usr/bin/grep -ioE 'State :.*resyncing')" ]; do
      write_console "RAID device is currently syncing..."
      sleep 1
    done

    return 0
  fi
}

# Perform provisioning based on nvme device count
case $NVME_DISK_COUNT in
  # No NVME disks are present, so sleep forever to prevent CrashLoopBackoff.
  "0")
    write_console "No volumes to configure, sleeping forever."
    ;;

  # Single NVME disk is present,
  "1")
    write_console "Detected a single NVME volume, preparing the disk."
    format_block_device ${NVME_DISKS[0]}
    mount_block_device ${NVME_DISKS[0]}
    ;;

  # Multiple NVME disks are present.
  *)
    write_console "Detected multiple NVME volumes, preparing all the disks."
    create_raid_device
    format_raid_device
    mount_block_device "/dev/md0"
    ;;
esac

write_console "Utility completed, sleeping for infinity now."
sleep infinity
