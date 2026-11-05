@echo off
setlocal enabledelayedexpansion

set "LAZARUS=C:\lazarus"
set "ITEMS=formconfig formsearch"

for %%N in (%ITEMS%) do (
    set "LRJ=src\%%N.lrj"
    set "RSJ=lib\x86_64-win64\%%N.rsj"
    set "POT=locale\%%N.pot"

    if not exist "!RSJ!" (
        echo Cannot find !RSJ!
        echo Compile the package first to generate it.
        pause
        exit /b 1
    )

    "%LAZARUS%\tools\updatepofiles.exe" "!LRJ!" "!RSJ!" "!POT!"

    if errorlevel 1 (
        echo Failed to update POT for %%N.
        pause
        exit /b 1
    )
)

echo POT updated successfully.
pause