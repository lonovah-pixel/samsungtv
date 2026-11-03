#!/usr/bin/env bash
# Снимок экрана меню Ventoy в QEMU (BIOS и/или UEFI) без записи на носитель.
# Носитель подключается с snapshot=on: все записи уходят во временный файл, флешка не меняется.
#
#   tests/qemu-ventoy-screenshot.sh <образ-или-/dev/sdX> <папка-для-снимков> [bios|uefi|both] [секунды]
#
# Для физической флешки нужны права чтения устройства (sudo). KVM не обязателен (медленнее без него).
set -euo pipefail
DISK=${1:?путь к образу или устройству}
OUT=${2:?папка для снимков}
MODE=${3:-both}
WAIT=${4:-40}
command -v qemu-system-x86_64 >/dev/null || { echo "нужен qemu-system-x86_64" >&2; exit 1; }
mkdir -p "$OUT"
ACCEL=(); [[ -w /dev/kvm ]] && ACCEL=(-enable-kvm -cpu host)

shot() {   # $1 = bios|uefi
  local mode=$1 sock; sock=$(mktemp -u /tmp/vtoy-mon.XXXXXX)
  local fw=()
  if [[ $mode == uefi ]]; then
    local code; code=$(ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd 2>/dev/null | head -1 || true)
    [[ -n $code ]] || { echo "OVMF не найден (apt install ovmf)" >&2; return 1; }
    fw=(-drive "if=pflash,format=raw,readonly=on,file=$code")
    local vars; vars=$(ls /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd 2>/dev/null | head -1 || true)
    if [[ -n $vars ]]; then cp "$vars" "$OUT/vars.fd"; fw+=(-drive "if=pflash,format=raw,file=$OUT/vars.fd"); fi
  fi
  qemu-system-x86_64 "${ACCEL[@]}" -m 1024 -machine q35 "${fw[@]}" \
    -drive "file=$DISK,format=raw,if=none,id=usb,snapshot=on" -device qemu-xhci -device usb-storage,drive=usb,bootindex=0 \
    -vga std -display none -monitor "unix:$sock,server,nowait" -no-reboot &
  local pid=$!
  sleep "$WAIT"
  python3 - "$sock" "$OUT/ventoy-$mode.ppm" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.5); s.recv(65536)
s.sendall(f"screendump {sys.argv[2]}\n".encode()); time.sleep(2); s.sendall(b"quit\n"); time.sleep(0.5)
PY
  wait "$pid" 2>/dev/null || true
  rm -f "$sock"
  if command -v convert >/dev/null; then convert "$OUT/ventoy-$mode.ppm" "$OUT/ventoy-$mode.png" && rm -f "$OUT/ventoy-$mode.ppm"; fi
  echo "снимок: $OUT/ventoy-$mode.(png|ppm)"
}
case $MODE in
  bios) shot bios ;; uefi) shot uefi ;; both) shot bios; shot uefi ;;
  *) echo "режим: bios|uefi|both" >&2; exit 1 ;;
esac
