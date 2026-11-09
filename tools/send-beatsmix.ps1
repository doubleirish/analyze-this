<#
.SYNOPSIS
  Sends every .beatsmix file in a folder to a phone running beats-me, over adb.

.EXAMPLE
  .\send-beatsmix.ps1 -Dir D:\music
  .\send-beatsmix.ps1 -Dir D:\music -Filter 'Techno*' -Serial 1A081FDF60019B

.NOTES
  Needs adb (Android platform-tools) and USB / Wireless debugging on the phone.
  Songs the phone already has (by SHA-256) are not sent again. Packages land in
  /sdcard/beats-me-inbox/<transport>/<id>/ and beats-me imports them.
#>
[CmdletBinding()]
param(
  [string]$Dir,
  [string]$Filter = '*.beatsmix',
  [string]$Serial,
  [string]$Adb,
  [int]$WaitSeconds = 60,
  [switch]$Setup
)
$ErrorActionPreference = 'Stop'
if (-not $Dir -and -not $Setup) { throw 'Pass -Dir <folder of .beatsmix files> (or -Setup for setup help).' }
Add-Type -AssemblyName System.IO.Compression.FileSystem

$inbox = '/sdcard/beats-me-inbox'

function Show-AdbHelp {
  Write-Host @'

adb (Android platform-tools) was not found. To set it up:
  1. Install it:   winget install Google.PlatformTools
     (or download "SDK Platform-Tools for Windows" from
      https://developer.android.com/tools/releases/platform-tools and unzip it).
  2. Open a new terminal so PATH updates, check with:  adb version
     (or pass the exe explicitly:  -Adb C:\path\to\platform-tools\adb.exe).
  3. Then set up the phone - run this script with -Setup to see the steps.
'@
}

function Show-PhoneHelp([string]$Problem) {
  if ($Problem) { Write-Host "`n$Problem" -ForegroundColor Yellow }
  Write-Host @'

Phone setup (once):
  1. Settings > About phone > tap "Build number" 7 times to enable Developer options.
  2. Settings > System > Developer options > switch on "USB debugging",
     then plug in the USB cable and tap "Allow" on the prompt on the phone.
     Wi-Fi instead of a cable: switch on "Wireless debugging" (same Wi-Fi as this PC),
     tap "Pair device with pairing code", then on the PC run
         adb pair <ip>:<pairing-port>      (enter the 6-digit code)
         adb connect <ip>:<port shown on the Wireless debugging screen>
  3. Check the phone shows up as "device":  adb devices -l
  4. Install the beats-me app (from the beats-me folder):  deploy-android.bat
     Open beats-me once and allow "All files access" and notifications, so it can
     import what is copied to /sdcard/beats-me-inbox. Keep the phone unlocked
     while sending; beats-me imports each mix when it is opened or resumed.

No cable or adb? serve-phone-qr.ps1 -Dir <folder> prints a QR code that
beats-me (Mixtapes > Scan QR code) can scan to download the same mixes over Wi-Fi.
'@
}

if ($Setup) { Show-AdbHelp; Show-PhoneHelp ''; return }

if (-not $Adb) {
  $cands = @('adb', "$env:ANDROID_HOME\platform-tools\adb.exe", "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe")
  $Adb = $cands | Where-Object { $_ -and (Get-Command $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
} elseif (-not (Get-Command $Adb -ErrorAction SilentlyContinue)) {
  $Adb = $null
}
if (-not $Adb) { Show-AdbHelp; Write-Host ''; throw 'adb not found.' }

if (-not $Serial) {
  $lines = @(& $Adb devices | Select-Object -Skip 1 | Where-Object { $_.Trim() })
  $ready = @($lines | Where-Object { $_ -match '\sdevice\b' } | ForEach-Object { ($_ -split '\s+')[0] })
  if ($ready.Count -eq 0) {
    $why = if ($lines -match 'unauthorized') { 'The phone is connected but has not allowed this PC: unlock it and tap "Allow" on the USB debugging prompt.' }
           elseif ($lines -match 'offline') { 'The phone is offline: unplug and replug the cable (or reconnect Wireless debugging).' }
           else { 'No phone found.' }
    Show-PhoneHelp $why
    throw 'No phone ready.'
  }
  if ($ready.Count -gt 1) {
    # One phone can appear twice (Wi-Fi debugging by IP and by mDNS name): keep one per hardware serial.
    $seen = @{}
    $ready = @($ready | Where-Object {
        $hw = (& $Adb -s $_ shell getprop ro.serialno 2>$null | Out-String).Trim()
        if (-not $hw) { $hw = $_ }
        if ($seen.ContainsKey($hw)) { $false } else { $seen[$hw] = $true; $true }
      })
  }
  if ($ready.Count -gt 1) { throw "Several phones: $($ready -join ', '). Pass -Serial." }
  $Serial = $ready[0]
}
function Invoke-Adb {
  # adb prints progress on stderr; don't let 'Stop' turn that into an error (callers check $LASTEXITCODE).
  $ErrorActionPreference = 'Continue'
  & $Adb -s $Serial @args
}

$files = @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File | Where-Object Extension -eq '.beatsmix' | Sort-Object Name)
if ($files.Count -eq 0) { throw "No .beatsmix files in $Dir" }
$freeKb = [long]((Invoke-Adb shell df -k /sdcard | Select-Object -Last 1) -split '\s+')[3]
$total = ($files | Measure-Object Length -Sum).Sum
Write-Host ("{0} file(s), {1:N0} MB; phone {2} has {3:N0} MB free" -f $files.Count, ($total / 1MB), $Serial, ($freeKb / 1KB))
if ($freeKb * 1KB -lt $total) { Write-Warning 'The phone may not have enough free space (songs it already has are skipped).' }

function Get-Inventory {
  $raw = (Invoke-Adb shell cat "$inbox/.inventory.json" 2>$null) -join "`n"
  try { $raw | ConvertFrom-Json } catch { $null }
}

# Package contents come from a file, so check them before they reach the disk
# or adb (same rules as beats-me's importer). Only the id and transport go into
# adb shell command lines, so they get the strict plain-name rule; file paths
# are only used with adb push, which doesn't go through a shell.
$safeId = '^[A-Za-z0-9._-]{1,64}$'
$transports = @('push', 'usb', 'pull', 'zip', 'folder', 'syncdir')
$maxPackageBytes = 64GB
function Test-SafeRelative([string]$Rel) {
  $Rel -and $Rel.Length -le 400 -and -not $Rel.StartsWith('/') -and $Rel -notmatch '[\\:]' -and
    -not (($Rel -split '/') -contains '..')
}
function Expand-Package([string]$Zip, [string]$To) {
  $z = [IO.Compression.ZipFile]::OpenRead($Zip)
  try {
    $sum = 0L
    foreach ($e in $z.Entries) {
      $name = $e.FullName.TrimEnd('/')
      if (-not (Test-SafeRelative $name)) { throw "unsafe entry in zip: $($e.FullName)" }
      $sum += $e.Length
    }
    if ($sum -gt $maxPackageBytes) { throw 'package too large to unpack' }
    $root = [IO.Path]::GetFullPath($To).TrimEnd('\') + '\'
    foreach ($e in $z.Entries) {
      $dest = [IO.Path]::GetFullPath((Join-Path $To $e.FullName))
      if (-not $dest.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "unsafe entry in zip: $($e.FullName)" }
      if ($e.FullName.EndsWith('/')) { [void](New-Item -ItemType Directory -Force -Path $dest); continue }
      [void](New-Item -ItemType Directory -Force -Path (Split-Path $dest))
      [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
    }
  } finally { $z.Dispose() }
}

$results = @()
$n = 0
foreach ($f in $files) {
  $n++
  $stage = Join-Path ([IO.Path]::GetTempPath()) ("beatsmix_" + [guid]::NewGuid().ToString('N'))
  $res = [ordered]@{ Name = $f.BaseName; Status = ''; Files = 0; MB = 0 }
  try {
    Write-Host ("[{0}/{1}] {2}" -f $n, $files.Count, $f.Name)
    Expand-Package $f.FullName $stage
    $m = Get-Content -LiteralPath (Join-Path $stage 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ("$($m.id)" -notmatch $safeId -or $m.id -match '^\.+$') { throw "bad mixtape id '$($m.id)'" }
    if ($transports -cnotcontains "$($m.transport)") { throw "bad transport '$($m.transport)'" }
    foreach ($t in $m.tracks) {
      if (-not (Test-SafeRelative "$($t.file)")) { throw "unsafe path '$($t.file)'" }
      if ($t.art -and -not (Test-SafeRelative "$($t.art)")) { throw "unsafe path '$($t.art)'" }
    }
    $key = "$($m.transport):$($m.id)"

    $inv = Get-Inventory
    $have = @{}
    if ($inv) { foreach ($p in $inv.PSObject.Properties) { foreach ($s in @($p.Value.shas)) { $have[$s] = $true } } }
    $mine = @{}
    if ($inv -and $inv.PSObject.Properties[$key]) { foreach ($s in @($inv.$key.shas)) { $mine[$s] = $true } }

    $send = New-Object System.Collections.Generic.List[string]
    foreach ($t in $m.tracks) {
      if ($mine.ContainsKey($t.sha256)) { continue }
      if (-not $have.ContainsKey($t.sha256) -and -not $send.Contains($t.file)) { $send.Add($t.file) }
      if ($t.art -and -not $send.Contains($t.art)) { $send.Add($t.art) }
    }
    $send.Add('playlist.m3u8')

    $base = "$inbox/$($m.transport)/$($m.id)"
    Invoke-Adb shell "rm -rf '$base'" | Out-Null
    Invoke-Adb shell "mkdir -p '$base/songs' '$base/art'" | Out-Null
    $bytes = 0
    foreach ($rel in $send) {
      $local = Join-Path $stage $rel
      if (-not (Test-Path -LiteralPath $local)) { continue }
      $out = Invoke-Adb push $local "$base/$($rel -replace '\\','/')" 2>&1
      if ($LASTEXITCODE -ne 0) { throw "push failed for ${rel}: $out" }
      $bytes += (Get-Item -LiteralPath $local).Length
    }
    $out = Invoke-Adb push (Join-Path $stage 'manifest.json') "$base/manifest.json" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "push failed for manifest: $out" }
    $res.Files = $send.Count - 1; $res.MB = [math]::Round($bytes / 1MB, 1)

    Invoke-Adb shell am start -a com.beatsme.IMPORT_INBOX -n com.beatsme.beats_me/.MainActivity | Out-Null
    $until = (Get-Date).AddSeconds($WaitSeconds)
    $res.Status = 'copied (not confirmed - unlock the phone / open beats-me)'
    while ((Get-Date) -lt $until) {
      $inv = Get-Inventory
      if ($inv -and $inv.PSObject.Properties[$key] -and $inv.$key.createdAt -eq $m.createdAt) { $res.Status = 'imported'; break }
      Start-Sleep -Seconds 2
    }
  } catch {
    $res.Status = "FAILED: $($_.Exception.Message)"
  } finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host "    $($res.Status)"
  $results += [pscustomobject]$res
}

$results | Format-Table -AutoSize
$bad = @($results | Where-Object { $_.Status -like 'FAILED*' }).Count
Write-Host ("{0} of {1} sent" -f ($results.Count - $bad), $results.Count)
if ($bad) { exit 1 }
