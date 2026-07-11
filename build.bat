@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo ============================================
echo  AutoLiangDu Build Script
echo ============================================
echo.

set "ROOT=%~dp0"
set "OUTPUT=%ROOT%dist"

REM ---- Clean output directory ----
if exist "%OUTPUT%" rmdir /s /q "%OUTPUT%"
mkdir "%OUTPUT%"

REM ============================================
REM  Part 1: PC Client (Flutter Windows)
REM ============================================
echo [1/3] Building PC Client (Flutter Windows)...

where flutter >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Flutter SDK not found. Please install Flutter first.
    echo         https://docs.flutter.dev/get-started/install/windows
    goto :build_failed
)

cd /d "%ROOT%pc_app_new"

echo   -- flutter pub get (checks cached dependencies)...
call flutter pub get
if %ERRORLEVEL% neq 0 (
    echo [ERROR] flutter pub get failed.
    goto :build_failed
)

echo   -- flutter build windows --release...
call flutter build windows --release
if %ERRORLEVEL% neq 0 (
    echo [ERROR] flutter build failed.
    goto :build_failed
)

echo   -- Copying PC Client output...
set "FLUTTER_OUT=%ROOT%pc_app_new\build\windows\x64\runner\Release"
if exist "%FLUTTER_OUT%" (
    xcopy /e /i /y "%FLUTTER_OUT%" "%OUTPUT%\pc_client\" >nul
) else (
    echo [WARN] Flutter build output not found at %FLUTTER_OUT%
)

REM Copy DDC tool alongside the PC client
if exist "%ROOT%ddc_tool\DDCBrightness.exe" (
    copy /y "%ROOT%ddc_tool\DDCBrightness.exe" "%OUTPUT%\pc_client\" >nul
    echo   -- DDC tool bundled with PC Client.
)

cd /d "%ROOT%"
echo   -- PC Client done.
echo.

REM ============================================
REM  Part 2: ESP8266 Firmware (PlatformIO)
REM ============================================
echo [2/3] Building ESP8266 Firmware (PlatformIO)...

where pio >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [INFO] PlatformIO not found. Attempting to install via pip...
    pip install platformio
    if !ERRORLEVEL! neq 0 (
        echo [WARN] Failed to install PlatformIO. Skipping firmware build.
        echo        Install manually: pip install platformio
        goto :skip_mcu
    )
)

cd /d "%ROOT%auto_brightness_mcu"

echo   -- pio run (auto-resolves dependencies)...
call pio run
if %ERRORLEVEL% neq 0 (
    echo [ERROR] PlatformIO build failed.
    goto :build_failed
)

echo   -- Copying firmware...
set "FIRMWARE=%ROOT%auto_brightness_mcu\.pio\build\nodemcuv2\firmware.bin"
if exist "%FIRMWARE%" (
    copy /y "%FIRMWARE%" "%OUTPUT%\firmware\" >nul
    echo   -- firmware.bin copied.
) else (
    echo [WARN] firmware.bin not found at %FIRMWARE%
)

cd /d "%ROOT%"
echo   -- ESP8266 Firmware done.
:skip_mcu
echo.

REM ============================================
REM  Part 3: Sun Tracker (Python, optional)
REM ============================================
echo [3/3] Checking Sun Tracker (Python)...

where python >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [WARN] Python not found. Skipping Sun Tracker setup.
    echo        Install Python to use sun_tracker.py.
    goto :skip_python
)

echo   -- Checking suntime dependency...
pip list 2>nul | findstr /I suntime >nul
if %ERRORLEVEL% neq 0 (
    echo   -- suntime not found, installing...
    pip install suntime
    if !ERRORLEVEL! neq 0 (
        echo [WARN] Failed to install suntime. Skipping.
        goto :skip_python
    )
) else (
    echo   -- suntime already installed.
)

echo   -- Copying sun_tracker.py...
copy /y "%ROOT%sun_tracker.py" "%OUTPUT%\" >nul

cd /d "%ROOT%"
echo   -- Sun Tracker done.
:skip_python
echo.

REM ============================================
REM  Package summary
REM ============================================
echo ============================================
echo  Build complete!
echo ============================================
echo.
echo Output directory: %OUTPUT%
echo.
if exist "%OUTPUT%\pc_client"    echo   - PC Client     : %OUTPUT%\pc_client\auto_liangdu.exe
if exist "%OUTPUT%\firmware"     echo   - Firmware      : %OUTPUT%\firmware\firmware.bin
if exist "%OUTPUT%\sun_tracker.py" echo - Sun Tracker   : %OUTPUT%\sun_tracker.py
echo.
echo To run the PC Client:
echo   %OUTPUT%\pc_client\auto_liangdu.exe
echo.
echo To flash ESP8266:
echo   pio run --target upload --upload-port COM3 -d "%ROOT%auto_brightness_mcu"
echo.
goto :end

:build_failed
echo.
echo [ERROR] Build failed. Check the output above for details.
exit /b 1

:end
endlocal
echo Done.
