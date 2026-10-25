# Copyright (c) Contributors to the Open 3D Engine Project.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Temporary, standalone PR #20230 archive regression probe.
# Runs on Windows; does not touch the O3DE build or project cache.

[CmdletBinding()]
param([ValidateRange(100, 20000)][int]$FileCount = 1024)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $sevenZip -PathType Leaf)) {
    throw '7-Zip executable unavailable on this Windows runner'
}
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$root = Join-Path $tempRoot ('pr20230-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$source = Join-Path $root 'source'
$restored = Join-Path $root 'restored'
$archive = Join-Path $root 'cache.tar'
$legacy = Join-Path $root 'legacy-posix.tar'
$legacyRestored = Join-Path $root 'legacy-restored'
$paths = @('.ccache', '.o3de\python\downloaded_packages', '3rdParty\downloaded_packages', 'AutomatedTesting\Cache')

function LongPath([string]$path) {
    $absolute = [IO.Path]::GetFullPath($path)
    if ($absolute.StartsWith('\\?\')) { return $absolute }
    return '\\?\' + $absolute
}
function Write-Data([string]$path, [string]$payload) {
    [IO.Directory]::CreateDirectory((LongPath (Split-Path -Path $path -Parent))) | Out-Null
    [IO.File]::WriteAllBytes((LongPath $path), [Text.Encoding]::UTF8.GetBytes($payload))
}
function Sha256([string]$path) {
    $algo = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($path)
    try {
        return [BitConverter]::ToString($algo.ComputeHash($stream)).Replace('-', '')
    }
    finally {
        $stream.Dispose()
        $algo.Dispose()
    }
}
function Manifest([string]$directory) {
    $base = (LongPath $directory).TrimEnd('\')
    $prefix = $base + '\'
    $items = [Collections.Generic.List[string]]::new()
    foreach ($file in [IO.Directory]::EnumerateFiles($base, '*', [IO.SearchOption]::AllDirectories)) {
        if (-not $file.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "File unexpectedly outside manifest directory: $file"
        }
        $relative = $file.Substring($prefix.Length).Replace('\', '/')
        $items.Add($relative + '|' + (Sha256 $file))
    }
    $items.Sort([StringComparer]::Ordinal)
    return $items.ToArray()
}
function Assert-Same([string]$leftDir, [string]$rightDir) {
    $left = @(Manifest $leftDir)
    $right = @(Manifest $rightDir)
    if ($left.Count -ne $right.Count -or $left.Count -eq 0) {
        throw "File count mismatch: $($left.Count) / $($right.Count)"
    }
    for ($j = 0; $j -lt $left.Count; $j++) {
        if (-not [string]::Equals($left[$j], $right[$j], [StringComparison]::Ordinal)) {
            throw "Path or SHA256 mismatch: $($left[$j]) != $($right[$j])"
        }
    }
    Write-Host "PASS: $($left.Count) files restored with byte-identical content and paths"
}

foreach ($relative in $paths) {
    [IO.Directory]::CreateDirectory((LongPath (Join-Path $source $relative))) | Out-Null
}
$unicodeNames = @(
    ((-join @([char]0x65e5, [char]0x672c, [char]0x8a9e)) + '.txt'),
    ((-join @([char]0x4e2d, [char]0x6587)) + '.txt'),
    ((-join @([char]0xd55c, [char]0xad6d, [char]0xc5b4)) + '.txt'),
    ('emoji-' + [char]::ConvertFromUtf32(0x1F600) + '.txt')
)
foreach ($relative in $paths) {
    foreach ($name in $unicodeNames) {
        Write-Data (Join-Path (Join-Path $source $relative) $name) 'Unicode filename round trip'
    }
}
for ($i = 0; $i -lt $FileCount; $i++) {
    $dir = Join-Path $source $paths[$i % $paths.Count]
    Write-Data (Join-Path $dir ('cache-{0:D5}.bin' -f $i)) "Cache file $i"
}
$deep = Join-Path $source '.ccache'
while ((Join-Path $deep 'long-file.bin').Length -le 330) {
    $deep = Join-Path $deep ('part_' + ('x' * 27))
}
$longFile = Join-Path $deep 'long-file.bin'
Write-Data $longFile 'Over 330 characters long path round-trip'
if ($longFile.Length -le 330) { throw 'Long-path fixture is too short' }
Write-Host "Long-path fixture length: $($longFile.Length)"

$timestampFile = Join-Path $source '.ccache\precision.bin'
Write-Data $timestampFile 'Timestamp precision probe'
$reference = [datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc).AddTicks(1234567)
[IO.File]::SetLastWriteTimeUtc((LongPath $timestampFile), $reference)
$beforeTime = [IO.File]::GetLastWriteTimeUtc((LongPath $timestampFile))

Push-Location $source
try {
    & $sevenZip a -ttar -y $archive @paths | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip TAR creation failed, exit=$LASTEXITCODE" }
}
finally { Pop-Location }
if ((-not (Test-Path -LiteralPath $archive)) -or ((Get-Item -LiteralPath $archive).Length -le 0)) {
    throw 'Archive missing or empty'
}
& $sevenZip t -ttar $archive | Out-Null
if ($LASTEXITCODE -ne 0) { throw "TAR structural check failed: $LASTEXITCODE" }
[IO.Directory]::CreateDirectory((LongPath $restored)) | Out-Null
& $sevenZip x -ttar -y "-o$restored" $archive | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7-Zip TAR extraction failed, exit=$LASTEXITCODE" }
Assert-Same $source $restored
foreach ($relative in $paths) {
    foreach ($name in $unicodeNames) {
        $expected = Join-Path (Join-Path $restored $relative) $name
        if (-not [IO.File]::Exists((LongPath $expected))) {
            throw "Exact Unicode filename missing after extraction: $name"
        }
    }
}
Write-Host 'PASS: exact Unicode filenames restored'
$longRelative = $longFile.Substring($source.Length).TrimStart('\')
$longRestored = Join-Path $restored $longRelative
if (-not [IO.File]::Exists((LongPath $longRestored))) {
    throw 'Long path did not survive restoration'
}
Write-Host 'PASS: long path survived TAR round trip'

$afterTime = [IO.File]::GetLastWriteTimeUtc((LongPath (Join-Path $restored '.ccache\precision.bin')))
$delta = [math]::Abs(($beforeTime - $afterTime).TotalSeconds)
Write-Host ("7-Zip TAR timestamp delta (s): {0:F7}" -f $delta)
if ($delta -gt 2.0) { throw 'Unexpected timestamp loss beyond 2 seconds' }

# Legacy POSIX-TAR timestamp comparison: compatibility measurement, not an AP cache-hit test.
Push-Location $source
try {
    & tar.exe --format=posix -cf $legacy '.ccache/precision.bin'
    $legacyExit = $LASTEXITCODE
}
finally { Pop-Location }
if ($legacyExit -eq 0) {
    [IO.Directory]::CreateDirectory((LongPath $legacyRestored)) | Out-Null
    & $sevenZip x -ttar -y "-o$legacyRestored" $legacy | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Legacy POSIX-TAR extraction failed' }
    $legacyFile = Join-Path $legacyRestored '.ccache\precision.bin'
    if ((Sha256 (LongPath $legacyFile)) -ne (Sha256 (LongPath $timestampFile))) {
        throw 'Legacy POSIX-TAR file content hash mismatch'
    }
    $legacyTime = [IO.File]::GetLastWriteTimeUtc((LongPath $legacyFile))
    Write-Host ("Legacy POSIX-TAR timestamp delta (s): {0:F7}" -f ([math]::Abs(($beforeTime - $legacyTime).TotalSeconds)))
}
else {
    Write-Warning "Legacy POSIX-TAR comparison unavailable, exit=$legacyExit"
}
Write-Host 'PASS: archive verification finished'
Write-Host "Test directory (ephemeral): $root"
