<#
.SYNOPSIS
  One-time SD card setup so a Pi accepts pushes over the local network (no balenaCloud needed).

.DESCRIPTION
  Edits config.json on the balenaOS boot partition of an SD card inserted in this PC:
   - enables development mode (exposes balenaEngine on the LAN so 'balena push <ip>' can build on the Pi)
   - optionally adds your SSH public key (development mode then requires the key for SSH)
   - optionally sets the hostname and a Wi-Fi network
  A backup of the original config.json is saved next to it.
  Works on cards flashed with an unmanaged balenaOS image (no balenaCloud, local mode is then
  automatic) or with a balenaCloud image (local mode must still be enabled from the dashboard).

.EXAMPLE
  .\prepare-sd.ps1                                            # auto-detect the boot partition
.EXAMPLE
  .\prepare-sd.ps1 -Hostname kitchen -WifiSsid MyWifi -WifiPassword 'secret'
.EXAMPLE
  .\prepare-sd.ps1 -Drive E -SshKey $HOME\.ssh\id_ed25519.pub
#>
[CmdletBinding()]
param(
  # Drive letter of the SD card's boot partition (label 'resin-boot' or 'balena-boot'). Auto-detected if omitted
  [string]$Drive,
  # SSH public key to install. Defaults to the first ~/.ssh/id_*.pub found, if any
  [string]$SshKey,
  # Skip adding an SSH key (development mode then allows passwordless root SSH from your LAN)
  [switch]$NoSshKey,
  # Device hostname, reachable as <hostname>.local
  [string]$Hostname,
  # Wi-Fi network to join (not needed for Ethernet or if the image already has Wi-Fi set up)
  [string]$WifiSsid,
  [string]$WifiPassword
)

$ErrorActionPreference = 'Stop'

function Find-BootDrive {
  $vols = @(Get-Volume | Where-Object { $_.FileSystemLabel -in @('resin-boot', 'balena-boot') -and $_.DriveLetter })
  if ($vols.Count -eq 0) { throw "No balenaOS boot partition found. Insert the SD card, or pass -Drive <letter>." }
  if ($vols.Count -gt 1) { throw "More than one balenaOS boot partition found ($($vols.DriveLetter -join ', ')). Pass -Drive <letter>." }
  return [string]$vols[0].DriveLetter
}

function Write-Utf8NoBom([string]$path, [string]$text) {
  [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-Prop($obj, [string]$name, $value) {
  if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
  else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# Validate inputs before touching the card
if ($Hostname -and $Hostname -notmatch '^[A-Za-z0-9-]{1,63}$') { throw "Invalid hostname '$Hostname' (letters, digits and dashes only)." }
if ($WifiSsid -and -not $WifiPassword) { throw '-WifiPassword is required with -WifiSsid.' }
if ($SshKey -and -not (Test-Path $SshKey)) { throw "SSH key $SshKey not found." }

if (-not $Drive) { $Drive = Find-BootDrive }
$root = "$($Drive.TrimEnd(':', '\')):\"
$configPath = Join-Path $root 'config.json'
if (-not (Test-Path $configPath)) { throw "$configPath not found. Is $root the balenaOS boot partition?" }

$raw = Get-Content $configPath -Raw
$config = $raw | ConvertFrom-Json

$backup = Join-Path $root ("config.json.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
Copy-Item $configPath $backup
Write-Host "Backed up config.json to $backup"

$managed = [bool]($config.PSObject.Properties['apiKey'] -or $config.PSObject.Properties['deviceApiKey'])
if ($managed) {
  Write-Host 'This card is balenaCloud-managed. After booting, also enable local mode once from the dashboard (Device > Settings > Local mode).' -ForegroundColor Yellow
} else {
  Write-Host 'This card is unmanaged (no balenaCloud). Local mode turns on automatically.' -ForegroundColor Green
}

Set-Prop $config 'developmentMode' $true
Write-Host 'Enabled development mode.'

if ($Hostname) {
  Set-Prop $config 'hostname' $Hostname
  Write-Host "Hostname set to $Hostname (reachable as $Hostname.local)."
}

if (-not $NoSshKey) {
  if (-not $SshKey) {
    $SshKey = Get-ChildItem (Join-Path $HOME '.ssh') -Filter 'id_*.pub' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  }
  if ($SshKey) {
    $key = (Get-Content $SshKey -Raw).Trim()
    if (-not $config.PSObject.Properties['os']) { Set-Prop $config 'os' ([pscustomobject]@{}) }
    $keys = @()
    if ($config.os.PSObject.Properties['sshKeys']) { $keys = @($config.os.sshKeys) }
    if ($keys -notcontains $key) { $keys += $key }
    Set-Prop $config.os 'sshKeys' $keys
    Write-Host "Added SSH key $SshKey."
  } else {
    Write-Host 'No SSH key found (~/.ssh/id_*.pub). Development mode allows passwordless root SSH from your LAN.' -ForegroundColor Yellow
    Write-Host 'Create one with: ssh-keygen -t ed25519   and run this script again, or pass -NoSshKey to silence this.' -ForegroundColor Yellow
  }
}

Write-Utf8NoBom $configPath ($config | ConvertTo-Json -Depth 20)
Write-Host "Updated $configPath"

if ($WifiSsid) {
  $connDir = Join-Path $root 'system-connections'
  New-Item -ItemType Directory -Force $connDir | Out-Null
  $wifi = @"
[connection]
id=iotsound-wifi
type=wifi

[wifi]
hidden=true
mode=infrastructure
ssid=$WifiSsid

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=$WifiPassword
"@
  Write-Utf8NoBom (Join-Path $connDir 'iotsound-wifi') ($wifi -replace "`r`n", "`n")
  Write-Host "Wi-Fi network '$WifiSsid' configured."
}

Write-Host ''
Write-Host 'Done. Eject the card, put it back in the Pi and boot it. Then from this PC run:' -ForegroundColor Green
Write-Host '  .\push.ps1 -Discover     # find its IP address'
Write-Host '  .\push.ps1 -Device <ip>  # push IoTSound to it'
