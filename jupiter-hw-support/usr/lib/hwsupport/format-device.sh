#!/bin/bash

set -e

source /etc/default/steamos-btrfs

# If the script is not run from a tty then send a copy of stdout and
# stderr to the journal. In this case stderr is also redirected to stdout.
if ! tty -s; then
    exec 8>&1
    exec &> >(tee /dev/fd/8 | logger -t steamos-format-device)
fi

RUN_VALIDATION=1
EXTENDED_OPTIONS="nodiscard"
# default owner for the new filesystem
OWNER="1000:1000"
EXTRA_MKFS_ARGS=()
# Increase the version number every time a new option is added
VERSION_NUMBER=1

OPTS=$(getopt -l version,force,skip-validation,full,quick,owner:,device:,label: -n format-device.sh -- "" "$@")

eval set -- "$OPTS"

while true; do
    case "$1" in
        --version) echo $VERSION_NUMBER; exit 0 ;;
        --force) RUN_VALIDATION=0; shift ;;
        --skip-validation) RUN_VALIDATION=0; shift ;;
        --full) EXTENDED_OPTIONS="discard"; shift ;;
        --quick) EXTENDED_OPTIONS="nodiscard"; shift ;;
        --owner) OWNER="$2"; shift 2;;
        --label) EXTRA_MKFS_ARGS+=(-L "$2"); shift 2 ;;
        --device) STORAGE_DEVICE="$2"; shift 2 ;;
        --) shift; break ;;
    esac
done

if [[ "$#" -gt 0 ]]; then
    echo "Unknown option $1"; exit 22
fi

EXTENDED_OPTIONS="$EXTENDED_OPTIONS,root_owner=$OWNER"

# We only support SD/MMC and USB mass-storage devices
case "$STORAGE_DEVICE" in
    "")
        echo "Usage: $(basename $0) [--version] [--force] [--skip-validation] [--full] [--quick] [--owner <uid>:<gid>] [--label <label>] --device <device>"
        exit 19 #ENODEV
        ;;
    /dev/mmcblk?)
        STORAGE_PARTITION="${STORAGE_DEVICE}p1"
        ;;
    /dev/sd?)
        STORAGE_PARTITION="${STORAGE_DEVICE}1"
        ;;
    *)
        echo "Unknown or unsupported device: $STORAGE_DEVICE"
        exit 19 #ENODEV
esac

if [[ ! -e "$STORAGE_DEVICE" ]]; then
    exit 19 #ENODEV
fi

STORAGE_PARTBASE="${STORAGE_PARTITION#/dev/}"

systemctl stop steamos-automount@"$STORAGE_PARTBASE".service

# lock file prevents the mount service from re-mounting as it gets triggered by udev rules.
#
# NOTE: Uses a shared lock filename between this and the auto-mount script to ensure we're not double-triggering nor
# automounting while formatting or vice-versa.
MOUNT_LOCK="/var/run/jupiter-automount-${STORAGE_PARTBASE//\/_}.lock"
MOUNT_LOCK_FD=9
exec 9<>"$MOUNT_LOCK"

if ! flock -n "$MOUNT_LOCK_FD"; then
  echo "Failed to obtain lock $MOUNT_LOCK, failing"
  exit 53
fi

# If any partitions on the device are mounted, unmount them before continuing
# to prevent problems later
lsblk -n "$STORAGE_DEVICE" -o MOUNTPOINTS | awk NF | sort -u | while read m; do
    if ! umount "$m"; then
        echo "Failed to unmount filesystem: $m"
        exit 32 # EPIPE
    fi
done

# Test the sdcard
# Some fake cards advertise a larger size than their actual capacity,
# which can result in data loss or other unexpected behaviour. It is
# best to try to detect these issues as early as possible.
if [[ "$RUN_VALIDATION" != "0" ]]; then
    echo "stage=testing"
    if ! f3probe --destructive "$STORAGE_DEVICE"; then
        # Fake sdcards tend to only behave correctly when formatted as exfat
        # The tricks they try to pull fall apart with any other filesystem and
        # it renders the card unusuable.
        #
        # Here we restore the card to exfat so that it can be used with other devices.
        # It won't be usable with the deck, and usage of the card will most likely
        # result in data loss. We return a special error code so we can surface
        # a specific error to the user.
        echo "stage=rescuing"
        echo "Bad sdcard - rescuing"
        for i in {1..3}; do # Give this a couple of tries since it fails sometimes
            echo "Create partition table: $i"
            dd if=/dev/zero of="$STORAGE_DEVICE" bs=512 count=1024 # see comment in similar statement below
            if ! parted --script "$STORAGE_DEVICE" mklabel msdos mkpart primary 0% 100% ; then
                echo "Failed to create partition table: $i"
                continue # try again
            fi

            echo "Create exfat filesystem: $i"
            sync
            if ! mkfs.exfat "$STORAGE_PARTITION"; then
                echo "Failed to exfat filesystem: $i"
                continue # try again
            fi

            echo "Successfully restored device"
            break
        done

        # Return a specific error code so the UI can warn the user about this bad device
        exit 14 # EFAULT
    fi
fi

# Clear out the garbage bits generated by f3probe from the partition table sectors
# Otherwise parted may think we have existing partitions in a bogus state
dd if=/dev/zero of="$STORAGE_DEVICE" bs=512 count=1024

# Format as EXT4 with casefolding for proton compatibility
echo "stage=formatting"
sync
parted --script "$STORAGE_DEVICE" mklabel gpt mkpart primary 0% 100%
sync
#### SteamOS Btrfs Begin ####
if [[ -f /etc/default/steamos-btrfs ]]; then
    source /etc/default/steamos-btrfs
fi
if [[ "$STEAMOS_BTRFS_SDCARD_FORMAT_FS" == "btrfs" ]]; then
    mkfs.btrfs ${STEAMOS_BTRFS_SDCARD_BTRFS_FORMAT_OPTS:--f -K} "$STORAGE_PARTITION"
    MOUNT_DIR="/var/run/sdcard-mount"
    mkdir -p "$MOUNT_DIR"
    mount -o "${STEAMOS_BTRFS_SDCARD_BTRFS_MOUNT_OPTS:-rw,noatime,lazytime,compress-force=zstd,space_cache=v2,autodefrag,ssd_spread}" "$STORAGE_PARTITION" "$MOUNT_DIR"
    btrfs subvolume create "$MOUNT_DIR/${STEAMOS_BTRFS_SDCARD_BTRFS_MOUNT_SUBVOL:-@}"
    btrfs subvolume set-default "$MOUNT_DIR/${STEAMOS_BTRFS_SDCARD_BTRFS_MOUNT_SUBVOL:-@}"
    umount -l "$MOUNT_DIR"
    rmdir "$MOUNT_DIR"
elif [[ "$STEAMOS_BTRFS_SDCARD_FORMAT_FS" == "f2fs" ]]; then
    mkfs.f2fs ${STEAMOS_BTRFS_SDCARD_F2FS_FORMAT_OPTS:--O encrypt,extra_attr,inode_checksum,sb_checksum,casefold,compression -C utf8 -f -t 0} "$STORAGE_PARTITION"
elif [[ "$STEAMOS_BTRFS_SDCARD_FORMAT_FS" == "fat" ]]; then
    mkfs.vfat ${STEAMOS_BTRFS_SDCARD_FAT_FORMAT_OPTS:--F 32 -I} "$STORAGE_PARTITION"
elif [[ "$STEAMOS_BTRFS_SDCARD_FORMAT_FS" == "exfat" ]]; then
    mkfs.exfat ${STEAMOS_BTRFS_SDCARD_EXFAT_FORMAT_OPTS:---pack-bitmap} "$STORAGE_PARTITION"
elif [[ "$STEAMOS_BTRFS_SDCARD_FORMAT_FS" == "ntfs" ]]; then
    mkfs.ntfs ${STEAMOS_BTRFS_SDCARD_NTFS_FORMAT_OPTS:--f -F} "$STORAGE_PARTITION"
else
    mkfs.ext4 -E "$EXTENDED_OPTIONS" ${STEAMOS_BTRFS_SDCARD_EXT4_FORMAT_OPTS:--m 0 -O casefold -F} "$STORAGE_PARTITION"
fi
#### SteamOS Btrfs End ####
sync
udevadm settle

# trigger the mount service
flock -u "$MOUNT_LOCK_FD"
if ! systemctl start steamos-automount@"$STORAGE_PARTBASE".service; then
    echo "Failed to start mount service"
    journalctl --no-pager --boot=0 -u steamos-automount@"$STORAGE_PARTBASE".service
    exit 5
fi

exit 0
