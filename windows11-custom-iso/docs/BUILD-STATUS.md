# Статус сборки: сессия 2026-11-03

**Итог: готовый ISO не создан.** `output/Windows11-Pro-RU-Custom.iso` не существует, поэтому нет ни его размера, ни SHA-256, ни ссылки на скачивание. Создан и проверен проект сборки, который готов к продолжению.

## 1. Проверка среды (фактические результаты)

| Параметр | Значение |
|---|---|
| ОС | Ubuntu 24.04.5 LTS, облачный контейнер (не Windows, не WSL) |
| Права | root (uid=0) |
| CPU / RAM | 4 vCPU / 15 ГБ |
| Свободное место | около 30 ГБ (выделенная квота сессии) |
| DISM / Windows ADK / Oscdimg | **нет**: хоста Windows нет, interop-доступа к Windows нет |
| Виртуализация | **нет**: `/dev/kvm` отсутствует, флагов vmx/svm нет. Установить Windows в VM с UEFI, Secure Boot и TPM нельзя |
| Установлено для запасной ветки | PowerShell 7.6.9, wimlib-imagex 1.14.4, xorriso 1.5.6, p7zip 16.02, osslsigncode |

Исходный журнал проверки: [session-2026-11-03/](session-2026-11-03/).

## 2. Блокеры

1. **Сетевая политика среды запрещает источники.** Прокси отвечает `403` на CONNECT к хостам:
   `massgrave.dev`, `drive.massgrave.dev`, `software-static.download.prss.microsoft.com`, `download.microsoft.com`, `go.microsoft.com`, `learn.microsoft.com`, `www.7-zip.org`, `download.videolan.org`, `get.videolan.org`, `download-installer.cdn.mozilla.net`, `ftp.mozilla.org`, `www.mozilla.org`, `notepad-plus-plus.org`; ещё `api.github.com` (HTTP 403).
   Поэтому не удалось получить ни ссылку на ISO и его эталонный хеш, ни сам ISO, ни установщики программ. Источник молча не подменялся.
2. **Нет Windows-среды для эталонного пути** (DISM + Oscdimg) и нет аппаратной виртуализации для VM-теста.

Реальный запуск `build.ps1` в этой среде остановился на шаге «Source ISO» с сообщением о том, что источник не задан ([журнал](session-2026-11-03/build-20261103-204605.log)). Отдельная проверка загрузчиков программ получила 403 для всех четырёх.

## 3. Что проверено (и чего это НЕ доказывает)

| Проверка | Результат | Что доказывает |
|---|---|---|
| Разбор всех `.ps1` парсером PowerShell 7.6 | без ошибок | только синтаксис |
| `Invoke-SyntheticPipelineTest.ps1`: Linux-ветка на синтетическом «ISO» (случайные загрузочные файлы, WIM с 3 фиктивными редакциями) | 23/23 PASS | Остановка при несовпадении SHA-256 источника; выбор индекса по `EditionId`, архитектуре и языку (нашёлся индекс 2); экспорт; внедрение полезной нагрузки (CRLF у `.cmd`); разбиение на SWM и `wimlib verify`; определение исходного UEFI-образа (`efisys_EX.bin`, а не `efisys.bin`); побайтное совпадение El Torito; `xorriso -check_md5_r`; `.sha256`; `autounattend.xml` и `ei.cfg` |
| `Invoke-PostInstallLogicTest.ps1`: пост-установка с заглушками командлетов Windows | 13/13 PASS | Ошибка → задача повтора и сохранённые установщики; успех → удаление задачи и установщиков; повторный запуск идемпотентен; после `maxAttempts` задача отключается |
| Ошибки, найденные тестами и исправленные | 4 | Подмена `$Trigger` из-за динамической области видимости (журнал на целевой системе был бы искажён); склейка строк при правке разбора подписи; `Get-Command 7z` возвращал 2 пути; неверная интерпретация вывода osslsigncode |

**Не проверено:** Windows-ветка (DISM, Oscdimg, `Mount-DiskImage`); загрузка ISO в UEFI и BIOS; установка Windows; тихая установка настоящих 7-Zip, VLC, Firefox и Notepad++; применение настроек и удаление Appx на Windows; работа Windows Update и средств защиты после установки. **Ни один ISO не является протестированным.**

## 4. Как продолжить

**Вариант A (рекомендуется): ПК с Windows 10/11.** Установите Windows ADK (Deployment Tools), заполните `source` в `config.json` по README и выполните `build.ps1` от администратора. Затем выполните `scripts/New-TestVM.ps1` и `scripts/Test-Deployment.ps1`.

**Вариант B: эта облачная среда.** В настройках окружения (Network access → Allowed domains) разрешите хосты из п. 2: как минимум узел загрузки ISO, `www.7-zip.org`, `download.videolan.org`, `product-details.mozilla.org`, `download-installer.cdn.mozilla.net`, `api.github.com`, `github.com`, `release-assets.githubusercontent.com`. Укажите в `config.json` URL ISO и SHA-256 от Microsoft и выполните `pwsh -NoProfile -File ./build.ps1`. Получится ISO из запасной ветки (xorriso/wimlib, без Oscdimg), без VM-теста. Инструкция по сетевым настройкам: <https://code.claude.com/docs/en/cloud-environments#network-access>.

**Вариант C:** передать готовый оригинальный ISO и указать его в `source.localIsoPath` вместе с эталонным SHA-256.
