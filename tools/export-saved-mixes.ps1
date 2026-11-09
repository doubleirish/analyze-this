<#
.SYNOPSIS
  Exports the saved mixes of the analyze-this library as .beatsmix files.

.EXAMPLE
  .\export-saved-mixes.ps1 -OutDir D:\music
  .\export-saved-mixes.ps1 -OutDir D:\music -Name 'Techno*'

.NOTES
  Reads a copy of the app database (the app may stay open). Needs the Flutter
  SDK on PATH (or at ..\flutter-sdk). Mixes keep their mixtape id, so sending
  them again updates the copy already on the phone. Follow with
  send-beatsmix.ps1 -Dir <OutDir> to put them on the phone.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$OutDir,
  [string]$Name = '*',
  [string]$DbFile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) { $flutter = Join-Path $root '..\flutter-sdk\bin\flutter.bat' }
if (-not (Test-Path $flutter)) { throw 'flutter not found on PATH.' }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$env:BEATSMIX_OUT = (Resolve-Path $OutDir).Path
$env:BEATSMIX_NAME = $Name
if ($DbFile) { $env:BEATSMIX_DB = (Resolve-Path $DbFile).Path }

Push-Location $root
try {
  & $flutter test tools\export_saved_mixes_test.dart --reporter expanded
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
