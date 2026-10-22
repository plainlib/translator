@echo off
setlocal

set "LAZARUS=C:\lazarus"
set "LRJ=src\formconfig.lrj"
set "POT=locale\formconfig.pot"

"%LAZARUS%\tools\updatepofiles.exe" "%LRJ%" "%POT%"

if errorlevel 1 (
    echo Failed to update POT.
    pause
    exit /b 1
)

echo POT updated successfully.
pause