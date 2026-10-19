# S.U.R.V.I.V.E

Tanie urządzenie LoRa (Meshtastic) z lokalizacją bez GPS i przesyłaniem danych o zagrożeniach w strefach wojennych.

**Grupa 6D:** Adam Podymniak, Karolina Rutkowska, Bartosz Sikora

---

## Repo

```
├── Dockerfile
├── docker-compose.yml
├── enter.sh / enter-arch.sh / enter.cmd
├── meshtastic-firmware/          # firmware + our SurviveModule
├── survive_app/                  # Flutter app (BLE + OSM map)
└── PLAN.md
```

Our additions to the stock Meshtastic firmware:

- `src/modules/SurviveModule.h/.cpp` - custom module on port 256 (`PRIVATE_APP`)
- `src/mesh/Router.cpp` - survival-mode suppression hook

---

## Starting the dev environment

```bash
./enter.sh            # Linux / WSL2
./enter-arch.sh       # Arch
enter                 # Windows cmd
```

First run builds the Docker image (~5 min). Afterwards you get a shell with PlatformIO 6.2, Flutter 3.16, Android SDK 34, Java 17, ADB, picocom.

The container's working dir starts in `/workspace/survive_app`.

---

## Building & flashing firmware (Heltec V3)

Our target board is the **Heltec WiFi LoRa 32 V3** (`heltec-v3` variant).

**Inside the container:**

```bash
cd /workspace/meshtastic-firmware
pio run -e heltec-v3                            # build only
pio run -e heltec-v3 -t upload --upload-port /dev/ttyUSB0   # build + flash
pio device monitor -p /dev/ttyUSB0 -b 115200    # watch serial output
```

**Or as one-shot commands (container `survive-test` running):**

```bash
wsl -d Debian -- docker exec -u dev survive-test bash -c "cd /workspace/meshtastic-firmware && /home/dev/.platformio/penv/bin/pio run -e heltec-v3"

wsl -d Debian -- docker exec -u dev survive-test bash -c "cd /workspace/meshtastic-firmware && /home/dev/.platformio/penv/bin/pio run -e heltec-v3 -t upload --upload-port /dev/ttyUSB0"
```

First build takes 30-60 min (compiles the whole ESP32-S3 toolchain). Later builds are fast.

Other boards: `heltec-v1`, `heltec-v2`, `heltec-v2.1`, `tbeam`, `tlora-v2-1-1_6`.

---

## The S.U.R.V.I.V.E module

The module listens on meshtastic port **256** and answers any `LOCATE` packet with a CSV of positioned nodes:

```
<nodehex>,<lat_i>,<lon_i>,<alt>;<nodehex>,...   (lat/lon in 1e-7 degrees)
```

### Flood the mesh with a locate request (CLI test)

Sending a LOCATE from `meshtastic-cli` isn't wired up yet - use the app instead:

### Flutter app - BLE locate

The app connects over BLE and can request node positions:

```bash
cd /workspace/survive_app
flutter run -d DEVICE_ID     # on your phone
```

Tap **Connect** (pick your Heltec V3), then **Locate nodes**. Nodes array on the OSM map.

Only nodes the station has heard (and that have a position) will appear.

---

## Survival mode

There is a compile-time flag in `SurviveModule` (`survivalMode`). When enabled, classic text-message packets are dropped at the router while routing/admin/position/our-own traffic still passes. It's toggled in code today; a config/CLI toggle is next.

---

## Flutter app - build & test

Commands run inside the container (cwd is already `/workspace/survive_app`):

```bash
flutter devices
flutter run -d DEVICE_ID
flutter build apk
flutter test
flutter analyze
flutter clean
```

If the app crashes with `ClassNotFoundException`, run `flutter clean && flutter run` once.

---

## Windows - USB devices

Docker Desktop on Windows can't see USB hardware directly. You need WSL2 + usbipd-win.

**One time:**

```powershell
wsl --install -d Ubuntu
```

Then enable WSL2 integration in Docker Desktop: Settings → Resources → WSL Integration → enable your distro.

```powershell
winget install dorssel.usbipd-win
```

**Every time you plug in a device** (run PowerShell as Administrator):

```powershell
usbipd list
usbipd bind --busid <BUSID>
usbipd attach --wsl <DISTRO> --busid <BUSID>
```

Our USB devices:

- Heltec V3 → `Silicon Labs CP210x USB to UART Bridge` (usually busid `3-16`, shows as `/dev/ttyUSB0`)
- Phone → `POCO X7` (for `adb`/flutter run)

**Check inside the container:**

```bash
ls /dev/ttyUSB* /dev/ttyACM*      # serial ports (ESP32)
adb devices                        # android phones
```

**If `adb devices` is empty:** check `usbipd list` shows "Attached" (not "Shared"/"Not shared"), reconnect the USB cable and re-run attach; on Xiaomi/POCO enable "Install via USB" in Developer Options.

---

## Git

```bash
git add .
git commit -m "..."
git push

git status            # what changed / untracked
git log --oneline     # recent commits
```

The initial `meshtastic-firmware` submodule issue is fixed - it's tracked as regular files now.

---

## Removing everything

```bash
docker compose down --rmi all -v
```

Uninstall usbipd-win from Windows Add or Remove Programs if you want it gone completely.