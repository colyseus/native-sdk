@echo off
REM Build script for Colyseus Game Maker Extension (Windows)
REM This script builds the Colyseus SDK for all Game Maker supported platforms

setlocal enabledelayedexpansion

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

endlocal

