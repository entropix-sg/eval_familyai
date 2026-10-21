#!/usr/bin/env bash
set -euo pipefail
umask 077

log() { printf '[emulator] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
adb_local() { timeout 30 adb -H 127.0.0.1 -P 5037 -s emulator-5554 "$@"; }

[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || die '/dev/kvm is unavailable or inaccessible'
[[ "$AVD_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Invalid AVD_NAME'
[[ "$BOOT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die 'Invalid boot timeout'
[[ "$EMULATOR_MEMORY_MB" =~ ^[1-9][0-9]*$ && "$EMULATOR_CORES" =~ ^[1-9][0-9]*$ ]] || die 'Invalid CPU or memory setting'
[[ "$APP_PACKAGE" =~ ^[A-Za-z][A-Za-z0-9_.]+$ ]] || die 'Invalid APP_PACKAGE'
[[ "$APP_ACTIVITY" =~ ^[A-Za-z0-9_.]+$ ]] || die 'Invalid APP_ACTIVITY'
unset ADB_SERVER_SOCKET ANDROID_ADB_SERVER_PORT
mkdir -p "$HOME" "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME" /run/android
rm -f /run/android/ready /run/android/adb.pid /run/android/emulator.pid

# PVC 恢复时拒绝自动跨系统镜像迁移，避免误清空或损坏已有设备数据。
if [[ -f /data/image-identity ]]; then
    cmp -s /data/image-identity /opt/android-image-identity || die 'System image/emulator changed; migrate or use a new volume explicitly'
else
    cp /opt/android-image-identity /data/image-identity
fi

avd_dir="${ANDROID_AVD_HOME}/${AVD_NAME}.avd"
if [[ ! -f "$avd_dir/config.ini" ]]; then
    log 'Creating a clean Android 15 Google APIs x86_64 device'
    printf 'no\n' | avdmanager create avd --name "$AVD_NAME" \
        --package "$(cat /opt/android-system-image)" --device pixel_6 --sdcard 512M
fi

set_config() {
    sed -i "/^${1//./\\.}=/d" "$avd_dir/config.ini"
    printf '%s=%s\n' "$1" "$2" >> "$avd_dir/config.ini"
}
set_config hw.ramSize "$EMULATOR_MEMORY_MB"
set_config hw.cpu.ncore "$EMULATOR_CORES"
set_config disk.dataPartition.size 10G
set_config hw.gpu.enabled yes
set_config hw.gpu.mode software
set_config hw.keyboard yes
set_config showDeviceFrame no
set_config fastboot.forceColdBoot yes

adb_pid=''
emulator_pid=''
cleanup() {
    local result=$?
    trap - EXIT TERM INT
    rm -f /run/android/ready
    log 'Stopping emulator and ADB server'
    if [[ -n "$emulator_pid" ]] && kill -0 "$emulator_pid" 2>/dev/null; then
        adb_local emu kill >/dev/null 2>&1 || true
        for ((i=0; i<30; i++)); do
            kill -0 "$emulator_pid" 2>/dev/null || break
            sleep 1
        done
        kill -TERM "$emulator_pid" 2>/dev/null || true
        for ((i=0; i<5; i++)); do
            kill -0 "$emulator_pid" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$emulator_pid" 2>/dev/null || true
    fi
    [[ -z "$adb_pid" ]] || kill -TERM "$adb_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 0' TERM INT

# 远程客户端连接的是 ADB server 5037，而非 Android adbd 5555。
adb -a -P 5037 nodaemon server &
adb_pid=$!
printf '%s\n' "$adb_pid" > /run/android/adb.pid
for ((i=0; i<30; i++)); do
    kill -0 "$adb_pid" 2>/dev/null || die 'ADB server exited'
    if timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/5037' 2>/dev/null; then
        break
    fi
    sleep 1
done
kill -0 "$adb_pid" 2>/dev/null || die 'ADB server failed to start'

args=(-avd "$AVD_NAME" -ports 5554,5555 -accel on -gpu software
      -no-window -no-audio -no-boot-anim -no-snapshot
      -memory "$EMULATOR_MEMORY_MB" -cores "$EMULATOR_CORES"
      -netdelay none -netspeed full -timezone "$TZ")
# 云环境直接使用 Pod 网络；需要代理或特定 DNS 时显式配置。
[[ -z "${EMULATOR_HTTP_PROXY:-}" ]] || args+=(-http-proxy "$EMULATOR_HTTP_PROXY")
[[ -z "${EMULATOR_DNS_SERVERS:-}" ]] || args+=(-dns-server "$EMULATOR_DNS_SERVERS")
emulator "${args[@]}" &
emulator_pid=$!
printf '%s\n' "$emulator_pid" > /run/android/emulator.pid

log 'Waiting for Android boot'
deadline=$((SECONDS + BOOT_TIMEOUT_SECONDS))
while true; do
    kill -0 "$adb_pid" 2>/dev/null || die 'ADB server exited during boot'
    kill -0 "$emulator_pid" 2>/dev/null || die 'Emulator exited during boot'
    boot="$(timeout 5 adb -H 127.0.0.1 -P 5037 -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null || true)"
    [[ "${boot//$'\r'/}" != 1 ]] || break
    (( SECONDS < deadline )) || die 'Android boot timed out'
    sleep 2
done

adb_local shell settings put global auto_time_zone 0
adb_local shell cmd alarm set-timezone "$TZ"
actual_timezone="$(adb_local shell getprop persist.sys.timezone)"
[[ "${actual_timezone//$'\r'/}" == "$TZ" ]] || die 'Android timezone was not applied'
adb_local shell settings put global window_animation_scale 0
adb_local shell settings put global transition_animation_scale 0
adb_local shell settings put global animator_duration_scale 0

log 'Installing APK (existing app data is retained on persistent volumes)'
timeout 180 adb -H 127.0.0.1 -P 5037 -s emulator-5554 install -r /opt/app/app.apk
# 不自动卸载，不自动降级，不在安装失败后清数据。
launch="$(adb_local shell am start -W -n "${APP_PACKAGE}/${APP_ACTIVITY}")"
printf '%s\n' "$launch"
[[ "$launch" != *'Error'* && "$launch" == *'Status: ok'* ]] || die 'Application did not launch successfully'
touch /run/android/ready
log 'READY: emulator-5554; remote ADB server :5037'

# 任一主进程退出时容器失败，交由 K8s 重启；不在容器内静默重放业务操作。
set +e
wait -n "$adb_pid" "$emulator_pid"
set -e
die 'Emulator or ADB server exited unexpectedly'
