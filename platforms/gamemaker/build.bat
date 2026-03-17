@echo off
REM Build script for Colyseus Game Maker Extension (Windows)
REM This script builds the Colyseus SDK for all Game Maker supported platforms
REM and configures the extension .yy for Windows.

setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0

echo Building Colyseus Native SDK for Game Maker...
echo.

REM Check if Zig is installed
where zig >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo Error: Zig is not installed. Please install Zig from https://ziglang.org/download/
    exit /b 1
)

REM Default values
set BUILD_ALL=false
set OPTIMIZE=ReleaseFast

REM Parse arguments
:parse_args
if "%~1"=="" goto end_parse
if /i "%~1"=="--all" (
    set BUILD_ALL=true
    shift
    goto parse_args
)
if /i "%~1:~0,11%"=="--optimize=" (
    set OPTIMIZE=%~1:~11%
    shift
    goto parse_args
)
if /i "%~1"=="--help" (
    echo Usage: %~nx0 [OPTIONS]
    echo.
    echo Options:
    echo   --all              Build for all Game Maker platforms (Windows, macOS, Linux)
    echo   --optimize=MODE    Set optimization mode (Debug, ReleaseFast, ReleaseSmall, ReleaseSafe)
    echo   --help             Show this help message
    echo.
    exit /b 0
)
echo Unknown option: %~1
echo Use --help to see available options
exit /b 1

:end_parse

REM Build command
set BUILD_CMD=zig build -Doptimize=%OPTIMIZE%

if "%BUILD_ALL%"=="true" (
    set BUILD_CMD=!BUILD_CMD! -Dall=true
    echo Building for all platforms...
) else (
    echo Building for native platform...
)

echo Command: !BUILD_CMD!
echo.

REM Execute build
!BUILD_CMD!

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Build failed!
    exit /b 1
)

echo.
echo Build completed successfully!
echo.
echo Output libraries are in: zig-out\lib\
echo.

REM List built files
dir /s /b zig-out\lib\*.dll zig-out\lib\*.dylib zig-out\lib\*.so 2>nul

REM =========================================================================
REM Configure extension .yy for Windows
REM =========================================================================
REM GameMaker only loads the FIRST kind:1 (native) file entry, ignoring
REM copyToTargets. Set colyseus.dll as the native filename so GameMaker
REM loads the correct DLL on Windows.

set EXT_YY=%SCRIPT_DIR%example\BlankProject\extensions\Colyseus_SDK\Colyseus_SDK.yy

if not exist "%EXT_YY%" (
    echo.
    echo Warning: Extension .yy not found — skipping platform configuration.
    goto :done
)

where jq >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Warning: jq not found — skipping .yy configuration. Install jq to auto-configure.
    goto :done
)

where perl >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Warning: perl not found — skipping .yy configuration.
    goto :done
)

echo.
echo === Configuring extension .yy for colyseus.dll ===

REM Fix trailing commas and update the .yy
perl -0777 -pe "1 while s/,(\s*[\]\}])/$1/g" "%EXT_YY%" | jq ".files[0].filename = \"colyseus.dll\" | .files[0].copyToTargets = -1 | .files[0].ProxyFiles = []" > "%EXT_YY%.tmp"
if %ERRORLEVEL% EQU 0 (
    move /y "%EXT_YY%.tmp" "%EXT_YY%" >nul
    echo Set native file entry to: colyseus.dll
    echo Done.
) else (
    echo Warning: Failed to update .yy file.
    del "%EXT_YY%.tmp" 2>nul
)

:done
endlocal
