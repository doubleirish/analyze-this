<#
.SYNOPSIS
  Pre-flight check for audio files: finds files that are corrupt (fail a full
  ffmpeg decode) or that Android can't play (e.g. .wma).
.EXAMPLE
  .\check-audio.ps1 -Path D:\music\Coldplay -Name '*Clocks*'
  .\check-audio.ps1 -Path D:\music -Beatsmix     # audio inside every .beatsmix
#>
param(
  [Parameter(Mandatory)][string]$Path,
  [string]$Name = '*',
  [switch]$Beatsmix,
  [string]$Ffmpeg
)
$ErrorActionPreference = 'Stop'
if (-not $Ffmpeg) {
  $Ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
  if (-not $Ffmpeg) { $Ffmpeg = Get-ChildItem "$PSScriptRoot\..\..\tools" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
}
if (-not $Ffmpeg) { throw 'ffmpeg not found. Pass -Ffmpeg <path>.' }

$audio = '.mp3', '.m4a', '.aac', '.mp4', '.flac', '.ogg', '.oga', '.opus', '.wav', '.3gp', '.amr', '.mka', '.wma', '.ape', '.wv', '.mpc', '.aiff', '.aif'
$androidOk = '.mp3', '.m4a', '.aac', '.mp4', '.flac', '.ogg', '.oga', '.opus', '.wav', '.3gp', '.amr', '.mka'
$work = $null
$problems = 0; $checked = 0; $minor = 0

function Test-File([string]$file, [string]$label) {
  $script:checked++
  $ext = [IO.Path]::GetExtension($file).ToLower()
  if ($androidOk -notcontains $ext) {
    Write-Host "NO-ANDROID  $label  ($ext is not playable on Android; convert to AAC/MP3)" -ForegroundColor Yellow
    $script:problems++
  }
  $ErrorActionPreference = 'Continue'
  $err = @(& $Ffmpeg -v error -i $file -vn -f null - 2>&1 | ForEach-Object { "$_" })
  $ErrorActionPreference = 'Stop'
  if ($LASTEXITCODE -ne 0 -or $err.Count) {
    $minor = $err.Count -le 4
    if ($minor) {
      Write-Host "MINOR       $label  (stray bad frame, usually still plays)" -ForegroundColor DarkYellow
      $script:minor++
    } else {
      Write-Host "CORRUPT     $label  ($($err | Select-Object -First 1))" -ForegroundColor Red
      $script:problems++
    }
  }
}

try {
  if ($Beatsmix) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $work = Join-Path $env:TEMP "check_audio_$PID"
    foreach ($bm in Get-ChildItem $Path -Filter '*.beatsmix' | Where-Object { $_.BaseName -like $Name }) {
      $dir = Join-Path $work $bm.BaseName
      [IO.Compression.ZipFile]::ExtractToDirectory($bm.FullName, $dir)
      Get-ChildItem $dir -Recurse -File | Where-Object { $audio -contains $_.Extension.ToLower() } |
        ForEach-Object { Test-File $_.FullName "$($bm.Name) :: $($_.Name)" }
    }
  } else {
    Get-ChildItem $Path -Recurse -File | Where-Object { $audio -contains $_.Extension.ToLower() -and $_.Name -like $Name } |
      ForEach-Object { Test-File $_.FullName $_.FullName }
  }
} finally {
  if ($work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "Checked $checked file(s): $problems problem(s), $minor minor warning(s)."
