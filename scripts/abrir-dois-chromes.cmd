@echo off
setlocal

set "CHROME=C:\Program Files\Google\Chrome\Application\chrome.exe"

if not exist "%CHROME%" (
    set "CHROME=C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
)

if not exist "%CHROME%" (
    echo Google Chrome nao encontrado.
    echo Verifique o caminho de instalacao do Chrome.
    pause
    exit /b 1
)

start "" "%CHROME%" --profile-directory="Default" --new-window --start-maximized
timeout /t 1 /nobreak >nul
start "" "%CHROME%" --profile-directory="Profile 2" --new-window --start-maximized
timeout /t 1 /nobreak >nul
start "" /max "C:\Windows\explorer.exe" "\\wsl.localhost\Ubuntu-22.04-D\home\daniel\Code"

endlocal
exit /b 0