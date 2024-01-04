#!/usr/bin/bash

devicepath=/dev/serial/by-id/usb-Renesas_RA_USB_Boot-if00

if [ $# -eq 0 ]; then
    echo "Usage rfp_cli_linux.sh <bootloader.srec> [--erase_prov_and_cal] [--erase_app]"
    echo "      Defaults are to preserve provisioning and application"
    exit
fi

#Preserve dataflash (provisioning/cal) by default
dataflash_option="-range-exclude 0x08000000,0x08002000"
if [ "$2" = "--erase_prov_and_cal" ] || [ "$3" = "--erase_prov_and_cal" ]; then
  echo "Erasing provisioning"
  dataflash_option=
else
  echo "Preserving provisioning"
fi

#Preserve application by default
application_option="-range-exclude 0x00008000,0x00040000"
if [ "$2" = "--preserve_app" ] || [ "$3" = "--preserve_app" ]; then
  echo "Erasing application"
  application_option=
else
  echo "Preserving application"
fi

chmod u+x "linux_host_tools/BatCtrl"
chmod u+x "linux_host_tools/rfp-linux-x64/rfp-cli"


#Repeatedly power cycle the controller, then check for RA Bootloader enumeration
echo "Press and *hold* Right Bumper, Right Upper Back, Right Quick Access."
t=1
found=0
while [ $t -le 10 ]
do
  sudo ./linux_host_tools/BatCtrl SetCBPower 0 > /dev/null
  sleep 1
  sudo ./linux_host_tools/BatCtrl SetCBPower 1 > /dev/null
  #It takes a while for the RA bootloader to enumerate
  sleep 4
  result=$(lsusb -d 045b:0261)
  if [ $? -ne 0 ]
  then
    t=$(( $t + 1))
  else
    found=1
    echo "Device found"
    break
  fi
done

if [ $found -le 0 ]
then
  echo "Timeout"
  exit
fi

#Program the bootloader, and memory boundaries
echo "Programming"
sudo ./linux_host_tools/rfp-linux-x64/rfp-cli -d RA -port $devicepath $application_option $dataflash_option -a $1 -fo boundary 256,0,8,128,0 > /dev/null
if [ $? -ne 0 ]
  then
  echo "Programming failed"
  exit
fi

echo "Programming done"
echo ""

#Power cycle the controller again, and verify the programmed bootloader enumerates
echo "*Please release buttons*"

foundsteamdevice=0
t=0
while [ $t -le 10 ]
do
  sudo ./linux_host_tools/BatCtrl SetCBPower 0 > /dev/null
  sleep 1
  sudo ./linux_host_tools/BatCtrl SetCBPower 1 > /dev/null
  sleep 2
  result=$(lsusb -d 28de:1004 -d 28de:1205)
  if [ $? -ne 0 ]
  then
    t=$(( $t + 1))
  else
    foundsteamdevice=1
    break
  fi
done

if [ $foundsteamdevice -le 0 ]
then
  echo "Timeout"
else
  echo "Success"
fi
