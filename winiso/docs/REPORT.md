# Отчёт WinIso — 2026-11-03

## 1. Проверка среды

| Что | Результат |
|---|---|
| Среда выполнения | Облачный Linux-контейнер Ubuntu 24.04, 4 CPU, 15 ГБ ОЗУ, 31 ГБ свободно |
| Оригинальный ISO Windows | **Не найден** (путь не указан, файлов `.iso` в среде нет) |
| Флешка Ventoy | **Недоступна** (физических USB-устройств нет) |
| DISM / Windows ADK / `oscdimg` | **Нет** — это Linux; сборка ISO штатными средствами Microsoft здесь невозможна |
| Виртуализация | `/dev/kvm` нет; QEMU (TCG) и OVMF установлены — хватает для загрузчика Ventoy, но не для установки Windows |
| Установлено для проверок | PowerShell 7.6, QEMU 8.2, OVMF, xorriso, wimlib, p7zip, mtools, exfat-fuse, Ventoy 1.1.18 (SHA-256 сверен с `sha256.txt` релиза) |
| Документация | `learn.microsoft.com` и `ventoy.net` **закрыты сетевой политикой** сессии. Использованы первоисточники на GitHub: исходники Ventoy (`ventoy_plugin.c`, `grub.cfg`, встроенная тема), документация winget (`MicrosoftDocs/windows-dev-docs`) и коды ошибок winget (`AppInstallerErrors.h`). DISM, `oscdimg`, `SetupComplete.cmd`, `FirstLogonCommands` — по известной документации Microsoft; перед первой сборкой сверьте страницы из раздела 6 |

## 2. Применяемые настройки (по умолчанию, консервативно)

**Удаление предустановленных приложений** (DISM `Remove-AppxProvisionedPackage`, всё возвращается из Store):
BingNews, BingWeather, BingSearch, GetHelp, Getstarted, MicrosoftSolitaireCollection, MicrosoftOfficeHub,
WindowsFeedbackHub, Todos, PowerAutomateDesktop, Clipchamp, MicrosoftFamily, MSTeams, Cortana (если есть).
Выключены по умолчанию: Xbox, Game Bar, Карты, новый Outlook. Защищено от удаления: Store, App Installer (winget),
Безопасность Windows, фреймворки (VCLibs, UI.Xaml, .NET Native, WindowsAppRuntime), Терминал, Блокнот, Paint,
Калькулятор, Фотографии, Ножницы, кодеки, виджеты.

**Реестр** (8 значений; назначение, побочный эффект и откат — в `config/tweaks.json`):
автоустановка продвигаемых приложений, предложения в «Пуске», советы, экран приветствия, рекомендации в «Параметрах»,
рекомендации `Start_IrisRecommendations` (профиль по умолчанию); политики «Отключить идентификатор рекламы» и
«Выключить возможности потребителя» (последняя действует только на Enterprise/Education). Удаление автозапуска
OneDriveSetup подготовлено, но выключено.

**Не изменяется**: Defender, брандмауэр, UAC, Windows Update, восстановление, файл подкачки, службы, аппаратные
требования, выбор диска. Нет активаторов, ключей, паролей, учётных записей. Запрещённые пути блокируются валидатором
(проверено тестами).

## 3. Программы и версии

Список программ ещё не прислан — `config/apps.json` пуст. Версии появятся в `<work_dir>\logs\build-report-*.json`
после `Get-Installers.ps1` (версия файла, SHA-256, издатель подписи). `apps.example.json` показывает формат:
VC++ Redistributable и Firefox MSI (офлайн), VLC и Notepad++ (winget).

## 4. Результаты проверок

| Проверка | Что подтверждает | Результат |
|---|---|---|
| `tests/Run-Tests.ps1` (pwsh 7.6, Linux) | синтаксис всех `.ps1/.psm1`, UTF-8 BOM, CRLF `.cmd`; валидация конфигурации; отказ на удаление защищённых пакетов и на твики Defender/UAC/Update; winget только на firstlogon; циклы зависимостей; `autounattend` без разметки дисков/ключей/учёток; `-PlanOnly` (код 2 при неполной, 0 при полной конфигурации); отказ реальной сборки вне Windows | **37/37** |
| `tests/test_ventoy_banner.py` | новая тема с сохранением других ключей `ventoy.json`; побайтный откат; замена только `desktop-image` в существующей теме; битый JSON не трогается; битая ссылка на тему останавливает; неподходящий PNG отклоняется; целостность копии темы | **9/9** |
| `tests/synthetic-iso-test.sh` | верификатор ISO принимает корректный синтетический образ (34 проверки) и отклоняет образ с `DiskConfiguration` | **пройдено** |
| Ventoy на виртуальной флешке | Ventoy 1.1.18 установлен `Ventoy2Disk.sh` на **файл-образ** (loop), с заранее заданными `control` и `menu_alias`; `apply` с неверным токеном — отказ; с верным — запись; загрузка в QEMU **BIOS и UEFI**: новый баннер, кириллический alias и таймаут на месте ([BIOS](img/ventoy-test-bios.png), [UEFI](img/ventoy-test-uefi.png)); `rollback` вернул `ventoy.json` байт-в-байт | **пройдено** |

**Не выполнено и статическими проверками не заменяется:**

* сборка ISO (нет исходного ISO, параметров и Windows с ADK);
* реальные операции DISM (`Export/Mount/Remove-AppxProvisionedPackage`, `reg load`, `oscdimg`) — код не исполнялся на Windows;
* `Deploy-Apps.ps1`, `Undo-Tweaks.ps1`, `Get-Installers.ps1` — только проверка синтаксиса;
* загрузка ISO, установка Windows и программ в ВМ;
* запись баннера на **вашу** флешку (носитель недоступен; баннер черновой).

## 5. Ограничения и замечания

* `SetupComplete.cmd` не запускается при OEM-ключе (кроме Enterprise) — подстраховано этапом FirstLogon.
* `FirstLogonCommands` выполняются для первого входа пользователя, созданного в OOBE; если это не администратор,
  установка не выполнится (сценарий запишет это в журнал) — запустите `Deploy-Apps.ps1 -Stage FirstLogon` от администратора.
* Программы `winget` требуют интернет на целевом ПК; полностью автономной будет только установка `offline`-программ.
* Копия темы взята из Ventoy 1.1.18; при другой версии Ventoy на флешке возможны мелкие визуальные отличия.
* Для образа Windows новее сборочной ОС используйте DISM из соответствующего ADK (`tools.dism`).

## 6. Что сделать на Windows-машине (проверочный список)

1. Сверить с актуальной документацией: DISM app package servicing, oscdimg command-line options,
   «Add a custom script to Windows Setup» (SetupComplete), Unattend `FirstLogonCommands`, Ventoy Theme Plugin.
2. Заполнить `config/build.json` и `config/apps.json`; `Build-WinIso.ps1 -PlanOnly` → код 0.
3. `Get-Installers.ps1 -Pin`, затем `Build-WinIso.ps1`; сохранить `*.sha256`, журнал и `build-report-*.json`.
4. Тест в Hyper-V (поколение 2, vTPM, Secure Boot): установка с выбором диска вручную, OOBE, первый вход,
   `C:\ProgramData\WinIsoDeploy\logs`, `Deploy-Apps.ps1 -Stage Status`, повторный запуск — без дубликатов,
   проверка, что Defender/Firewall/UAC/Update включены, `Undo-Tweaks.ps1 -WhatIf`.
5. Ventoy: `inspect` → `plan` → подтвердить носитель → `apply`; проверить меню (или QEMU-скрипт с `snapshot=on`);
   в меню Ventoy F5 → Check plugin json.
