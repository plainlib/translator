@echo off
setlocal

set "LAZARUS=C:\lazarus"
set "LRJ=src\formconfig.lrj"
set "RSJ=lib\x86_64-win64\formconfig.rsj"
set "POT=locale\formconfig.pot"

if not exist "%RSJ%" (
    echo Cannot find %RSJ%
    echo Compile the package first to generate it.
    pause
    exit /b 1
)

"%LAZARUS%\tools\updatepofiles.exe" "%LRJ%" "%RSJ%" "%POT%"

if errorlevel 1 (
    echo Failed to update POT.
    pause
    exit /b 1
)

echo POT updated successfully.
pause