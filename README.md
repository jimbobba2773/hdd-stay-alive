# HDD Stay Alive

A small macOS menu bar app by GitSoft that keeps external drives (for example a USB RAID) from going to sleep.

- Pick the drives to keep awake from the menu bar icon.
- While active it prevents idle sleep and writes a tiny file to each chosen drive on a timer.
- Starts active at launch, optional launch at login, optional "Only Show Active Drives".
- "Keep awake for…" timer (30 minutes to 8 hours, or until turned off).

## Build

```
./build.sh
```

Produces `HDD Stay Alive.app` and `HDD Stay Alive.zip`. Bump `VERSION` in `build.sh` for each release and publish the zip as a GitHub release tagged `v<VERSION>`; the app's "Check for Updates" reads the latest release.

© 2026 GitSoft
