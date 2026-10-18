# S.U.R.V.I.V.E

Tanie urządzenie LoRa (Meshtastic) z lokalizacją bez GPS i przesyłaniem danych o zagrożeniach w strefach wojennych.

**Grupa 6D:** Adam Podymniak, Karolina Rutkowska, Bartosz Sikora

---

## Repo

```
├── Dockerfile
├── docker-compose.yml
├── enter.sh
├── enter-arch.sh
├── enter.cmd
├── meshtastic-firmware/
├── survive_app/
└── PLAN.md
```

---

## Starting the dev environment

```bash
./enter.sh            # Linux
./enter-arch.sh       # Arch
enter                 # Windows (cmd)
```

First run builds the Docker image. Takes about 5 minutes. Every time after is instant.

The container has everything pre-installed: PlatformIO 6.2, Flutter 3.16, Android SDK 34, Java 17, ADB, picocom.

---

## Building firmware

The container starts in `/workspace/survive_app`. For firmware work:

```bash
cd /workspace/meshtastic-firmware
pio run -e tbeam
pio run -e tbeam -t upload --upload-port /dev/ttyUSB0
pio device monitor -p /dev/ttyUSB0 -b 115200
```

Other ESP32-WROOM boards: `tlora-v2-1-1_6`, `heltec-v1`, `heltec-v2`, `heltec-v2.1`.

---

## Running the Flutter app

Commands run from inside the container. The working directory is already set to `/workspace/survive_app`:

```bash
flutter devices
flutter run
flutter run -d DEVICE_ID
flutter build apk
flutter test
```

If the app crashes with `ClassNotFoundException`, run `flutter clean && flutter run` once.

---

## Windows - USB devices

Docker Desktop on Windows can't see USB hardware directly. You need WSL2 and usbipd-win.

**One time:**

```powershell
wsl --install -d Ubuntu
```

Then enable WSL2 integration in Docker Desktop: Settings → Resources → WSL Integration → enable your distro.

```powershell
winget install dorssel.usbipd-win
```

**Every time you plug in a device:**

Run PowerShell as Administrator:

```powershell
usbipd list
usbipd bind --busid <BUSID>
usbipd attach --wsl <DISTRO> --busid <BUSID>
```

Now `enter.cmd` will see the device.

**If ADB returns nothing:**
- Check `usbipd list` - must say "Attached", not "Shared" or "Not shared"
- Reconnect the USB cable and run attach again
- On Xiaomi/POCO phones: enable "Install via USB" in Developer Options

---

## Removing everything

```bash
docker compose down --rmi all -v
```

Uninstall usbipd-win from Windows Add or Remove Programs if you want it gone completely.