#!/usr/bin/env bash
set -euo pipefail

for name in adb emulator; do
    test -s "/run/android/${name}.pid"
    kill -0 "$(cat "/run/android/${name}.pid")"
done
if [[ "${1:-ready}" == ready ]]; then
    test -f /run/android/ready
fi
boot="$(timeout 8 adb -H 127.0.0.1 -P 5037 -s emulator-5554 shell getprop sys.boot_completed)"
[[ "${boot//$'\r'/}" == 1 ]]
