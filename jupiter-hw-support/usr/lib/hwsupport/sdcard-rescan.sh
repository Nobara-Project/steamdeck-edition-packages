#!/bin/sh

# Some SanDisk SD cards are occasionally misdetected by the kernel
# and appear with the 'SD032' name and 30.6 MB of capacity.

# This can be solved by rebinding the sdhci-pci device, forcing a
# rescan.

# https://github.com/ValveSoftware/SteamOS/issues/1339

KERNEL_NAME="$1" # e.g. mmc0:d555
MMC_HOST="${KERNEL_NAME%:*}"
MMC_PATH="/sys/bus/mmc/devices/${KERNEL_NAME}"

sleep 2

[ -n "$KERNEL_NAME" -a -d "$MMC_PATH" ] || {
    echo "ERROR: cannot find MMC card '${KERNEL_NAME}' in /sys/bus/mmc/devices"
    exit 1
}

log_and_quit() {
    echo "Found SD card with unexpected attributes at ${KERNEL_NAME}:"
    for attr in name date oemid fwrev hwrev serial ssr; do
        echo "* ${attr}: $(cat "${MMC_PATH}/${attr}")"
    done
    echo "* size: $(cat "${MMC_PATH}/block/mmcblk0/size")"
    exit 0
}

# Misdetected cards can be identified by some attributes
grep -qsw SD032  "${MMC_PATH}/name"  || log_and_quit
grep -qsw 0x5344 "${MMC_PATH}/oemid" || log_and_quit
grep -qsw 62688  "${MMC_PATH}/block/mmcblk0/size" || log_and_quit

# Once we know that this is a misdetected card, get the sdhci-pci device
PCI_NAME=$(grep -s ^PCI_SLOT_NAME= "/sys/class/mmc_host/${MMC_HOST}/device/uevent" | cut -d = -f 2)
[ -n "$PCI_NAME" -a -d "/sys/bus/pci/drivers/sdhci-pci/${PCI_NAME}" ] || {
    echo "ERROR: cannot find PCI device '${PCI_NAME}' in /sys/bus/pci/drivers/sdhci-pci"
    exit 1
}

# This workaround needs a kernel with commit 1036f69e2513,
# otherwise it can crash the system.
KERNEL_VERSION=$(uname -r)
case "$KERNEL_VERSION" in
    6.1.52-valve*) MIN_VERSION=6.1.52-valve18 ;;
    6.1.*) MIN_VERSION=6.1.72 ;;
    6.5.*) MIN_VERSION=6.5.0-valve1-3 ;;
    6.6.*) MIN_VERSION=6.6.11 ;;
    *) MIN_VERSION=6.7 ;;
esac

if printf "%s\n%s\n" "$KERNEL_VERSION" "$MIN_VERSION" | sort -CV; then
    echo "SD card ${KERNEL_NAME} incorrectly detected, but this kernel is too old: ${KERNEL_VERSION}"
    exit 0
fi

# If this lock is held it means that a previous call to this script
# hasn't finished yet and rescanning the card solved nothing.
RESCAN_LOCK="/run/sdcard-rescan.lock"
exec 9<>"$RESCAN_LOCK"
if ! flock -n 9; then
    echo "Rescanning SD card ${KERNEL_NAME} did not succeed, maybe it's damaged?" >&2
    exit 0
fi

# Unbind and rebind the sdhci-pci device so the card is detected correctly
echo "SD card ${KERNEL_NAME} incorrectly detected, forcing a reset"
echo "$PCI_NAME" > /sys/bus/pci/drivers/sdhci-pci/unbind
sleep 2
echo "$PCI_NAME" > /sys/bus/pci/drivers/sdhci-pci/bind

# Wait before releasing $RESCAN_LOCK to ensure that this script
# is not called in a loop if the SD card is faulty.
sleep 5
