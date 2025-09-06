#!/bin/bash

set -euo pipefail

declare -r PARTSETS=/efi/SteamOS/partsets/all

. /usr/lib/hwsupport/common-functions

usage()
{
    echo "Usage: $0 {add|remove} device_name (e.g. sdb1)"
    echo "NOTE: Ignores partitions registered in ${PARTSETS}"
    exit 1
}

is_os_partition ()
{
    local -r dev="/dev/${DEVBASE}"
    local label=
    local uuid=
    local ignore=
    # if lsblk errors our we have to bypass the OS partition check anyway
    # shellcheck disable=SC2155
    local partuuid=$(lsblk -ndo partuuid "$dev" || :)

    echo "Checking if $dev is an OS partition ($partuuid) in $PARTSETS" >&2

    if [ ! -r "$PARTSETS" ] || [ ! -b "$dev" ] || [ -z "$partuuid" ]
    then
        return 1
    fi

    # the label and ignore file entries are, in fact, unused:
    # shellcheck disable=SC2034
    while read -r label uuid ignore
    do
        if [ "$uuid" = "$partuuid" ]
        then
            echo "Ignoring device $dev registered in $PARTSETS" >&2
            return 0
        fi
    done < "$PARTSETS"

    return 1
}

if [[ $# -ne 2 ]]; then
    usage
fi

ACTION=$1
DEVBASE=$2

# Shared between this and format-device.sh to ensure we're not
# double-triggering nor automounting while formatting or vice-versa.
if ! create_lock_file "$DEVBASE"; then
    exit 0
fi

do_add()
{
    declare -i current_time=$EPOCHSECONDS
    declare -i detected_us

    # Prior to talking to udisks, we need all udev hooks (we were started by one) to finish, so we know it has knowledge
    # of the drive.  Our own rule starts us as a service with --no-block, so we can wait for rules to settle here
    # safely.
    if ! udevadm settle; then
        echo "Failed to wait for \`udevadm settle\`" >&2
        exit 1
    fi

    # We only want to handle udev 'add' events that happen when a
    # drive is inserted (and not when it's repartitioned), so here we
    # check that they arrive shortly after the drive is detected.
    #
    # A special case is the cold plug scenario: we always handle 'add'
    # events during system boot because they can actually arrive late
    # if the boot process is slow. Therefore we check the arrival time
    # of the event only if we have already reached multi-user.target.
    if systemctl -q check multi-user.target; then
        drive=$(make_dbus_udisks_call get-property data o "block_devices/${DEVBASE}" Block Drive)
        detected_us=$(make_dbus_udisks_call get-property data t "${drive}" Drive TimeMediaDetected)
        # The 5 seconds window is taken from the original GNOME fix that inspired this one
        # https://gitlab.gnome.org/GNOME/gvfs/-/commit/b4800b987b4a8423a52306c9aef35b3777464cc5
        if (( detected_us / 1000000 + 5 < current_time )); then
            echo "Skipping mounting /dev/${DEVBASE} because it has not been inserted recently" >&2
            exit 0
        fi
    fi

    /usr/lib/hwsupport/steamos-automount.sh add "${DEVBASE}"
}

do_remove()
{
    /usr/lib/hwsupport/steamos-automount.sh remove "${DEVBASE}"
}

case "${ACTION}" in
    add)
        if ! is_os_partition
        then
            do_add;
        fi
        ;;
    remove)
        do_remove
        ;;
    *)
        usage
        ;;
esac
