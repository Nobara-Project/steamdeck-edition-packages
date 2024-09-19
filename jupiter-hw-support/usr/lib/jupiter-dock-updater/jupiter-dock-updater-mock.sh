#!/bin/bash

set -e

UPDATE_CHECK=0
UPDATE_ERROR=0
CURRENT_VER=4.4
AVAILABLE_VER=4.5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) UPDATE_CHECK=1; shift ;;
        --mock-update-available) shift ;; #default behaviour
        --mock-up-to-date) CURRENT_VER=$AVAILABLE_VER; shift ;;
        --mock-update-error) UPDATE_ERROR=1; shift ;;
        *) echo "Unknown option $1"; exit -22;;
    esac
done


function check()
{
	echo "FW Current: $CURRENT_VER"
	echo "FW Available: $AVAILABLE_VER"

    if (( $(echo "$AVAILABLE_VER > $CURRENT_VER" | bc -l) )); then
        echo "FW update available"
        exit 0
    fi
    echo "FW up to date"
    exit 7
}


function update()
{
    echo "Kinet_Flash_Write FW1"
    for i in {1..100}; do
        echo -en "\rprogress=$i%"
        sleep 0.001
    done
    echo

    echo "Kinet_Flash_Write FW0"
    for i in {1..100}; do
        echo -en "\rprogress=$i%"
        sleep 0.02

        if [[ "$i" -gt "50" ]]; then
            if [[ "$UPDATE_ERROR" != "0" ]]; then
                echo
                echo "FW Update error"
                exit -1
            fi
        fi
    done
    echo

    exit 0
}


if [[ "$UPDATE_CHECK" != "0" ]]; then
    check
else
    update
fi
