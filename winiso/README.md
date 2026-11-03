# WinIso — воспроизводимая сборка настроенного ISO Windows + баннер Ventoy

Проект собирает установочный ISO Windows штатными средствами Microsoft (DISM + `oscdimg` из Windows ADK)
и заменяет баннер в меню Ventoy без переустановки Ventoy. Оригинальный ISO не изменяется: работа идёт с копией.

> **Состояние:** конфигурация заполнена: Windows 11 Домашняя + Pro в одном ISO (ru-RU, x64), стандартный набор программ,
> удаление Xbox, Game Bar и Outlook, черновой баннер в стиле DNS. ISO ещё **не собран**: нужны исходный ISO, рабочая папка
> и Windows-машина с ADK. Подробности в [docs/REPORT.md](docs/REPORT.md).

## Откуда брать ISO

Только официальный образ Microsoft: <https://www.microsoft.com/ru-ru/software-download/windows11> →
«Загрузка образа диска (ISO) для устройств x64» → Windows 11 (multi-edition ISO) → русский. В нём есть и Домашняя, и Pro.
На той же странице после выбора языка показан SHA-256 — впишите его в `source.iso_sha256`, сборка сверит образ.
Сторонние сборки и активаторы (в т. ч. MAS с massgrave.dev) проект не использует и не встраивает: активируйте
Windows своим ключом или цифровой лицензией (на ПК с ключом в прошивке это происходит автоматически).

## Что нужно указать (ответы → `config/build.json`, `config/apps.json`)

| Параметр | Куда |
|---|---|
| Версия Windows, редакции (`EditionId`: `Core` = Домашняя, `Professional` = Pro), язык, архитектура | `target.*` |
| Путь к оригинальному ISO или папке (сейчас `D:\iso\`) + по желанию эталонный SHA-256 | `source.iso_path`, `source.iso_sha256` |
| Рабочая папка (NTFS, ≥ 25 ГБ) и путь к готовому ISO | `paths.work_dir`, `paths.output_iso` |
| Назначение ПК и железо (нужны ли драйверы RST/VMD/сеть) | `paths.drivers_dir` |
| Список программ; какие нужны без интернета | `config/apps.json` (формат: `apps.example.json`) |
| Какие приложения Windows убрать сверх консервативного набора | `optimization.user_extra_appx_remove` / `appx-remove.json` |
| Флешка Ventoy (буква/точка монтирования) и картинка или описание баннера | `ventoy_banner.py` |

## Чем и что собирать (рекомендация)

* **Версия Windows:** текущий выпуск с microsoft.com — на 2026-11-03 это **Windows 11 26H2**, многоредакционный ISO
  (Домашняя и Pro в одном файле), язык «Русский», x64. Положите его в `D:\iso\` (имя вида `Win11_26H2_Russian_x64.iso`)
  — сборка найдёт его сама; если там несколько `Win11*.iso`, попросит указать файл.
* **Чем собирать:** обычный ПК с **Windows 11** (желательно 24H2 или новее, со всеми обновлениями), **Windows ADK**
  последней версии с learn.microsoft.com (при установке достаточно галочки **Deployment Tools**), PowerShell
  «от имени администратора». Сторонние программы-«сборщики» не нужны и не используются: DISM и oscdimg — штатные
  инструменты Microsoft. Если ADK предупредит о версии образа новее системы — укажите в `tools.dism` DISM из ADK.
* **Где:** рабочая папка `C:\WinBuild` (NTFS, ≥ 25 ГБ свободно). Не на флешке: Ventoy-раздел — exFAT, сборка там откажется.
* **На флешку D:** готовый ISO и баннер записывает `scripts\Install-ToVentoy.ps1` — после показа носителя и ввода токена.

## Требования к сборочной машине

* Windows 10/11, PowerShell 5.1+ **от администратора**, NTFS-диск с ≥ 25 ГБ свободного места.
* Windows ADK → компонент **Deployment Tools** (`oscdimg.exe`; для образа новее ОС — и DISM этой версии ADK).
* Интернет — только для загрузки офлайн-установщиков (`Get-Installers.ps1`).
* Для Ventoy: Python 3.8+; Pillow — только для `make-banner`.

## Быстрый старт

```powershell
cd <папка проекта>\winiso
# 1. Проверка плана без изменений (покажет редакции в ISO и недостающие параметры)
powershell -ExecutionPolicy Bypass -File .\scripts\Build-WinIso.ps1 -PlanOnly
# 2. Загрузка и проверка офлайн-установщиков (подпись + SHA-256); -Pin закрепит хэши подписанных файлов
powershell -ExecutionPolicy Bypass -File .\scripts\Get-Installers.ps1 -Pin
# 3. Сборка → ISO, .sha256, журнал и отчёт в <work_dir>\logs, затем автоматическая статическая проверка
powershell -ExecutionPolicy Bypass -File .\scripts\Build-WinIso.ps1
# 4. Записать баннер и готовый ISO на флешку Ventoy D: (сначала план, затем запись с подтверждением токеном)
powershell -ExecutionPolicy Bypass -File .\scripts\Install-ToVentoy.ps1 -Drive D -Banner .\ventoy\draft-banner.png -Iso C:\WinBuild\out\Win11_HomePro_ru-RU_custom.iso -PlanOnly
powershell -ExecutionPolicy Bypass -File .\scripts\Install-ToVentoy.ps1 -Drive D -Banner .\ventoy\draft-banner.png -Iso C:\WinBuild\out\Win11_HomePro_ru-RU_custom.iso
# Если сборка была прервана (остались смонтированные образы/кусты реестра):
powershell -ExecutionPolicy Bypass -File .\scripts\Repair-WinIsoMounts.ps1 -PlanOnly   # затем без -PlanOnly
```

Баннер Ventoy (команды одинаковы в Windows и Linux; `E:\` — раздел данных Ventoy):

```bash
python ventoy/ventoy_banner.py inspect E:\
python ventoy/ventoy_banner.py make-banner --out banner.png --source my-picture.jpg --title "Моя флешка"
python ventoy/ventoy_banner.py plan E:\ --banner banner.png          # покажет носитель и токен подтверждения
python ventoy/ventoy_banner.py apply E:\ --banner banner.png --confirm <ТОКЕН из plan>
python ventoy/ventoy_banner.py rollback E:\                          # откат последнего применения
```

Флешки под рукой нет — используйте готовую папку [`ventoy/staged/`](ventoy/staged/INSTRUCTIONS.md) (черновой баннер в стиле DNS,
`ventoy/draft-banner.png`). Свой логотип: `make-banner --source logo.png` или `--palette orange --title "..."`.

## Что делает сборка

1. Проверки: права, `dism`/`oscdimg`, свободное место, NTFS, отсутствие зависших монтирований; сверка SHA-256 оригинала.
2. Копия ISO → распаковка → экспорт **только выбранных редакций** (`target.editions`, по EditionId) в новый
   `install.wim` (ESD конвертируется). Проверяются архитектура и язык. При двух редакциях добавляется `sources\ei.cfg`
   (`[Channel] Retail`, без ключа), чтобы установщик спрашивал редакцию даже на ноутбуке с OEM-ключом Домашней.
   Обслуживание (шаг 3) выполняется для каждой редакции.
3. Офлайн-обслуживание смонтированного образа:
   * удаление предустановленных приложений из `appx-remove.json` (`Remove-AppxProvisionedPackage`); защищённые пакеты
     (Store, App Installer/winget, Безопасность Windows, фреймворки) удалить нельзя — скрипт откажет;
   * настройки из `tweaks.json` в профиле по умолчанию и `HKLM\SOFTWARE` (переключатели «Параметров» и документированные
     политики); пути Defender/Firewall/UAC/Update/подкачки/восстановления/обхода требований запрещены валидатором;
   * драйверы из `drivers_dir` в `install.wim` и `boot.wim` (по желанию);
   * `C:\ProgramData\WinIsoDeploy\` (сценарии, офлайн-установщики, манифест) и `Windows\Setup\Scripts\SetupComplete.cmd`.
4. `autounattend.xml` — **только** `FirstLogonCommands` в проходе oobeSystem. Нет прохода windowsPE, разметки дисков,
   ключей, учётных записей, паролей, автологина и обходов: язык, редакция, **диск** и OOBE выбираются вручную.
5. `oscdimg -m -o -u2 -udfver102 -bootdata:2#p0,e,b<etfsboot.com>#pEF,e,b<efisys.bin>` (BIOS + UEFI, загрузочные файлы
   берутся из самого ISO) → SHA-256 → `Test-WinIsoOutput.ps1`.

Каждое изменение (назначение / побочный эффект / откат) перечислено в `config/appx-remove.json` и `config/tweaks.json`
и печатается в `-PlanOnly`. В установленной системе: `C:\ProgramData\WinIsoDeploy\Undo-Tweaks.ps1` откатывает настройки,
приложения возвращаются из Microsoft Store (команды в поле `undo`).

## Программы

| `method` / `stage` | Когда и как | Интернет |
|---|---|---|
| `offline` / `setupcomplete` | Установщик встроен в образ; ставится от SYSTEM в конце установки Windows, до первого входа | не нужен |
| `offline` / `firstlogon` | Встроен; ставится при первом входе администратора | не нужен |
| `winget` / `firstlogon` | `winget install --exact --silent` при первом входе | **нужен** |

* winget появляется только после первого входа пользователя — поэтому `winget` разрешён только на `firstlogon`;
  сценарий проверяет его наличие, при необходимости выполняет документированную регистрацию App Installer и проверяет сеть.
* Перед установкой — правило `detect` (запись в «Программы и компоненты», файл, MSI ProductCode или `winget list`):
  установленное пропускается, дубликатов нет. Состояние — `state.json`, журналы — `C:\ProgramData\WinIsoDeploy\logs`.
* Коды: `success_codes`; `reboot_codes` (3010/1641) — успех, перезагрузка **не** выполняется автоматически (флаг
  `REBOOT_REQUIRED`); коды winget «уже установлено» / «нужна перезагрузка» учитываются.
* Нет сети/winget или ошибка → задача `WinIsoDeploy-Retry` повторит при следующем входе (до 3 попыток), затем удаляется.
* `depends_on` и `order` задают порядок; зависимая программа ждёт успешной установки зависимости.
* `SetupComplete.cmd` не выполняется Windows при OEM-ключе (кроме Enterprise) — тогда офлайн-программы ставит этап
  `FirstLogon` (тот же идемпотентный сценарий).
* Офлайн-установщики берутся только по HTTPS из официальных URL; сборка требует действительную подпись Authenticode
  ожидаемого издателя и закреплённый SHA-256 (настраивается в `security`). Встраивайте только то, что лицензия разрешает
  распространять; остальное — через `winget`.

## Ventoy

* Встроенная тема Ventoy лежит в разделе VTOYEFI; логотип «Ventoy» нарисован в её `background.png` 1024×768.
  Поэтому баннер меняется **своей темой** через плагин `theme` в `/ventoy/ventoy.json` на разделе данных.
* Если тема уже задана — заменяется только её `desktop-image` (остальное не трогается).
  Если нет — создаётся `/ventoy/themes/winiso/` (копия встроенной темы Ventoy 1.1.18 + новый фон) и добавляется
  только ключ `theme`; остальные ключи `ventoy.json` проверяются на неизменность. Для тёмного баннера цвет строки
  версии и подсказок клавиш меняется на светлый (`ventoy_color`).
* Запись только после `--confirm <МЕТКА-UUID>` именно этого носителя; резервные копии — `/ventoy/winiso_backup/<время>/`
  на флешке и `winiso/ventoy-backups/` локально; `rollback` возвращает всё побайтно. Разделы, форматирование и
  установка Ventoy не затрагиваются.
* Проверка без записи на флешку: `tests/qemu-ventoy-screenshot.sh /dev/sdX out/ both` (Linux, QEMU, `snapshot=on`).

## Тесты

```bash
pwsh -NoProfile -File tests/Run-Tests.ps1                     # синтаксис, валидация, защитные ограничения, -PlanOnly
python3 -m unittest discover -s tests -p 'test_*.py'          # инструмент Ventoy
tests/synthetic-iso-test.sh                                   # сам верификатор ISO (синтетический образ, не Windows)
```

## Структура

```
config/      build.json, apps.json, apps.example.json, appx-remove.json, tweaks.json
scripts/     Build-WinIso.ps1, Get-Installers.ps1, Install-ToVentoy.ps1, Test-WinIsoOutput.ps1, Repair-WinIsoMounts.ps1, WinIso.Common.psm1
payload/     Deploy-Apps.ps1, Undo-Tweaks.ps1, SetupComplete.cmd   (попадают в образ)
unattend/    autounattend.template.xml
ventoy/      ventoy_banner.py, base-theme/ (Ventoy 1.1.18, GPLv3), draft-banner.png, staged/
tests/       Run-Tests.ps1, test_ventoy_banner.py, synthetic-iso-test.sh, qemu-ventoy-screenshot.sh
docs/        REPORT.md, img/
```
