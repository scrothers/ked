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

# Clean up the old folders so they don't confuse local storage.
function clean_stale_mount_paths {
  write_console "Cleaning old mount paths"
  /usr/bin/find ${MOUNT_DIRECTORY}/* -type d -delete
}

# Mount the disk to the local system.
function mount_block_device {
  if test -f "${MOUNT_DIRECTORY}/filesystem.uuid"; then
    clean_stale_mount_paths
    local UUID=$(cat ${MOUNT_DIRECTORY}/filesystem.uuid)
    local MOUNT_DESTINATION="${MOUNT_DIRECTORY}/${UUID}"

    write_console "Creating mount destination for the filesystem"
    /usr/bin/mkdir -p ${MOUNT_DESTINATION}
    write_console "Mounting filesystem with UUID ${UUID} to ${MOUNT_DESTINATION}"
    /usr/bin/mount \
      -o defaults,noatime,discard,nobarrier \
      --uuid ${UUID} \
      ${MOUNT_DESTINATION} > ${MOUNT_DIRECTORY}/filesystem_mount.log 2>&1

    if test $? -eq 0; then
      write_console "Filesystem successfully mounted"
    else
      write_console "Filesystem mount error"
      if [ $(/usr/bin/grep -c "can't find UUID" ${MOUNT_DIRECTORY}/filesystem_mount.log) -eq 1 ]; then
          write_console "Filesystem on disk is missing, recreating..."
          remove_filesystem_uuid
          run_process
      else
          write_console "An unknown filesystem error occured"
          write_console "Please check the ${MOUNT_DIRECTORY}/filesystem_mount.log file for more details"
          write_console "To recreate filesystem, delete ${MOUNT_DIRECTORY}/filesystem.uuid file"
          exit 1
      fi
    fi
  else
    write_console "Unable to locate a UUID at ${MOUNT_DIRECTORY}/filesystem.uuid"
    write_console "Recreating the filesystem on disk"
  fi
}

# Store the filesystem UUID to the system.
function store_filesystem_uuid {
  local UUID=$1

  echo ${UUID} > ${MOUNT_DIRECTORY}/filesystem.uuid
  write_console "Stored filesystem UUID ${UUID} to ${MOUNT_DIRECTORY}/filesystem.uuid"
}

# Remove the filesystem UUID configuration file to free the script.
function remove_filesystem_uuid {
  if test -f "${MOUNT_DIRECTORY}/filesystem.uuid"; then
    write_console "Removing the old filesystem UUID configuration"
    /usr/bin/rm -f ${MOUNT_DIRECTORY}/filesystem.uuid
  else
    write_console "No existing filesystem UUID configuration exists"
  fi
}

# Format a single block device.
function format_block_device {
  local BLOCK_DEVICE=$1

  /usr/sbin/blkid -s UUID -o value ${BLOCK_DEVICE} > /dev/null 2> /dev/null
  if test $? -eq 0; then
    write_console "Filesystem already exists on the disk, continuing"

    return 0
  else
    write_console "Creating filesystem on ${BLOCK_DEVICE} of type ext4"
    remove_filesystem_uuid
    /usr/sbin/wipefs -a ${BLOCK_DEVICE}
    /usr/sbin/mkfs.ext4 \
      -m 0 \
      -b 4096 \
      ${BLOCK_DEVICE} > ${MOUNT_DIRECTORY}/filesystem_create.log 2>&1

    if test $? -eq 0; then
      write_console "Disk format was successful"
      write_console "Disk format log located at: ${MOUNT_DIRECTORY}/filesystem_create.log"
    else
      write_console "Disk format failed"
      write_console "Disk format log located at: ${MOUNT_DIRECTORY}/filesystem_create.log"
      exit 1
    fi

    FILESYSTEM_ID=$(/sbin/blkid -s UUID -o value ${BLOCK_DEVICE})
    store_filesystem_uuid ${FILESYSTEM_ID}
  fi
}

# Format a RAID device.
function format_raid_device {
  local STRIPE_WIDTH=$(/bin/expr $NVME_DISK_COUNT \* 128 || true)

  /usr/sbin/blkid -s UUID -o value /dev/md0 2>&1 > /dev/null
  if test $? -eq 0; then
    write_console "Filesystem already exists on the raid device, continuing"
    remove_filesystem_uuid
    FILESYSTEM_ID=$(/sbin/blkid -s UUID -o value /dev/md0)
    store_filesystem_uuid ${FILESYSTEM_ID}

    return 0
  else
    write_console "Creating filesystem on /dev/md0 of type ext4"
    remove_filesystem_uuid
    /usr/sbin/wipefs -a /dev/md0
    /usr/sbin/mkfs.ext4 \
      -m 0 \
      -b 4096 \
      -E stride=128,stripe-width=${STRIPE_WIDTH} \
      /dev/md0 > ${MOUNT_DIRECTORY}/filesystem_create.log 2>&1

    if test $? -eq 0; then
      write_console "Disk format was successful"
      write_console "Disk format log located at: ${MOUNT_DIRECTORY}/filesystem_create.log"
    else
      write_console "Disk format failed"
      write_console "Disk format log located at: ${MOUNT_DIRECTORY}/filesystem_create.log"
      exit 1
    fi

    FILESYSTEM_ID=$(/sbin/blkid -s UUID -o value /dev/md0)
    store_filesystem_uuid ${FILESYSTEM_ID}
  fi
}

# Store the RAID device UUID for a specific RAID device.
function store_raid_device_uuid {
  local RAID_DEVICE=$1

  RAID_UUID=$(/usr/sbin/mdadm --detail ${RAID_DEVICE} | /usr/bin/grep UUID | /usr/bin/awk '{print $3}')
  echo ${RAID_UUID} > ${MOUNT_DIRECTORY}/raid_device.uuid
  write_console "Stored the RAID UUID ${RAID_UUID} at ${MOUNT_DIRECTORY}/raid_device.uuid"
}

# Remove the old RAID UUID configuration to free the script.
function remove_raid_device_uuid {
  if test -f "${MOUNT_DIRECTORY}/raid_device.uuid"; then
    write_console "Removing the old RAID UUID configuration"
    /usr/bin/rm -f ${MOUNT_DIRECTORY}/raid_device.uuid
  else
    write_console "No existing RAID UUID configuration exists"
  fi
}

# Wipe the superblock information from the RAID members.
function wipe_raid_members {
  write_console "Wiping the RAID member disks..."
  for DISK in "${NVME_DISKS[@]}"; do
    write_console " Wiping ${DISK}..."
    /usr/sbin/wipefs -a ${DISK} > /dev/null 2>&1
  done
}

# Create a RAID device from many disks.
function create_raid_device {
  local RAID_UUID_CONFIG="${MOUNT_DIRECTORY}/raid_device.uuid"
  write_console "Staring the RAID creation process"
  write_console "Searching for RAID configuration at ${RAID_UUID_CONFIG}"

  if test -f "${RAID_UUID_CONFIG}"; then
    if test -b /dev/md0; then
      write_console "RAID device is already present."
    else
      local UUID=$(cat ${MOUNT_DIRECTORY}/raid_device.uuid)
      write_console "Located RAID configuration UUID"
      write_console "Probing for RAID block device ${UUID}"
      if /usr/sbin/mdadm --assemble /dev/md0 --uuid ${UUID} > ${MOUNT_DIRECTORY}/raid_assemble.log 2> /dev/null; then
        write_console "Restored RAID device with UUID ${UUID} to /dev/md0"
      else
        write_console "RAID UUID stored on system, but unable to create device"
        remove_raid_device_uuid
        create_raid_device

        return $?
      fi
    fi

    return 0
  else
    write_console "RAID configuration UUID file is not present"
    if test -b /dev/md0; then
      store_raid_device_uuid /dev/md0
      if /usr/sbin/blkid -s UUID -o value /dev/md0 2>&1 > /dev/null; then
        write_console "RAID exists, and appears to have a filesystem"
      else
        write_console "RAID exists, and does not appear to have a filesystem"
      fi

      return 0
    else
      wipe_raid_members
      write_console "Creating RAID device..."
      remove_filesystem_uuid
      remove_raid_device_uuid
      /usr/bin/yes no | /usr/sbin/mdadm \
        --create \
        --verbose \
        /dev/md0 \
        --level=0 \
        -c 512 \
        --raid-devices=${NVME_DISK_COUNT} \
        ${NVME_DISKS[*]} > ${MOUNT_DIRECTORY}/raid_create.log 2>&1
      write_console "RAID creation command completed"

      # Loop over the sync to make sure that the device is fully created.
      while [ -n "$(/usr/sbin/mdadm --detail /dev/md0 | /usr/bin/grep -ioE 'State :.*resyncing')" ]; do
        write_console "RAID device is currently syncing..."
        sleep 1
      done

      # Wait for the devices to settle on some systems.
      write_console "Waiting for devices to settle"
      sleep 3

      # If the RAID device has appeared, we have successfully created the RAID.
      if test -b /dev/md0; then
        write_console "RAID device created"
        store_raid_device_uuid /dev/md0
      else
        write_console "RAID device failed to create, log at ${MOUNT_DIRECTORY}/raid_create.log"
        exit 1
      fi

      return 0
    fi
  fi
}

# Run the process to create a mount point.
function run_process {
  # Perform provisioning based on nvme device count
  case $NVME_DISK_COUNT in
    # No NVME disks are present, so sleep forever to prevent CrashLoopBackoff.
    "0")
      write_console "No volumes to configure, sleeping forever"
      ;;

    # Single NVME disk is present,
    "1")
      write_console "Detected a single NVME volume, preparing the disk"
      write_console " Disk: ${NVME_DISKS[0]}"
      format_block_device ${NVME_DISKS[0]}
      mount_block_device
      ;;

    # Multiple NVME disks are present.
    *)
      write_console "Detected multiple NVME volumes, preparing all the disks"
      for DISK in "${NVME_DISKS[@]}"; do
        write_console " Disk: ${DISK}"
      done
      create_raid_device
      format_raid_device
      mount_block_device
      ;;
  esac
}

if test -f "${MOUNT_DIRECTORY}/filesystem.uuid"; then
  STORED_UUID=$(cat ${MOUNT_DIRECTORY}/filesystem.uuid)
  if [ $(/usr/bin/mount | /usr/bin/grep -c ${STORED_UUID}) -eq 1 ]; then
    write_console "File system already mounted at ${MOUNT_DIRECTORY}/${STORED_UUID}"
  else
    write_console "Detected a filesystem identifier, attempting to mount"
    mount_block_device
  fi
elif test -f "${MOUNT_DIRECTORY}/raid_device.uuid"; then
  write_console "Detected a RAID device created, attempting to format"
  format_raid_device
  mount_block_device
else
  write_console "No configuration detected, attempting to create"
  run_process
fi

write_console "Utility completed, sleeping for infinity now"
sleep infinity
