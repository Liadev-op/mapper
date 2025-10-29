@echo off
setlocal
set "URL=https://raw.githubusercontent.com/Liadev-op/mapper/main/mapper.ps1"
set "DEST=%ProgramData%\Liadev\RedDriveMapper\mapper.ps1"

mkdir "%ProgramData%\Liadev\RedDriveMapper" 2>nul
curl.exe -fL "%URL%" -o "%DEST%" || (echo Error descargando & exit /b 1)

:: (Opcional) verifica integridad: poné el SHA256 real de mapper.ps1
:: set "HASH=PEGAR_SHA256_AQUI"
:: for /f "tokens=1" %%H in ('powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 '''%DEST%''').Hash"') do set ACT=%%H
:: if /I not "%ACT%"=="%HASH%" (echo Hash distinto. Abortando. & exit /b 1)

powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%DEST%"
