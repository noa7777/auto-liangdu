# Build Guide

This project consists of three sub-projects:

| Sub-project | Location | Platform/Target |
|---|---|---|
| PC Client | `pc_app_new/` | Flutter 3.x (Windows Desktop) |
| Sensor Firmware | `auto_brightness_mcu/` | ESP8266 (PlatformIO + Arduino) |
| Sun Tracker (optional) | `sun_tracker.py` | Python 3.x |

---

## 1. Prerequisites

Before building, ensure the following tools are installed on your system.

Each section below checks whether the tool is already available before prompting to install.

### 1.1 Flutter SDK (for PC Client)

```powershell
# Check if Flutter is installed
where flutter
```

If not found, download from: https://docs.flutter.dev/get-started/install/windows

After installation, verify:

```powershell
flutter doctor
```

### 1.2 Python 3.x (for Sun Tracker)

```powershell
# Check if Python is installed
python --version
```

If not found, download from: https://www.python.org/downloads/

### 1.3 PlatformIO CLI (for ESP8266 Firmware)

```powershell
# Check if PlatformIO is installed
where pio
pip show platformio
```

If not found, install via pip:

```powershell
pip install platformio
```

---

## 2. Build Steps

### 2.1 PC Client (Flutter Windows Desktop)

**Step 1 — Check & install Flutter dependencies**

Navigate to the Flutter project directory and run:

```powershell
cd pc_app_new

# 'flutter pub get' is idempotent:
# - If the pub cache already contains all dependencies, it completes instantly.
# - If any are missing, it downloads them automatically.
flutter pub get
```

**Step 2 — Build the release executable**

```powershell
flutter build windows --release
```

The output will be at:

```
pc_app_new\build\windows\x64\runner\Release\
```

The executable name is `auto_liangdu.exe`.

---

### 2.2 ESP8266 Firmware (PlatformIO + Arduino)

**Step 1 — Check & install PlatformIO dependencies**

```powershell
cd auto_brightness_mcu

# PlatformIO reads platformio.ini and automatically downloads:
#   - espressif8266 platform  (~200 MB, cached after first download)
#   - BH1750 library          (claws/BH1750@^1.3.0)
# 'pio run' handles this before building, no separate command needed.
```

**Step 2 — Build the firmware**

```powershell
pio run
```

**Step 3 — Upload to ESP8266 (optional)**

```powershell
# Replace COM3 with your actual port
pio run --target upload --upload-port COM3
```

To find the COM port:

```powershell
mode
# or
[System.IO.Ports.SerialPort]::GetPortNames()
```

---

### 2.3 Sun Tracker (Python, optional)

This is a standalone Python utility for sunrise/sunset calculation, independent of the auto-brightness system.

**Step 1 — Check & install Python dependency**

```powershell
# Check if suntime is already installed
pip list 2>nul | findstr /I suntime
```

If not installed:

```powershell
pip install suntime
```

`suntime` is a tiny library (~8 KB) with zero external dependencies.

**Step 2 — Run**

```powershell
python sun_tracker.py
```

---

## 3. Quick Build (All-in-One Script)

For a clean build of everything, run the following in order:

```powershell
# === PC Client ===
cd pc_app_new
flutter pub get
flutter build windows --release
cd ..

# === ESP8266 Firmware ===
cd auto_brightness_mcu
pio run
cd ..

# === Sun Tracker (optional) ===
pip list 2>nul | findstr /I suntime || pip install suntime
python sun_tracker.py
```

---

## 4. Notes

- **Windows only**: The PC Client uses Win32 APIs (`dxva2.dll`) and is only buildable on Windows.
- **WiFi credentials**: Edit `auto_brightness_mcu/src/main.cpp` and replace `ssid` / `password` before uploading to your ESP8266.
- **DDC/CI tool**: `ddc_tool/DDCBrightness.exe` is pre-compiled and bundled with the Flutter app at runtime. No separate build step is needed. The source (`DDCBrightness.cs`) is included for reference.
