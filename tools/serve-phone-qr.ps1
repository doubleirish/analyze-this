<#
.SYNOPSIS
  Serves a folder of .beatsmix files to the beats-me phone app and prints a QR
  code (as text) it can scan. No adb or cable needed - Wi-Fi only.

.EXAMPLE
  .\serve-phone-qr.ps1 -Dir D:\music
  .\serve-phone-qr.ps1 -Dir D:\music -Name 'Techno*'

.NOTES
  On the phone: open beats-me, go to the Mixtapes screen and tap "Scan QR code".
  PC and phone must be on the same Wi-Fi (not a guest network); allow TCP port
  47822 in the Windows firewall (Private network) if the phone cannot connect.
  Needs the Flutter SDK on PATH (or at ..\flutter-sdk). Press Ctrl+C to stop.
  Mixes arrive on the phone as "pull" copies, separate from ones sent with adb.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Dir,
  [string]$Name = '*'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) { $flutter = Join-Path $root '..\flutter-sdk\bin\flutter.bat' }
if (-not (Test-Path $flutter)) { throw 'flutter not found on PATH.' }
if (-not (Test-Path -LiteralPath $Dir)) { throw "Folder not found: $Dir" }

$work = Join-Path ([IO.Path]::GetTempPath()) ("beatsmix_pull_" + [guid]::NewGuid().ToString('N'))
$env:BEATSMIX_DIR = (Resolve-Path -LiteralPath $Dir).Path
$env:BEATSMIX_NAME = $Name
$env:BEATSMIX_WORK = $work

Push-Location $root
try {
  & $flutter test tools\serve_phone_qr_test.dart --reporter expanded 2>&1 |
    ForEach-Object {
      $line = "$_"
      # flutter test prefixes the test's own output with "Shell: "
      if ($line -match '^Shell: ?(.*)$') { $Matches[1] }
      elseif ($line -match 'Some tests failed|Error|Exception') { $line }
    }
} finally {
  Pop-Location
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
