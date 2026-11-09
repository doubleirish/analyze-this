<#
.SYNOPSIS
  Builds a 60-minute .beatsmix for each of the top genres and top artists of the library.

.EXAMPLE
  .\build-top-mixes.ps1 -OutDir D:\music [-Count 10]

.NOTES
  Reads a copy of the app database. Every mix uses a different class style
  (similar activities are never placed together). Mix ids are derived from the
  mix name, so rebuilding updates the same mix on the phone. Follow with
  import-beatsmix-local.ps1 or send-beatsmix.ps1.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$OutDir,
  [int]$Count = 10
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) { $flutter = Join-Path $root '..\flutter-sdk\bin\flutter.bat' }
if (-not (Test-Path $flutter)) { throw 'flutter not found on PATH.' }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$env:TOPMIX_OUT = (Resolve-Path $OutDir).Path
$env:TOPMIX_COUNT = $Count

Push-Location $root
try {
  & $flutter test tools\build_top_mixes_test.dart --reporter expanded
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
