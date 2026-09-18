@echo off
setlocal enabledelayedexpansion

:: =============================================================================
:: program.bat - Load bitstream onto AX7010 over USB JTAG via Vivado
::
:: Usage:
::   .\scripts\program.bat sim
::   .\scripts\program.bat tracker
::   .\scripts\program.bat bringup
:: =============================================================================

set "SCRIPT_DIR=%~dp0"
set "REPO_DIR=%SCRIPT_DIR%.."

set "VARIANT=%~1"
if "%VARIANT%"=="" set "VARIANT=sim"

set "VIVADO="
where vivado >nul 2>&1
if %ERRORLEVEL% equ 0 (
    for /f "delims=" %%I in ('where vivado') do (
        if not defined VIVADO set "VIVADO=%%I"
    )
)

if not defined VIVADO (
    if exist "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" (
        set "VIVADO=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
    ) else if exist "C:\Xilinx\2025.2\Vivado\bin\vivado.bat" (
        set "VIVADO=C:\Xilinx\2025.2\Vivado\bin\vivado.bat"
    ) else if exist "C:\Xilinx\Vivado\2025.2\bin\vivado.bat" (
        set "VIVADO=C:\Xilinx\Vivado\2025.2\bin\vivado.bat"
    )
)

if not defined VIVADO (
    echo ERROR: vivado not found in PATH or standard AMD / Xilinx install paths. >&2
    exit /b 1
)

if not exist "%REPO_DIR%\build" mkdir "%REPO_DIR%\build"

cd /d "%REPO_DIR%\build"
echo Programming bitstream variant: %VARIANT%...
call "!VIVADO!" -mode batch -nojournal -log "%REPO_DIR%\build\program_%VARIANT%.log" -source "%REPO_DIR%\scripts\program.tcl" -tclargs "%VARIANT%"
