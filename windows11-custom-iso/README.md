# Windows 11 Pro RU: воспроизводимая сборка установочного ISO

Проект собирает установочный образ **Windows 11 Pro x64, русский язык** (стабильный выпуск, не Insider) с офлайн-установщиками **7-Zip, VLC, Firefox, Notepad++** и умеренной оптимизацией. Результат: `output/Windows11-Pro-RU-Custom.iso`, а также `.sha256` и `build-manifest.json`.

> **Статус на 2026-11-03: ISO в этой среде НЕ собран.** Причины, проведённые проверки и способ продолжить описаны в [docs/BUILD-STATUS.md](docs/BUILD-STATUS.md).

## Состав

| Путь | Назначение |
|---|---|
| `build.ps1` | Основной сценарий: проверка среды → исходный ISO → программы → образ → ISO → проверки |
| `config.json` | Параметры Windows, источника, программ, удаляемых Appx и настроек |
| `scripts/BuildCommon.ps1` | Журнал, запуск внешних команд с проверкой кода возврата, загрузка, SHA-256, Authenticode, разбор El Torito |
| `scripts/AppInstallers.ps1` | Определение версий и URL на сайтах производителей, загрузка, проверка хеша и подписи |
| `scripts/Test-BuildEnvironment.ps1` | Проверка среды (только чтение) |
| `scripts/payload/` | То, что попадает в образ: `SetupComplete.cmd`, `CustomImage/Invoke-PostInstall.ps1`, `Register.cmd`, `autounattend.xml` |
| `scripts/New-TestVM.ps1` | Тестовая VM Hyper-V: Gen2, UEFI, Secure Boot, vTPM, новый VHDX |
| `scripts/Test-Deployment.ps1` | Приёмочная проверка внутри установленной системы |
| `scripts/tests/` | Тесты механики сборки и логики пост-установки на синтетических данных (Linux/pwsh) |
| `downloads/` `logs/` `output/` | Исходники и установщики, журналы, результат (в git не хранятся) |

## Требования

**Эталонный путь (рекомендуется): Windows 10/11 x64**
- Windows PowerShell 5.1 (`powershell.exe`), запущенный от администратора;
- модуль DISM (встроен) и **Windows ADK для Windows 11, компонент Deployment Tools** (даёт `oscdimg.exe`; путь находится автоматически или задаётся в `iso.oscdimgPath`);
- не меньше 50 ГБ свободного места на диске проекта; `curl.exe` (встроен с Windows 10 1803);
- для VM-теста нужен Hyper-V.

**Запасной путь: Linux или WSL (PowerShell 7, `wimtools`, `xorriso`, `p7zip-full`, `osslsigncode`, `curl`; от 25 ГБ свободного места)**
По сравнению с эталоном он отличается так: DISM не используется, ISO собирается xorriso вместо Oscdimg, файловая система ISO9660+Joliet (без UDF), `install.wim` больше 4 ГиБ делится на `install*.swm`. Эти отличия записываются в манифест. Если вы работаете в WSL и доступен `powershell.exe` хоста, лучше запустить `build.ps1` в Windows.

## Подготовка исходного ISO (обязательно)

1. На странице <https://massgrave.dev/genuine-installation-media> (раздел Windows 11) найдите **ru-ru, x64, consumer editions** текущего стабильного выпуска. Активаторы и скрипты с сайта не нужны и не используются.
2. Найдите SHA-256 этого файла, опубликованный Microsoft. Список хешей выводится на <https://www.microsoft.com/ru-ru/software-download/windows11> после выбора языка, в блоке проверки загрузки. Если используете ISO, скачанный напрямую с этой страницы, укажите его через `localIsoPath`.
3. Заполните `config.json`:
   ```json
   "source": {
     "downloadUrl": "<фактическая ссылка на .iso>",
     "pageUrl": "https://massgrave.dev/genuine-installation-media",
     "expectedSha256": "<SHA-256 от Microsoft>",
     "expectedSha256Reference": "<где опубликован хеш>"
   }
   ```
   Вместо `downloadUrl` можно указать `localIsoPath` (путь к своему ISO).

Если хеш не совпадает, сборка **останавливается** и файл не используется. Если эталонного хеша нет, сборка тоже останавливается. Ключ `-AllowUnverifiedSource` позволяет продолжить сознательно, но в манифесте источник тогда помечается как непроверенный. Например, у ISO, созданного Media Creation Tool, опубликованного хеша нет.

## Запуск

```powershell
# Windows, PowerShell от имени администратора, в папке проекта
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -CheckOnly   # только проверка среды
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

```bash
# Linux/WSL (запасной путь)
pwsh -NoProfile -File ./build.ps1
```

Ключи: `-Backend Auto|Windows|Linux`, `-CheckOnly`, `-AllowUnverifiedSource`, `-KeepWorkDir`.
Журналы пишутся в `logs/build-*.log` и `logs/environment-*.json`, при ошибке ещё и в `logs/build-manifest-failed-*.json`.

## Что делает сборка

1. **Среда.** Проверяются ОС, права, место, DISM, Oscdimg и Hyper-V; на Linux ещё wimlib, xorriso, 7z, KVM и WSL.
2. **Источник.** ISO загружается с докачкой и повторами, проверяется по SHA-256 эталона, имя файла проверяется на признаки Insider-сборки. Проверяются подписи Microsoft у `setup.exe`, `efi/boot/bootx64.efi` и `bootmgr.efi`.
3. **Программы.** Установщики загружаются с сайтов производителей и проверяются (см. таблицу ниже).
4. **Распаковка ISO.** На Windows образ подключается через `Mount-DiskImage` только для чтения и копируется robocopy; на Linux распаковывается 7z.
5. **Выбор редакции по метаданным.** Ищется ровно один образ, у которого `EditionId=Professional`, архитектура x64 и язык ru-RU (`Get-WindowsImage` или XML WIM). Номер индекса нигде не задан заранее.
6. **Экспорт** этой редакции в отдельный `install.wim` (`Export-WindowsImage -CompressionType max -CheckIntegrity`; из ESD тоже работает).
7. **Полезная нагрузка** копируется в `Windows\Setup\Scripts` внутри образа через DISM mount/commit. На Windows дополнительно сохраняется список предустановленных Appx в `logs/provisioned-appx-*.txt`. При любой ошибке монтирование отменяется с `-Discard`.
8. **Корень ISO.** Добавляются `autounattend.xml` (только проход specialize, см. ниже) и `sources\ei.cfg` (только `EditionID=Professional`, `Channel=Retail`, без ключа).
9. **ISO.** Определяется, какой именно `efisys*.bin` использует исходный ISO: образ El Torito сравнивается побайтно с `efisys.bin`, `efisys_EX.bin` и т. д. Этот же файл передаётся Oscdimg (`-m -o -u2 -udfver102 -bootdata:2#p0,e,b<etfsboot.com>#pEF,e,b<efisys*.bin>`). Загрузочные компоненты не меняются.
10. **Проверка результата.** Загрузочные записи UEFI и BIOS побайтно совпадают с исходными файлами; присутствуют обязательные файлы. Хеш `install.wim` внутри ISO равен хешу подготовленного; в образе один индекс нужной редакции (на Linux вместо этого `wimlib verify` и `xorriso -check_md5_r`). Затем считается SHA-256 ISO и записывается манифест.
11. Папка `work/` удаляется только после успеха. Удаляются только файлы этого проекта.

## Программы

Версия определяется **в момент сборки** по официальному источнику (`"version": "latest"`), её можно закрепить конкретным значением. Фактические версии, URL, SHA-256 и результат проверки подписи записываются в `downloads/apps/manifest.json` и `output/build-manifest.json`.

| Программа | Источник | Эталон хеша | Подпись Authenticode | Тихая установка (контекст SYSTEM) |
|---|---|---|---|---|
| 7-Zip (x64 MSI) | `https://www.7-zip.org/a/7zXXXX-x64.msi`, версия со страницы download.html | производитель хеши не публикует, после первой проверки закрепите `expectedSha256` | производитель не подписывает, проверка необязательна | `msiexec /i … /qn /norestart /l*v <журнал>` |
| VLC (x64 EXE) | `https://download.videolan.org/pub/videolan/vlc/<v>/win64/`, версия из `…/vlc/last/win64/` | файл `.sha256` рядом с установщиком | обязательна, подписант `VideoLAN` | `/L=1049 /S` (NSIS, русский язык) |
| Firefox (x64 MSI, ru) | `https://download-installer.cdn.mozilla.net/pub/firefox/releases/<v>/win64/ru/`, версия из product-details.mozilla.org | `SHA256SUMS` выпуска | обязательна, `Mozilla Corporation` | `msiexec /i … /qn /norestart /l*v <журнал>` |
| Notepad++ (x64 EXE) | официальный репозиторий GitHub (на него ведёт notepad-plus-plus.org) | digest ресурса выпуска из API GitHub | обязательна, `Notepad++` или `Don HO` | `/S` (NSIS) |

Подпись проверяется через `Get-AuthenticodeSignature` на Windows и `osslsigncode` на Linux. Недействительная подпись, чужой подписант или отсутствие обязательной подписи прерывают сборку.

### Когда и как устанавливаются программы

Обычные EXE и MSI **не** устанавливаются в WIM. Установщики лежат в образе в `C:\Windows\Setup\Scripts\CustomImage\Apps` и запускаются **после развёртывания Windows**:

1. `SetupComplete.cmd` выполняется Windows Setup от имени SYSTEM после установки, **до первого входа пользователя**. Он запускает `Invoke-PostInstall.ps1`.
2. Страховка. `autounattend.xml` содержит только одну команду прохода *specialize*, которая регистрирует задачу планировщика `CustomImage-PostInstall` (SYSTEM, при запуске, с задержкой 1 мин). Нужна на случай, если Setup не выполнит `SetupComplete.cmd` (так бывает при установке с OEM-ключом). Сам сценарий тоже регистрирует эту задачу при каждом незавершённом запуске.
3. Сценарий выполняет три шага с отдельными отметками о завершении: настройки → удаление Appx → программы. Уже установленные программы определяются по файлу и не переустанавливаются. Код 1618 (идёт другая установка) приводит к повтору через 60 с. Коды 3010 и 1641 означают успех с отложенной перезагрузкой, принудительной перезагрузки нет.
4. При полном успехе задача удаляется, установщики стираются (`postInstall.deleteInstallersAfterSuccess`), сценарий завершается. При ошибке задача остаётся и повторяет попытку при следующей загрузке, но не больше `maxAttempts` (5 по умолчанию), после чего отключается.
5. Журналы: `C:\ProgramData\CustomImage\Logs\PostInstall.log`, MSI-журналы каждой программы, `SetupComplete.log`. Состояние: `C:\ProgramData\CustomImage\state.json`.

Пароли не хранятся, автоматический вход не включается. Выбор диска, учётная запись, язык и ключ продукта остаются интерактивными.

## Изменения Windows

Все изменения применяются **после развёртывания** сценарием пост-установки, кроме добавления файлов в образ. Параметры `HKLM\...\Policies` в «Параметрах» отображаются как «управляется организацией»; это нормально для политик.

### Настройки (config.json → `tweaks`)

| ID | Раздел | Назначение | Применимость к Windows 11 Pro 24H2/25H2 | Отмена |
|---|---|---|---|---|
| `adv-id-policy` | HKLM Policies `AdvertisingInfo\DisabledByGroupPolicy=1` | Отключение рекламного идентификатора | Политика поддерживается в Pro | Удалить значение |
| `search-highlights` | HKLM Policies `Windows Search\EnableDynamicContentInWSB=0` | Отключение «главного в поиске» (продвигаемый контент) | Поддерживается в Pro | Удалить значение |
| `widgets-off` | HKLM Policies `Dsh\AllowNewsAndInterests=0` | **Выключено по умолчанию**: отключение доски виджетов | Поддерживается | Удалить значение |
| `cdm-silent-apps` | Default user `ContentDeliveryManager\SilentInstalledAppsEnabled=0` | Не устанавливать продвигаемые приложения автоматически | Пользовательский параметр | Значение 1 или удалить в HKCU |
| `cdm-preinstalled`, `cdm-oem-preinstalled` | `PreInstalledAppsEnabled=0`, `OemPreInstalledAppsEnabled=0` | Не создавать рекламные заглушки приложений | Пользовательский параметр | Значение 1 или удалить |
| `cdm-system-pane`, `cdm-start-suggestions` | `SystemPaneSuggestionsEnabled=0`, `SubscribedContent-338388Enabled=0` | Без предложений приложений в «Пуске» | Пользовательский параметр | Значение 1 |
| `cdm-tips`, `cdm-softlanding` | `SubscribedContent-338389Enabled=0`, `SoftLandingEnabled=0` | Без советов и рекомендаций при работе с Windows | «Параметры → Уведомления» | Включить переключатель |
| `cdm-welcome` | `SubscribedContent-310093Enabled=0` | Без экрана приветствия после обновлений | «Параметры → Уведомления» | Включить переключатель |
| `cdm-settings-suggest-1..3` | `SubscribedContent-338393/353694/353696Enabled=0` | Без рекомендуемого контента в «Параметрах» | «Конфиденциальность → Общие» | Включить переключатель |
| `cdm-lockscreen-overlay`, `cdm-lockscreen-tips` | `RotatingLockScreenOverlayEnabled=0`, `SubscribedContent-338387Enabled=0` | Без «интересных фактов и советов» на экране блокировки | «Персонализация → Экран блокировки» | Включить флажок |
| `scoobe` | `UserProfileEngagement\ScoobeSystemSettingEnabled=0` | Без предложений «завершить настройку устройства» | «Параметры → Уведомления» | Включить переключатель |
| `start-iris` | `Explorer\Advanced\Start_IrisRecommendations=0` | Без рекомендаций советов и новых приложений в «Пуске» | 22H2 и новее | «Персонализация → Пуск» |
| `start-account-notifications` | `Start_AccountNotifications=0` | Без уведомлений учётной записи в «Пуске» | 23H2 и новее | «Персонализация → Пуск» |
| `explorer-sync-provider` | `ShowSyncProviderNotifications=0` | Без рекламных уведомлений поставщиков синхронизации в Проводнике | Пользовательский параметр | Параметры папок → Вид |
| `tailored-experiences` | `Privacy\TailoredExperiencesWithDiagnosticDataEnabled=0` | Без персонализированных предложений на основе диагностики | Пользовательский параметр | «Конфиденциальность → Общие» |

Параметры раздела «Default user» записываются в `C:\Users\Default\NTUSER.DAT` до первого входа и действуют для всех **новых** профилей. Windows может со временем менять некоторые значения `ContentDeliveryManager`; `Test-Deployment.ps1` проверяет их фактическое состояние.

**Сознательно не применялись**: `CloudContent\DisableWindowsConsumerFeatures` и `DisableSoftLanding` официально действуют только в Enterprise/Education; `HideRecommendedSection` предназначен только для SE/Enterprise/Education; телеметрия, службы, файл подкачки, таймеры, сетевые «ускорители» и электропитание не трогались.

### Удаляемые предустановленные приложения (`appxRemoval.packages`)

`Microsoft.BingNews`, `Microsoft.MicrosoftSolitaireCollection`, `Microsoft.MicrosoftOfficeHub`, `Microsoft.Todos`, `Microsoft.PowerAutomateDesktop`, `Clipchamp.Clipchamp`, `Microsoft.Getstarted` (Советы), `Microsoft.OutlookForWindows` (новый Outlook), `MSTeams`.

- Удаляется только то, что есть в образе, через `Remove-AppxProvisionedPackage -Online [-AllUsers]` до первого входа.
- **Проверка зависимостей.** Пакет не удаляется, если его объявляет зависимостью (`PackageDependency`) манифест любого другого предустановленного пакета.
- Пакеты из `appxRemoval.neverRemove` удалить нельзя: сборка выдаёт ошибку при пересечении списков. Туда входят Store, App Installer, Безопасность Windows, все Xbox и игровые компоненты, VCLibs, UI.Xaml, .NET Native, WindowsAppRuntime и кодеки.
- **Отмена**: любое из этих приложений можно снова установить из Microsoft Store.

### Что не меняется

Defender, брандмауэр, SmartScreen, UAC, Windows Update, Microsoft Store, App Installer, WinRE, .NET, компоненты Xbox и игр, службы, файл подкачки и обслуживание компонентов остаются как есть. Требования TPM и Secure Boot не обходятся. Ключи продукта и обход активации не добавляются.

### Изменения образа и носителя

- В ISO остаётся только редакция Pro. Это свойство носителя, на целевом ПК оно ничего не меняет. В остальном `install.wim` изменён только добавлением файлов в `Windows\Setup\Scripts`.
- `sources\ei.cfg` (`EditionID=Professional`, `Channel=Retail`) нужен, чтобы Setup не искал в образе редакцию, соответствующую ключу из прошивки (например, Home). **Активация**: Pro активируется только лицензией Pro (цифровой лицензией или вашим ключом). Если в прошивке ключ Home, Pro без своей лицензии активирована не будет.
- `autounattend.xml` содержит один проход *specialize* с регистрацией задачи; разделов windowsPE и OOBE в нём нет.

### Необратимые изменения

**По умолчанию нет.** Необязательный `image.componentCleanupResetBase=true` (выключен) выполняет `StartComponentCleanup /ResetBase`: после этого обновления, интегрированные в образ, удалить нельзя. Сборка выводит об этом предупреждение. Необязательный `image.enableNetFx3=true` (выключен) включает .NET 3.5 из `sources\sxs`; это обратимо через «Компоненты Windows».

## Проверка в VM (обязательна перед использованием на реальном ПК)

```powershell
# хост с Hyper-V, PowerShell от администратора
.\scripts\New-TestVM.ps1 -IsoPath .\output\Windows11-Pro-RU-Custom.iso -Start          # без сети
.\scripts\New-TestVM.ps1 -IsoPath .\output\Windows11-Pro-RU-Custom.iso -VMName W11-Net -SwitchName "Default Switch" -Start
```
Установите Windows в VM вручную. Скопируйте `scripts\Test-Deployment.ps1` в VM и после первого входа и одной перезагрузки выполните его от администратора:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Test-Deployment.ps1
```
Отчёт сохраняется в `C:\ProgramData\CustomImage\TestReport.md`. Проверяются: Pro и сборка, завершение пост-установки, удаление задачи, ошибки в журналах, установка и запуск четырёх программ, загрузка рабочего стола, Defender, брандмауэр, SmartScreen, UAC, службы Windows Update и поиск обновлений, Store, App Installer, winget, WinRE, Secure Boot, TPM, .NET и применённые настройки.

## Тесты механики (без Windows)

```bash
pwsh -NoProfile -File scripts/tests/Invoke-SyntheticPipelineTest.ps1   # Linux-конвейер на синтетическом «ISO»
pwsh -NoProfile -File scripts/tests/Invoke-PostInstallLogicTest.ps1    # повтор/завершение пост-установки (с заглушками)
```
Они проверяют только логику сценариев: Windows в них не участвует, и загрузочный носитель они не создают и не проверяют.

## Известные ограничения

- Windows-ветка (DISM + Oscdimg) и сценарии на целевой системе синтаксически проверены парсером PowerShell, но в этой среде **не запускались**: Windows-хоста здесь нет.
- ISO из Linux-ветки (ISO9660+Joliet, SWM, без UDF) не является гибридным образом для `dd` на USB. Флешку из него записывают Rufus или аналогичным средством.
- Если версии программ не закреплены, ISO, собранные в разные дни, могут содержать разные версии. Все фактические значения есть в манифесте.
- Удалённые приложения могут вернуться при обновлении функций Windows; это поведение Windows.
- Резервная регистрация задачи через `autounattend.xml` не проверялась в VM.
