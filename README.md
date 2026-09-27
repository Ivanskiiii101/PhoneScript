# phone-provision

Sets up a new Samsung Galaxy A-series or Google Pixel phone over USB:

1. **System update** – opens the update screen and loops until the phone is on the newest version it can get (handles the reboot and any follow-up updates).
2. **Aurora Store** – downloads the latest release from F-Droid and installs it.
3. **Apps** – installs the apps listed in `apps.conf`: directly from the developer (F-Droid, GitHub, official sites) where possible, otherwise through Aurora Store.

## Supported phones

| Samsung | Google Pixel |
|---|---|
| Galaxy A06, A07, A13, A14, A15, A16, A17, A17 5G | Pixel 7a, 8a, 9a, 10a, 10, 10 Pro / Pro XL / Pro Fold |

Other models are refused unless you pass `--force`.

## Requirements (computer)

- `adb` – [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools)
- `curl` and `jq`
- Linux or macOS. On Windows use WSL or Git Bash.

```bash
# Debian/Ubuntu
sudo apt install adb curl jq
# macOS
brew install android-platform-tools jq
```

## One-time steps on each phone

ADB only works after USB debugging is switched on, which Android does not allow to be automated:

1. Go through the setup wizard (connect Wi-Fi so the phone can update).
2. **Settings → About phone** (Samsung: **→ Software information**) → tap **Build number** 7 times.
3. **Settings → Developer options → USB debugging** → on.
4. Plug in the phone and tap **Allow** on the "Allow USB debugging?" prompt (tick "Always allow from this computer").

## Usage

```bash
git clone https://github.com/<you>/phone-provision.git
cd phone-provision
chmod +x provision.sh
./provision.sh
```

| Option | Effect |
|---|---|
| `-s SERIAL` | Choose a phone when several are connected (`adb devices` lists serials) |
| `--skip-update` | Skip the system update step |
| `--aurora-only` | Install every app through Aurora Store instead of direct downloads |
| `--force` | Run on a model that is not on the supported list |
| `-c FILE` | Use a different app list |

Downloaded APKs are cached in `cache/` for 24 hours, so the second phone of the day installs faster.

## Editing the app list

Each line in `apps.conf` is `Name | package id | source | argument`. The file header explains the sources. The package id is the `id=` part of an app's Play Store URL.

## What can't be fully automated, and why

- **System updates** need a tap on a normal (unrooted) phone. Android doesn't let ADB start an OTA. The script opens the right screen and does everything else.
- **Aurora Store installs** need one tap per app, because Android asks the user to confirm installs from any store other than Google Play. That's why the script installs apps directly over ADB where an official APK exists (no taps), and only uses Aurora for Play-only apps (Telegram, Snapchat, Threema).
- **Paid apps** (Threema) need a purchased licence. Aurora's anonymous login can't install them.
- Aurora's anonymous accounts are shared and sometimes rate-limited by Google. If installs stall, wait or log in with a Google account in Aurora.

## Notes

- Download sources change over time. If an app fails, check its line in `apps.conf`; the script falls back to Aurora automatically.
- The script never factory-resets, roots or unlocks the phone.
