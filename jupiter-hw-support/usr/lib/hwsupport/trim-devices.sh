#!/bin/bash

set -e

# Run fstrim using chunks, to allow it to be interruptable, e.g. for system
# suspend.
#
# $1: mount path to fstrim
function _fstrim()
{
    local _path="$1"
    local _size
    _size="$(findmnt --output size --raw --noheadings --bytes "$_path")"
    # Use a 1GB chunk size. This doesn't take too long on a modest SD card. 1GB
    # may(?) be too small, causing too much overhead with too 1 many calls to
    # fstrim. So some further optimization is likely needed.
    local _chunk_size=1073741824
    local _offset=0

    echo "Running fstrim in 1GB chunks on: $_path"
    while [ "$_offset" -le "$_size" ]; do
        fstrim -o "$_offset" -l "$_chunk_size" "$_path"
        ((_offset+=_chunk_size))
    done
}

# Run fstrim on all mounted filesystems. Currently only ext4 and btrfs, and
# mounted rw. Based loosely on the "util-linux/fstrim -a" implementation.
function fstrim_all()
{
    local _mountpt
    for _src in $(findmnt --noheadings -t ext4,btrfs -O rw --list --output source -v | sort -u); do
        _mountpt="$(findmnt --noheadings --output target "$_src" | head -n1)"
        _fstrim "$_mountpt"
    done
}

function is_known_bad_device()
{
    local sdcard_dir=$(find /sys/class/mmc_host/mmc0/mmc0\:* -maxdepth 0)
    if [[ ! -d "$sdcard_dir" ]]; then
        echo "No sdcard present"
        false
        return;
    fi

    local sdcard_manfid=$(cat "$sdcard_dir"/manfid)
    local sdcard_oemid=$(cat "$sdcard_dir"/oemid)
    local sdcard_safe_trim_quirk_version=$(cat "$sdcard_dir"/safe_trim_quirk)

    if [ -z "$sdcard_safe_trim_quirk_version" ]; then
        echo "Warning: kernel does not advertise safe_trim_quirk version, assuming 0"
        sdcard_safe_trim_quirk_version=0
    fi

    echo "Found sdcard: manfid=$sdcard_manfid oemid=$sdcard_oemid safe_trim_quirk_version=$sdcard_safe_trim_quirk_version"

    # Check for problematic cards

    # These cards are not safe to trim unless we have a discard->erase quirk
    # present in the kernel
    if (( "$sdcard_manfid" == 0x3 || "$sdcard_oemid" == 0x5344 )); then
        # Only allow trim on these cards if the kernel has the necessary quirk
        # to convert discard commands to erase commands
        if [[ "$sdcard_safe_trim_quirk_version" -lt "1" ]]; then
            echo "Warning: sdcard is not safe to trim"
            true
            return
        fi

        echo "Warning: possible problematic card, but kernel advertises workaround support. Proceeding."
        false
        return;
    fi

    echo "sdcard is safe to trim"
    false
    return;
}

# In some cases it is unsafe to trim an sdcard. When we detect this case
# lets just trim the partitions on the internal drive which we know are
# safe to trim/discard
if is_known_bad_device; then
    _fstrim /var
    _fstrim /home
    exit
fi

fstrim_all
