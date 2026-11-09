<#
.SYNOPSIS
  Converts tracks Android can't play (.wma, .aiff, .ape ...) inside .beatsmix
  files to AAC (.m4a), updating the manifest and playlist. Originals are
  copied to -BackupDir first.
.EXAMPLE
  .\fix-beatsmix-audio.ps1 -Dir D:\music
#>
param(
  [Parameter(Mandatory)][string]$Dir,
  [string]$Filter = '*.beatsmix',
  [string]$BackupDir,
  [string]$Bitrate = '256k',
  [string]$Ffmpeg
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not $Ffmpeg) {
  $Ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
  if (-not $Ffmpeg) { $Ffmpeg = Get-ChildItem "$PSScriptRoot\..\..\tools" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
}
if (-not $Ffmpeg) { throw 'ffmpeg not found. Pass -Ffmpeg <path>.' }
if (-not $BackupDir) { $BackupDir = (Resolve-Path $Dir).Path.TrimEnd('\') + '_backup_audiofix' }
$ok = '.mp3', '.m4a', '.aac', '.mp4', '.flac', '.ogg', '.oga', '.opus', '.wav', '.3gp', '.amr', '.mka'
$audio = $ok + '.wma', '.ape', '.wv', '.mpc', '.aiff', '.aif'
$utf8 = New-Object Text.UTF8Encoding($false)
$work = Join-Path $env:TEMP "fix_beatsmix_$PID"
New-Item -ItemType Directory $work -Force | Out-Null
$fixedFiles = 0; $converted = 0

try {
  foreach ($bm in Get-ChildItem $Dir -Filter '*.beatsmix' | Where-Object { $_.BaseName -like $Filter.Replace('.beatsmix', '') }) {
    $zip = [IO.Compression.ZipFile]::OpenRead($bm.FullName)
    $bad = @($zip.Entries | Where-Object { $_.FullName -like 'songs/*' -and $audio -contains [IO.Path]::GetExtension($_.Name).ToLower() -and $ok -notcontains [IO.Path]::GetExtension($_.Name).ToLower() })
    $zip.Dispose()
    if (-not $bad.Count) { continue }

    $tmp = Join-Path $work $bm.Name
    Copy-Item $bm.FullName $tmp -Force
    $zip = [IO.Compression.ZipFile]::Open($tmp, 'Update')
    try {
      $readText = { param($name) $e = $zip.GetEntry($name); $r = New-Object IO.StreamReader($e.Open(), $utf8); $t = $r.ReadToEnd(); $r.Close(); $e.Delete(); $t }
      $manifest = & $readText 'manifest.json'
      $m3u = if ($zip.GetEntry('playlist.m3u8')) { & $readText 'playlist.m3u8' } else { $null }
      foreach ($name in ($bad | ForEach-Object FullName)) {
        $src = Join-Path $work 'src.bin'
        $dst = Join-Path $work 'dst.m4a'
        $e = $zip.GetEntry($name)
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $src, $true)
        Remove-Item $dst -ErrorAction SilentlyContinue
        $ErrorActionPreference = 'Continue'
        & $Ffmpeg -v error -y -i $src -vn -map_metadata 0 -c:a aac -b:a $Bitrate -f ipod $dst 2>&1 | Out-Null
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0 -or -not (Test-Path $dst)) { Write-Host "FAILED   $($bm.Name) :: $name" -ForegroundColor Red; continue }
        $newName = [IO.Path]::ChangeExtension($name, '.m4a')
        $sha = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
        $size = (Get-Item $dst).Length
        $e.Delete()
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $dst, $newName, 'Optimal') | Out-Null
        $rx = '("file":\s*")' + [regex]::Escape($name) + '("\s*,\s*"sha256":\s*")[0-9a-fA-F]+("\s*,\s*"size":\s*)\d+'
        $manifest = [regex]::Replace($manifest, $rx, { param($mm) $mm.Groups[1].Value + $newName + $mm.Groups[2].Value + $sha + $mm.Groups[3].Value + $size })
        if ($m3u) { $m3u = $m3u.Replace($name, $newName).Replace($name.Substring(6), $newName.Substring(6)) }
        $converted++
        Write-Host "CONVERT  $($bm.Name) :: $([IO.Path]::GetFileName($name))"
      }
      foreach ($pair in @(@('manifest.json', $manifest), @('playlist.m3u8', $m3u))) {
        if ($null -eq $pair[1]) { continue }
        $ne = $zip.CreateEntry($pair[0], 'Optimal')
        $w = $ne.Open(); $bytes = $utf8.GetBytes($pair[1]); $w.Write($bytes, 0, $bytes.Length); $w.Close()
      }
    } finally { $zip.Dispose() }

    New-Item -ItemType Directory $BackupDir -Force | Out-Null
    if (-not (Test-Path (Join-Path $BackupDir $bm.Name))) { Copy-Item $bm.FullName $BackupDir }
    Copy-Item $tmp $bm.FullName -Force
    Remove-Item $tmp -Force
    $fixedFiles++
  }
} finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Converted $converted track(s) in $fixedFiles file(s). Originals in $BackupDir"
