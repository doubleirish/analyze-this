<#
.SYNOPSIS
  Installs .beatsmix files into the local (Windows) beats-me app's mixtape
  folder, so they show up under Mixes without sending to a phone.
.EXAMPLE
  .\import-beatsmix-local.ps1 -Files (Get-ChildItem D:\music_backup_audiofix *.beatsmix | % { "D:\music\$($_.Name)" })
  .\import-beatsmix-local.ps1 -Dir D:\music -Root D:\music\Mixtapes
#>
param(
  [string]$Dir,
  [string[]]$Files,
  [string]$Root = 'D:\music\Mixtapes'
)
$ErrorActionPreference = 'Stop'
if (-not $Files) {
  if (-not $Dir) { throw 'Pass -Dir <folder> or -Files <paths>.' }
  $Files = Get-ChildItem $Dir -Filter '*.beatsmix' | ForEach-Object FullName
}
if (-not $Files) { throw 'No .beatsmix files.' }
$env:IMPORT_FILES = ($Files | ForEach-Object { (Resolve-Path $_).Path }) -join '|'
$env:IMPORT_ROOT = $Root
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Push-Location "$PSScriptRoot\.."
try {
  flutter test tools\import_beatsmix_test.dart --reporter expanded 2>&1 |
    ForEach-Object { if ("$_" -match '^(?:\d+:\d+ \+\d+(?: [-~]\d+)*: )?Shell: (.*)$') { $Matches[1] } elseif ("$_" -match 'Error|Exception|Some tests failed') { "$_" } }
} finally { Pop-Location }
