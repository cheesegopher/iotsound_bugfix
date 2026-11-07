# Push to your Pis over the local network

`push.ps1` sends this repo from your PC to each Raspberry Pi over your network, builds it on the Pi and
restarts IoTSound. You don't need to reflash anything, and only containers whose files changed are rebuilt.

It uses balena **local mode**. That works with balenaCloud and without it.

## One-time setup per Pi

Every Pi needs **development mode** (so it accepts builds over the LAN) and **local mode**.

### Option A: Pi managed by balenaCloud (no SD card needed)

Local mode needs a development variant of balenaOS. If the dashboard says local mode is only available on a
development variant, switch the Pi to development mode first:

1. In the balenaCloud dashboard open the device, then **Terminal**, and pick **Host OS**.
2. Run:
   ```sh
   jq '.developmentMode = true' /mnt/boot/config.json > /tmp/config.json && cat /tmp/config.json > /mnt/boot/config.json && sync && reboot
   ```
3. After it reboots, the OS version on the device page should end in **(development)**. If it doesn't, the OS
   is too old for this switch: update the host OS from the dashboard (**Settings > Host OS version**) and run
   step 2 again, or flash a development image once.
4. In **Settings**, turn on **Local mode**.

While local mode is on, the Pi ignores releases and variables from balenaCloud. Turn it off to go back.

### Option B: no balenaCloud

1. Download balenaOS for your board from <https://www.balena.io/os#download>. Flash it once with
   balenaEtcher. This is the last time the card needs to come out.
2. With the card still in your PC, run:
   ```powershell
   .\prepare-sd.ps1 -Hostname kitchen
   # add  -WifiSsid "MyWifi" -WifiPassword "..."  if the Pi uses Wi-Fi
   ```
   This turns on development mode, adds your SSH key (from `~\.ssh\id_*.pub`) and sets the hostname and Wi-Fi.
   It saves a backup of `config.json` on the card first.
3. Put the card back in the Pi and boot it. A Pi without balenaCloud turns on local mode by itself.

If you use a DAC, add its overlay to `config.txt` on the boot partition while the card is in your PC,
for example `dtoverlay=hifiberry-dacplus`. Without balenaCloud there's no dashboard to set it from.

## Device list

```powershell
Copy-Item devices.example.json devices.json
```

Edit `devices.json` with each Pi's IP address. Give each Pi a fixed address (a DHCP reservation in your router)
so the IPs don't change. `.\push.ps1 -Discover` lists the balenaOS devices it can find on your network.

Put your settings (`SOUND_MODE`, `SOUND_DEVICE_NAME`, `SOUND_VOLUME`, `AUDIO_OUTPUT`...) under `env` here.
Pis in local mode don't use the variables from the balenaCloud dashboard. Each Pi also needs its own
`hostname:SET_HOSTNAME`. Otherwise they all call themselves `balena.local`.

`devices.json` is git-ignored and is not sent to the Pis.

## Usage

Run these from this folder in PowerShell. If scripts are blocked, run
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once.

| Command | What it does |
|---|---|
| `.\push.ps1` | Push to every Pi in `devices.json`, all at once |
| `.\push.ps1 -Device kitchen` | Push to one Pi (by name, or by an IP that isn't in the list) |
| `.\push.ps1 -Device kitchen -Follow` | Push and keep streaming that Pi's logs |
| `.\push.ps1 -Check` | Only check which Pis are reachable and ready |
| `.\push.ps1 -Logs kitchen` | Stream logs from a Pi |
| `.\push.ps1 -Discover` | Scan the network for balenaOS devices |
| `.\push.ps1 -Pull` / `-NoCache` | Re-pull base images / rebuild everything from scratch |

The first run downloads balena CLI v24.1.4 (about 100 MB). Newer versions (v25+) fail on Windows with
"Specified file not found or is invalid: Dockerfile", so the script always uses its own copy. Build logs are in `logs\`.

The first push to a Pi builds every image on the Pi, which can take 10 to 30 minutes on a Pi 3 or Zero.
Later pushes only rebuild what changed.

## Security

Development mode opens the Pi's container engine (port 2375) on your network without a password.
Anyone on that network can then run software on the Pi. Only use it on a home network you trust,
and not on guest or public Wi-Fi. When you have an SSH key installed, SSH (port 22222) accepts only that key.
