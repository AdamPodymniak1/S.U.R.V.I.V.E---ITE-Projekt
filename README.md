## Quick start

### Linux

```bash
./enter.sh
```

First run builds the Docker image (~5 min). After that it starts instantly.

---

## What's inside

| Tool | What for |
|---|---|
| **PlatformIO** | Build & flash firmware to ESP32 |
| **Flutter SDK 3.16** | Build & run the mobile app |
| **Android SDK 34** | Compile APKs |
| **Java 17** | Required by Android |
| **ADB** | Talk to Android phones over USB |
| **picocom** | Monitor ESP32 serial output |

---

## Firmware - building and flashing

```bash
cd /workspace/meshtastic-firmware
pio run -e tbeam
pio run -e tbeam -t upload --upload-port /dev/ttyUSB0
pio device monitor -p /dev/ttyUSB0 -b 115200
```

---

## Flutter app - building and testing

```bash
cd /workspace/survive_app
flutter build apk
flutter devices
flutter run
flutter test
```

---

## WSL2 for USB

Docker Desktop on Windows can't see USB. For that we use WSL2.

```powershell
# Ubuntu or any other distro (i use clean Debian, but Ubuntu should be good too):
wsl --install -d Ubuntu
```

Then in Docker Desktop: Settings -> Resources -> WSL Integration -> enable Ubuntu.

```powershell
# Each time you plug in USB (both usbipd for ESP and mobile):
winget install dorssel.usbipd-win
usbipd wsl list
usbipd wsl attach --busid <BUSID>
enter
```

## Full removal

```bash
docker compose down --rmi all -v
```

And then WLS2 if you don't neet it later. Should be good. (Will change if not, but in the future)