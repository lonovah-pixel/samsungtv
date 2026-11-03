@echo off
rem Копирует тему "DNS" на флешку Ventoy.
rem Запуск: install_theme.cmd E:    (E: - буква раздела Ventoy на флешке)
rem Без аргумента скрипт сам ищет диск с меткой "Ventoy".
chcp 65001 >nul
setlocal
set "SRC=%~dp0ventoy"
set "DRV=%~1"

if "%DRV%"=="" (
  for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "(Get-Volume -FileSystemLabel Ventoy -ErrorAction SilentlyContinue | Select-Object -First 1).DriveLetter"`) do set "DRV=%%D:"
)
if "%DRV%"=="" (
  echo Не найдена флешка Ventoy. Укажите букву диска: install_theme.cmd E:
  exit /b 1
)
set "DRV=%DRV:~0,2%"

if not exist "%DRV%\" (
  echo Диск %DRV% не найден.
  exit /b 1
)

if exist "%DRV%\ventoy\ventoy.json" (
  echo На флешке уже есть ventoy.json - сохраняю копию в ventoy.json.bak
  copy /y "%DRV%\ventoy\ventoy.json" "%DRV%\ventoy\ventoy.json.bak" >nul
)

xcopy "%SRC%" "%DRV%\ventoy\" /e /i /y /q >nul || (echo Ошибка копирования & exit /b 1)
echo Готово: тема DNS установлена на %DRV%
endlocal
