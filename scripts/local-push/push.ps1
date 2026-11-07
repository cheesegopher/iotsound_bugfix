<#
.SYNOPSIS
  Push IoTSound from this PC to Raspberry Pis on the local network, no SD card reflashing.

.DESCRIPTION
  Uses balena local mode: the source is sent straight to each Pi over the LAN, built on the
  Pi and started there. Works for balenaCloud-managed Pis (with local mode enabled) and for
  unmanaged Pis running balenaOS without balenaCloud (local mode is automatic there).
  Each Pi needs a development-mode balenaOS. See README.md in this folder for one-time setup.

.EXAMPLE
  .\push.ps1                          # push to every device in devices.json, in parallel
.EXAMPLE
  .\push.ps1 -Device kitchen          # push to one device from devices.json
.EXAMPLE
  .\push.ps1 -Device 192.168.0.60     # push to an address not listed in devices.json
.EXAMPLE
  .\push.ps1 -Device kitchen -Follow  # push and keep streaming that device's logs
.EXAMPLE
  .\push.ps1 -Check                   # only check which devices are ready for a push
.EXAMPLE
  .\push.ps1 -Discover                # scan the network for balenaOS devices
.EXAMPLE
  .\push.ps1 -Logs kitchen            # stream logs from a device
#>
[CmdletBinding()]
param(
  # Device names (from devices.json) or addresses. Defaults to every device in devices.json
  [string[]]$Device,
  # Device list, see devices.example.json. Defaults to devices.json next to this script
  [string]$Config,
  # Stream build and runtime logs instead of returning when the build finishes (single device only)
  [switch]$Follow,
  # Force base images to be pulled again
  [switch]$Pull,
  # Don't use cached image layers
  [switch]$NoCache,
  # Only check whether devices are reachable and in local mode
  [switch]$Check,
  # Scan the local network for balenaOS devices and exit
  [switch]$Discover,
  # Stream logs from the given device and exit
  [string]$Logs
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot isn't available yet in param() defaults on Windows PowerShell 5.1
if (-not $Config) { $Config = Join-Path $PSScriptRoot 'devices.json' }

# Local pushes don't need balenaCloud: don't let the CLI stall sending analytics/crash reports to it.
# (BALENARC_OFFLINE_MODE can't be used, the CLI refuses 'push' in offline mode)
$env:BALENARC_NO_ANALYTICS = '1'
$env:BALENARC_NO_SENTRY = '1'

# Pinned: CLI v25.0.0 and later can't find Dockerfiles on Windows ("Specified file not found or is invalid:
# Dockerfile"), its new compose parser returns build contexts with backslashes. 24.1.4 is the last version before it
$BalenaCliVersion = '24.1.4'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$LogDir = Join-Path $PSScriptRoot 'logs'

# --- balena CLI --------------------------------------------------------------

function Get-BalenaCli {
  # A balena CLI already on PATH is not used, it may be a version with the Windows build bug above
  $installDir = Join-Path $env:LOCALAPPDATA "iotsound\balena-cli-$BalenaCliVersion"
  $cli = Join-Path $installDir 'balena\bin\balena.cmd'
  if (Test-Path $cli) { return $cli }

  Write-Host "balena CLI not found, downloading v$BalenaCliVersion (~100 MB, one time only)..." -ForegroundColor Cyan
  $url = "https://github.com/balena-io/balena-cli/releases/download/v$BalenaCliVersion/balena-cli-v$BalenaCliVersion-windows-x64-standalone.tar.gz"
  New-Item -ItemType Directory -Force $installDir | Out-Null
  $archive = Join-Path $installDir 'balena-cli.tar.gz'
  $ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is very slow with the progress bar on PS 5.1
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
  & "$env:SystemRoot\System32\tar.exe" -xzf $archive -C $installDir
  if ($LASTEXITCODE -ne 0) { throw "Failed to extract $archive" }
  Remove-Item $archive
  if (-not (Test-Path $cli)) { throw "balena CLI not found at $cli after extraction" }
  return $cli
}

# --- Devices ------------------------------------------------------------------

function Get-Props($obj) {
  $result = [ordered]@{}
  if ($null -ne $obj) {
    foreach ($p in $obj.PSObject.Properties) { $result[$p.Name] = [string]$p.Value }
  }
  return $result
}

function Get-Devices {
  # Note: PowerShell variables are case-insensitive, so this must not be called $config (it would shadow -Config)
  $deviceList = $null
  if (Test-Path $Config) {
    $deviceList = Get-Content $Config -Raw | ConvertFrom-Json
  } elseif (-not $Device) {
    throw "No device list found at $Config. Copy devices.example.json to devices.json and edit it, or pass -Device <ip>."
  }

  $commonEnv = Get-Props $(if ($deviceList) { $deviceList.env } else { $null })
  $known = @()
  if ($deviceList) {
    foreach ($d in $deviceList.devices) {
      $envVars = [ordered]@{}
      foreach ($k in $commonEnv.Keys) { $envVars[$k] = $commonEnv[$k] }
      $own = Get-Props $d.env
      foreach ($k in $own.Keys) { $envVars[$k] = $own[$k] }
      $known += [pscustomobject]@{ Name = [string]$d.name; Address = [string]$d.address; Env = $envVars }
    }
  }

  if (-not $Device) { return $known }

  $selected = @()
  foreach ($item in $Device) {
    $match = $known | Where-Object { $_.Name -eq $item -or $_.Address -eq $item }
    if ($match) {
      $selected += $match
    } else {
      # Not in devices.json: treat as an address, with only the shared env vars
      $selected += [pscustomobject]@{ Name = $item; Address = $item; Env = $commonEnv }
    }
  }
  return $selected
}

function Test-TcpPort([string]$address, [int]$port, [int]$timeoutMs = 3000) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync($address, $port)
    return ($task.Wait($timeoutMs) -and $client.Connected)
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

# Returns $null when the device is ready, otherwise the reason it is not
function Test-Device($dev) {
  if (-not (Test-TcpPort $dev.Address 48484)) {
    return "not reachable (balena supervisor on port 48484 did not answer). Is it powered on and is the address right?"
  }
  try {
    # The supervisor only allows this unauthenticated call in local mode (or on unmanaged devices)
    Invoke-WebRequest -Uri "http://$($dev.Address):48484/v2/local/target-state" -UseBasicParsing -TimeoutSec 10 | Out-Null
  } catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    if ($status -eq 401) { return "is not in local mode. Enable it once (see README.md)." }
    return "supervisor check failed: $($_.Exception.Message)"
  }
  if (-not (Test-TcpPort $dev.Address 2375)) {
    return "is in local mode but balenaEngine (port 2375) is closed. Enable development mode (see README.md)."
  }
  return $null
}

# Quote an argument for a Windows command line
function ConvertTo-Arg([string]$value) {
  if ($value -notmatch '[\s"]') { return $value }
  return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-PushArgs($dev, [bool]$detached) {
  $pushArgs = @('push', $dev.Address, '--source', $RepoRoot, '--nolive')
  if ($detached) { $pushArgs += '--detached' }
  if ($Pull) { $pushArgs += '--pull' }
  if ($NoCache) { $pushArgs += '--nocache' }
  foreach ($k in $dev.Env.Keys) { $pushArgs += @('--env', "$k=$($dev.Env[$k])") }
  return $pushArgs
}

# --- Commands -----------------------------------------------------------------

$cli = Get-BalenaCli

if ($Discover) {
  Write-Host 'Scanning the local network for balenaOS devices (about 20 seconds)...' -ForegroundColor Cyan
  & $cli device detect --timeout 20
  exit $LASTEXITCODE
}

if ($Logs) {
  $dev = (Get-Devices | Where-Object { $_.Name -eq $Logs -or $_.Address -eq $Logs } | Select-Object -First 1)
  $address = if ($dev) { $dev.Address } else { $Logs }
  & $cli device logs $address --tail
  exit $LASTEXITCODE
}

$devices = @(Get-Devices)
if ($devices.Count -eq 0) { throw "No devices to push to. Add them to $Config or pass -Device." }
if ($Follow -and $devices.Count -ne 1) { throw '-Follow works with a single device, pass one with -Device.' }

# Pre-flight checks, so one bad device doesn't hide behind a long build log
$ready = @()
foreach ($dev in $devices) {
  $problem = Test-Device $dev
  if ($problem) {
    Write-Host "[$($dev.Name)] $($dev.Address) $problem" -ForegroundColor Yellow
  } else {
    Write-Host "[$($dev.Name)] $($dev.Address) ready" -ForegroundColor Green
    $ready += $dev
  }
}
if ($Check) { exit $(if ($ready.Count -eq $devices.Count) { 0 } else { 1 }) }
if ($ready.Count -eq 0) { Write-Host 'No devices ready, nothing pushed.' -ForegroundColor Red; exit 1 }

if ($Follow) {
  $dev = $ready[0]
  Write-Host "[$($dev.Name)] Pushing and streaming logs, Ctrl+C to stop following (the device keeps running)." -ForegroundColor Cyan
  & $cli @(Get-PushArgs $dev $false)
  exit $LASTEXITCODE
}

# Push to all ready devices in parallel. Each Pi builds its own images, so they don't slow each other down
New-Item -ItemType Directory -Force $LogDir | Out-Null
$runs = @()
foreach ($dev in $ready) {
  $safeName = $dev.Name -replace '[^\w.-]', '_'
  $log = Join-Path $LogDir "$safeName.log"
  $errLog = Join-Path $LogDir "$safeName.err.log"
  $argLine = (Get-PushArgs $dev $true | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
  $proc = Start-Process -FilePath $cli -ArgumentList $argLine -NoNewWindow -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError $errLog
  $null = $proc.Handle  # needed on PS 5.1 for ExitCode to be available later
  $runs += [pscustomobject]@{ Device = $dev; Process = $proc; Log = $log; ErrLog = $errLog; Start = Get-Date }
  Write-Host "[$($dev.Name)] build started, log: $log" -ForegroundColor Cyan
}

Write-Host "Building on $($runs.Count) device(s). First builds take a while, later pushes only rebuild what changed." -ForegroundColor Cyan
$failed = 0
foreach ($run in $runs) {
  $run.Process.WaitForExit()
  $elapsed = [int]((Get-Date) - $run.Start).TotalSeconds
  if ($run.Process.ExitCode -eq 0) {
    Write-Host "[$($run.Device.Name)] done in ${elapsed}s" -ForegroundColor Green
  } else {
    $failed++
    Write-Host "[$($run.Device.Name)] FAILED after ${elapsed}s (exit code $($run.Process.ExitCode)). Last log lines:" -ForegroundColor Red
    Get-Content $run.Log, $run.ErrLog -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
  }
}

$skipped = $devices.Count - $ready.Count
Write-Host ''
Write-Host "Pushed: $($runs.Count - $failed) ok, $failed failed, $skipped skipped (not ready)."
exit $(if ($failed -eq 0 -and $skipped -eq 0) { 0 } else { 1 })
