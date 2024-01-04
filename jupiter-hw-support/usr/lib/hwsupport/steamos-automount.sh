#!/bin/bash

set -euo pipefail

# Originally from https://serverfault.com/a/767079

# This script is called from our systemd unit file to mount or unmount
# a USB drive.

usage()
{
    echo "Usage: $0 {add|remove} device_name (e.g. sdb1)"
    exit 1
}

if [[ $# -ne 2 ]]; then
    usage
fi

# SteamOS Btrfs: lock execution to script due to udisks2 mount options
if [[ "${FLOCKER:-}" != "$0" ]] ; then exec env FLOCKER="$0" flock -e -w 20 "$0" "$0" "$@" ; fi

ACTION=$1
DEVBASE=$2
DEVICE="/dev/${DEVBASE}"

# Shared between this and the auto-mount script to ensure we're not double-triggering nor automounting while formatting
# or vice-versa.
MOUNT_LOCK="/var/run/jupiter-automount-${DEVBASE//\/_}.lock"

# Obtain lock
exec 9<>"$MOUNT_LOCK"
if ! flock -n 9; then
    echo "$MOUNT_LOCK is active: ignoring action $ACTION"
    # Do not return a success exit code: it could end up putting the service in 'started' state without doing the mount
    # work (further start commands will be ignored after that)
    exit 1
fi

# Wait N seconds for steam
wait_steam()
{
    local i=0
    local wait=$1
    echo "Waiting up to $wait seconds for steam to load"
    while ! pgrep -x steamwebhelper &>/dev/null && (( i++ < wait )); do
        sleep 1
    done
}

send_steam_url()
{
  local command="$1"
  local arg="$2"
  local encoded=$(urlencode "$arg")
  if pgrep -x "steam" > /dev/null; then
      # TODO use -ifrunning and check return value - if there was a steam process and it returns -1, the message wasn't sent
      # need to retry until either steam process is gone or -ifrunning returns 0, or timeout i guess
      systemd-run --uid=1000 --collect --wait sh -c "/usr/bin/steam steam://${command}/${encoded@Q}"
      echo "Sent URL to steam: steam://${command}/${arg} (steam://${command}/${encoded})"
  else
      echo "Could not send steam URL steam://${command}/${arg} (steam://${command}/${encoded}) -- steam not running"
  fi
}

# From https://gist.github.com/HazCod/da9ec610c3d50ebff7dd5e7cac76de05
urlencode()
{
    [ -z "$1" ] || echo -n "$@" | hexdump -v -e '/1 "%02x"' | sed 's/\(..\)/%\1/g'
}

do_mount()
{
    declare -i ret
    # NOTE: these values are ABI, since they are sent to the Steam client
    readonly FSCK_ERROR=1
    readonly MOUNT_ERROR=2

    # Get info for this drive: $ID_FS_LABEL, and $ID_FS_TYPE
    dev_json=$(lsblk -o PATH,LABEL,FSTYPE --json -- "$DEVICE" | jq '.blockdevices[0]')
    ID_FS_LABEL=$(jq -r '.label | select(type == "string")' <<< "$dev_json")
    ID_FS_TYPE=$(jq -r '.fstype | select(type == "string")' <<< "$dev_json")
    FSTYPE_PREFIX=""

    #### SteamOS Btrfs Begin ####
    if [[ -f /etc/default/steamos-btrfs ]]; then
        source /etc/default/steamos-btrfs
    fi
    if [[ "${ID_FS_TYPE}" == "ext4" ]]; then
        UDISKS2_ALLOW='errors=remount-ro'
        OPTS="${STEAMOS_BTRFS_SDCARD_EXT4_MOUNT_OPTS:-rw,noatime,lazytime}"
        FSTYPE="ext4"
    elif [[ "${ID_FS_TYPE}" == "f2fs" ]]; then
        UDISKS2_ALLOW='discard,nodiscard,compress_algorithm,compress_log_size,compress_extension,alloc_mode'
        OPTS="${STEAMOS_BTRFS_SDCARD_F2FS_MOUNT_OPTS:-rw,noatime,lazytime,compress_algorithm=zstd,compress_chksum,atgc,gc_merge}"
        FSTYPE="f2fs"
        if [[ ! -f /etc/filesystems ]] || ! grep -q '\b'"${FSTYPE}"'\b' /etc/filesystems; then
            echo "${FSTYPE}" >> /etc/filesystems
        fi
    elif [[ "${ID_FS_TYPE}" == "btrfs" ]]; then
        UDISKS2_ALLOW='compress,compress-force,datacow,nodatacow,datasum,nodatasum,autodefrag,noautodefrag,degraded,device,discard,nodiscard,subvol,subvolid,space_cache'
        OPTS="${STEAMOS_BTRFS_SDCARD_BTRFS_MOUNT_OPTS:-rw,noatime,lazytime,compress-force=zstd,space_cache=v2,autodefrag,ssd_spread}"
        FSTYPE="btrfs"
        # check for main subvol
        mount_point_tmp="${MOUNT_LOCK%.*}.tmp"
        mkdir -p "${mount_point_tmp}"
        if /bin/mount -t btrfs -o ro "${DEVICE}" "${mount_point_tmp}"; then
            if [[ -d "${mount_point_tmp}/${STEAMOS_BTRFS_SDCARD_BTRFS_MOUNT_SUBVOL:-@}" ]] && \
                btrfs subvolume show "${mount_point_tmp}/${STEAMOS_BTRFS_SDCARD_BTRFS_MOUNT_SUBVOL:-@}" &>/dev/null; then
                OPTS+=",subvol=${STEAMOS_BTRFS_SDCARD_BTRFS_MOUNT_SUBVOL:-@}"
            fi
            /bin/umount -l "${mount_point_tmp}"
            rmdir "${mount_point_tmp}"
        fi
    elif [[ "${ID_FS_TYPE}" == "vfat" ]]; then
        UDISKS2_ALLOW='uid=$UID,gid=$GID,flush,utf8,shortname,umask,dmask,fmask,codepage,iocharset,usefree,showexec'
        OPTS="${STEAMOS_BTRFS_SDCARD_FAT_MOUNT_OPTS:-rw,noatime,lazytime,uid=1000,gid=1000,utf8=1}"
        FSTYPE="vfat"
    elif [[ "${ID_FS_TYPE}" == "exfat" ]]; then
        UDISKS2_ALLOW='uid=$UID,gid=$GID,dmask,errors,fmask,iocharset,namecase,umask'
        OPTS="${STEAMOS_BTRFS_SDCARD_EXFAT_MOUNT_OPTS:-rw,noatime,lazytime,uid=1000,gid=1000}"
        FSTYPE="exfat"
    elif [[ "${ID_FS_TYPE}" == "ntfs" ]]; then
        UDISKS2_ALLOW='uid=$UID,gid=$GID,umask,dmask,fmask,locale,norecover,ignore_case,windows_names,compression,nocompression,big_writes,nls,nohidden,sys_immutable,sparse,showmeta,prealloc'
        OPTS="${STEAMOS_BTRFS_SDCARD_NTFS_MOUNT_OPTS:-rw,noatime,lazytime,uid=1000,gid=1000,big_writes,umask=0022,ignore_case,windows_names}"
        FSTYPE="lowntfs-3g"
        FSTYPE_PREFIX="ntfs:"
        if [[ ! -f /etc/filesystems ]] || ! grep -q '\b'"${FSTYPE}"'\b' /etc/filesystems; then
            echo "${FSTYPE}" >> /etc/filesystems
        fi
    else
        echo "Error mounting ${DEVICE}: wrong fstype: ${ID_FS_TYPE} - ${dev_json}"
        exit 2
    fi
    udisks2_mount_options_conf='/etc/udisks2/mount_options.conf'
    mkdir -p "$(dirname "${udisks2_mount_options_conf}")"
    if [[ -f "${udisks2_mount_options_conf}" && ! -f "${udisks2_mount_options_conf}.orig" ]]; then
        mv -f "${udisks2_mount_options_conf}"{,.orig}
    fi
    echo -e "[defaults]\n${FSTYPE_PREFIX}${FSTYPE}_allow=${UDISKS2_ALLOW},${OPTS}" > "${udisks2_mount_options_conf}"
    trap 'rm -f "${udisks2_mount_options_conf}" ; [[ -f "${udisks2_mount_options_conf}.orig" ]] && mv -f "${udisks2_mount_options_conf}"{.orig,}' EXIT
    #### SteamOS Btrfs End ####

    # Prior to talking to udisks, we need all udev hooks (we were started by one) to finish, so we know it has knowledge
    # of the drive.  Our own rule starts us as a service with --no-block, so we can wait for rules to settle here
    # safely.
    if ! udevadm settle; then
      echo "Failed to wait for \`udevadm settle\`"
      exit 1
    fi

    # Try to repair the filesystem if it's known to have errors.
    # ret=0 means no errors, 1 means that errors were corrected.
    # In all other cases we try to mount the fs read-only and report an error.
    ret=0
    #### SteamOS Btrfs Begin ####
    if [[ "${ID_FS_TYPE}" == "ntfs" ]]; then
        ntfsfix "${DEVICE}" || ret=$?
    else
        fsck."${ID_FS_TYPE}" -y "${DEVICE}" || ret=$?
    fi
    #### SteamOS Btrfs End ####
    if (( ret != 0 && ret != 1 )); then
        send_steam_url "system/devicemountresult" "${DEVBASE}/${FSCK_ERROR}"
        echo "Error running fsck on ${DEVICE} (status = $ret)"
        OPTS+=",ro"
    else
        OPTS+=",rw"
    fi

    # Ask udisks to auto-mount. This needs a version of udisks that supports the 'as-user' option.
    USER=$(id -nu 1000)
    ret=0
    reply=$(busctl call --allow-interactive-authorization=false --expect-reply=true --json=short   \
                org.freedesktop.UDisks2                                                            \
                /org/freedesktop/UDisks2/block_devices/"${DEVBASE}"                                \
                org.freedesktop.UDisks2.Filesystem                                                 \
                Mount 'a{sv}' 4                                                                    \
                  as-user s ${USER}                                                                  \
                  auth.no_user_interaction b true                                                  \
                  fstype                   s "$FSTYPE"                                             \
                  options                  s "$OPTS") || ret=$?

    if (( ret != 0 )); then
        send_steam_url "system/devicemountresult" "${DEVBASE}/${MOUNT_ERROR}"
        echo "Error mounting ${DEVICE} (status = $ret)"
        exit 1
    fi

    # Expected reply is of the format
    #  {"type":"s","data":["/run/media/deck/home"]}
    mount_point=$(jq -r '.data[0] | select(type == "string")' <<< "$reply" || true)
    if [[ -z $mount_point ]]; then
        echo "Error when mounting ${DEVICE}: udisks returned success but could not parse reply:"
        echo "---"$'\n'"$reply"$'\n'"---"
        exit 1
    fi

    # Create a symlink from /run/media to keep compatibility with apps
    # that use the older mount point (for SD cards only).
    case "${DEVBASE}" in
        mmcblk0p*)
            if [[ -z "${ID_FS_LABEL}" ]]; then
                old_mount_point="/run/media/${DEVBASE}"
            else
                old_mount_point="/run/media/${mount_point##*/}"
            fi
            if [[ ! -d "${old_mount_point}" ]]; then
                rm -f -- "${old_mount_point}"
                ln -s -- "${mount_point}" "${old_mount_point}"
            fi
            ;;
    esac

    #### SteamOS Btrfs Begin ####
    if [[ "${ID_FS_TYPE}" == "btrfs" ]]; then
        # Workaround for for Steam compression bug
        for d in "${mount_point}"/steamapps/{downloading,temp} ; do
            if ! btrfs subvolume show "$d" &>/dev/null; then
                mkdir -p "$d"
                rm -rf "$d"
                btrfs subvolume create "$d"
                chattr +C "$d"
                chown 1000:1000 "${d%/*}" "$d"
            fi
        done
    elif [[ "${STEAMOS_BTRFS_SDCARD_COMPATDATA_BIND_MOUNT:-1}" == "1" ]] && \
        [[ "${ID_FS_TYPE}" == "vfat" || "${ID_FS_TYPE}" == "exfat" || "${ID_FS_TYPE}" == "ntfs" ]]; then
        # bind mount compatdata folder from internal disk
        mkdir -p "${mount_point}"/steamapps/compatdata
        chown 1000:1000 "${mount_point}"/steamapps{,/compatdata}
        mkdir -p /home/${USER}/.local/share/Steam/steamapps/compatdata
        chown 1000:1000 /home/${USER}/.local{,/share{,/Steam{,/steamapps{,/compatdata}}}}
        mount --rbind /home/${USER}/.local/share/Steam/steamapps/compatdata "${mount_point}"/steamapps/compatdata
    fi
    chown 1000:1000 -- "${mount_point}"
    #### SteamOS Btrfs End ####

    echo "**** Mounted ${DEVICE} at ${mount_point} ****"

    # If Steam is running, notify it
    send_steam_url "addlibraryfolder" "${mount_point}"
}

do_unmount()
{
    local mount_point=$(findmnt -fno TARGET "${DEVICE}" || true)
    if [[ -n $mount_point ]]; then
        # Remove symlink to the mount point that we're unmounting
        find /run/media -maxdepth 1 -xdev -type l -lname "${mount_point}" -exec rm -- {} \;
    else
        # If we don't know the mount point then remove all broken symlinks
        find /run/media -maxdepth 1 -xdev -xtype l -exec rm -- {} \;
    fi
    #### SteamOS Btrfs Begin ####
    if [[ -L /run/media/mmcblk0p1 && "$(realpath /run/media/mmcblk0p1)" == "$(realpath "${mount_point}")" ]]; then
        rm -f /run/media/mmcblk0p1
    fi
    if mountpoint -q "${mount_point}"/steamapps/compatdata; then
        /bin/umount -l -R "${mount_point}"/steamapps/compatdata
    fi
    systemd-run --uid=1000 --pipe                                                          \
      busctl call --allow-interactive-authorization=false --expect-reply=true --json=short \
        org.freedesktop.UDisks2                                                            \
        /org/freedesktop/UDisks2/block_devices/"${DEVBASE}"                                \
        org.freedesktop.UDisks2.Filesystem                                                 \
        Unmount 'a{sv}' 2                                                                  \
          auth.no_user_interaction b true                                                  \
          force                    b true
    #### SteamOS Btrfs End ####
}

do_retrigger()
{
    local mount_point=$(findmnt -fno TARGET "${DEVICE}" || true)
    [[ -n $mount_point ]] || return 0

    # In retrigger mode, we want to wait a bit for steam as the common pattern is starting in parallel with a retrigger
    wait_steam 10
    # This is a truly gnarly way to ensure steam is ready for commands.
    # TODO literally anything else
    sleep 6
    send_steam_url "addlibraryfolder" "${mount_point}"
}

case "${ACTION}" in
    add)
        do_mount
        ;;
    remove)
        do_unmount
        ;;
    retrigger)
        do_retrigger
        ;;
    *)
        usage
        ;;
esac
