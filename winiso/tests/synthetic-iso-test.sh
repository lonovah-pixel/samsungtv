#!/usr/bin/env bash
# Проверка САМОГО верификатора Test-WinIsoOutput.ps1 на синтетическом ISO (не Windows!).
# Собирает фиктивную структуру носителя и install.wim (wimlib), затем:
#   1) корректный образ → верификатор должен пройти;
#   2) образ с разметкой диска в autounattend.xml → верификатор должен упасть.
# Требует: pwsh, xorriso, wimlib-imagex, 7z, python3.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for t in pwsh xorriso wimlib-imagex 7z python3; do command -v $t >/dev/null || { echo "нет $t" >&2; exit 1; }; done

# Тестовая конфигурация: примеры программ + заполненные параметры.
mkdir -p "$W/cfg"; cp "$ROOT"/config/*.json "$W/cfg/"; cp "$W/cfg/apps.example.json" "$W/cfg/apps.json"
python3 - "$W/cfg/build.json" <<'PY'
import json, sys
p = sys.argv[1]; b = json.load(open(p, encoding="utf-8"))
b["source"]["iso_path"] = "C:\\iso\\Win11.iso"
b["target"].update(windows="Windows 11 25H2", editions=["Core", "Professional"], language="ru-RU")
b["paths"].update(work_dir="D:\\WinBuild", output_iso="D:\\WinBuild\\out\\custom.iso")
json.dump(b, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY

make_iso() {   # $1 = имя, $2 = файл autounattend
  local m="$W/$1/media" img="$W/$1/img"
  mkdir -p "$m"/{boot,efi/microsoft/boot,efi/boot,sources} "$img"/Windows/Setup/Scripts "$img"/ProgramData/WinIsoDeploy/installers
  for f in bootmgr bootmgr.efi boot/etfsboot.com efi/microsoft/boot/efisys.bin efi/boot/bootx64.efi sources/setup.exe; do echo stub > "$m/$f"; done
  cp "$ROOT/payload/SetupComplete.cmd" "$img/Windows/Setup/Scripts/"
  cp "$ROOT/payload/Deploy-Apps.ps1" "$ROOT/payload/Undo-Tweaks.ps1" "$img/ProgramData/WinIsoDeploy/"
  echo '{}' > "$img/ProgramData/WinIsoDeploy/apps.json"
  echo stub > "$img/ProgramData/WinIsoDeploy/installers/vc_redist.x64.exe"
  echo stub > "$img/ProgramData/WinIsoDeploy/installers/Firefox-ru-x64.msi"
  wimlib-imagex capture "$img" "$m/sources/install.wim" "Windows 11 Home" --compress=fast >/dev/null
  wimlib-imagex append "$img" "$m/sources/install.wim" "Windows 11 Pro" >/dev/null
  wimlib-imagex info "$m/sources/install.wim" 1 --image-property WINDOWS/EDITIONID=Core >/dev/null
  wimlib-imagex info "$m/sources/install.wim" 2 --image-property WINDOWS/EDITIONID=Professional >/dev/null
  printf '[Channel]\r\nRetail\r\n' > "$m/sources/ei.cfg"
  wimlib-imagex capture "$img" "$m/sources/boot.wim" "boot" --compress=fast >/dev/null
  cp "$2" "$m/autounattend.xml"
  xorriso -as mkisofs -quiet -J -joliet-long -R -V WIN_CUSTOM -o "$W/$1.iso" "$m" 2>/dev/null
  sha256sum "$W/$1.iso" | awk '{print $1" *'"$1"'.iso"}' > "$W/$1.iso.sha256"
}

sed -e 's/{{ARCH}}/amd64/' -e 's#{{FIRST_LOGON_SCRIPT}}#C:\\ProgramData\\WinIsoDeploy\\Deploy-Apps.ps1#' \
  "$ROOT/unattend/autounattend.template.xml" > "$W/good.xml"
python3 - "$W/good.xml" "$W/bad.xml" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
bad = s.replace('<settings pass="oobeSystem">',
  '<settings pass="windowsPE"><component name="Microsoft-Windows-Setup" processorArchitecture="amd64" '
  'publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><DiskConfiguration><WillShowUI>OnError</WillShowUI>'
  '</DiskConfiguration></component></settings><settings pass="oobeSystem">')
open(sys.argv[2], "w", encoding="utf-8").write(bad)
PY
make_iso good "$W/good.xml"
make_iso bad "$W/bad.xml"

echo "== 1. корректный образ (ожидается успех)"
pwsh -NoProfile -File "$ROOT/scripts/Test-WinIsoOutput.ps1" -IsoPath "$W/good.iso" -ConfigPath "$W/cfg/build.json" | grep -E "FAIL|Итог" || true
pwsh -NoProfile -File "$ROOT/scripts/Test-WinIsoOutput.ps1" -IsoPath "$W/good.iso" -ConfigPath "$W/cfg/build.json" >/dev/null
echo "   OK: верификатор принял корректный образ"
echo "== 2. образ с DiskConfiguration (ожидается отказ)"
if pwsh -NoProfile -File "$ROOT/scripts/Test-WinIsoOutput.ps1" -IsoPath "$W/bad.iso" -ConfigPath "$W/cfg/build.json" > "$W/bad.log" 2>&1; then
  echo "   ОШИБКА: верификатор пропустил разметку диска" >&2; exit 1
fi
grep -E "FAIL" "$W/bad.log" | sed 's/^/   /'
echo "   OK: верификатор отклонил образ"
