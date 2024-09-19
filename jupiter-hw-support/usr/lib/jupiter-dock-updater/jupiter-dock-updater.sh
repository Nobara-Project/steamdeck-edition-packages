#!/bin/bash

set -e

ROOT=$(dirname "$(realpath -- "$0" )")
CHECK_ARGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ARGS="-checkupdateonly=1"; shift ;;
        *) echo "Unknown option $1"; exit -22;;
    esac
done

pushd "$ROOT"
"$ROOT/hub_update" -vid=28DE -pid=2001 $CHECK_ARGS
