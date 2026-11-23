# Copyright (c) Contributors to the Open 3D Engine Project.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Temporary, standalone PR #20230 archive regression probe.
# Runs on Windows; does not touch the O3DE build or project cache.

[CmdletBinding()]
param(
    [ValidateRange(100, 20000)][int]$FileCount = 1024,
    [string]$ExportDirectory,
    [string]$VerifyTransportDirectory
)

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
# Exercise several fractional-second mtimes across every production cache root.
# These are metadata transport checks; real AssetProcessor cache-hit behavior is separate.
$timestampFixtures = @(
    [pscustomobject]@{ Relative = '.ccache\precision.bin'; FractionalTicks = 1234567 }
    [pscustomobject]@{ Relative = '.o3de\python\downloaded_packages\precision.bin'; FractionalTicks = 4567890 }
    [pscustomobject]@{ Relative = '3rdParty\downloaded_packages\precision.bin'; FractionalTicks = 7890123 }
    [pscustomobject]@{ Relative = 'AutomatedTesting\Cache\precision.bin'; FractionalTicks = 9876543 }
)

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
function Assert-TimestampMatrix([object[]]$expected, [string]$directory, [string]$description) {
    if ($expected.Count -ne $timestampFixtures.Count) {
        throw "Missing expected timestamp records: $($expected.Count) / $($timestampFixtures.Count)"
    }
    foreach ($fixture in $timestampFixtures) {
        $matches = @($expected | Where-Object { $_.Relative -ceq $fixture.Relative })
        if ($matches.Count -ne 1) { throw "Missing/duplicate timestamp fixture: $($fixture.Relative)" }
        $path = Join-Path $directory $fixture.Relative
        if (-not [IO.File]::Exists((LongPath $path))) { throw "Missing timestamp file: $path" }
        $expectedUtc = [datetime]::new([long]$matches[0].UtcTicks, [DateTimeKind]::Utc)
        $actualUtc = [IO.File]::GetLastWriteTimeUtc((LongPath $path))
        $delta = [math]::Abs(($expectedUtc - $actualUtc).TotalSeconds)
        Write-Host ("{0} timestamp delta ({1}): {2:F7}s" -f $description, $fixture.Relative, $delta)
        if ($delta -gt 1.0) {
            throw "Unexpected timestamp loss exceeding one second: $($fixture.Relative), delta=$delta"
        }
    }
    Write-Host "PASS: $description timestamp matrix across all four cache roots"
}

# Verify the same TAR and source manifest after transfer via GitHub Actions Artifact.
# This runs on an independent Windows runner, not on the producer's filesystem.
if (-not [string]::IsNullOrWhiteSpace($VerifyTransportDirectory)) {
    $bundle = [IO.Path]::GetFullPath($VerifyTransportDirectory)
    $transportArchive = Join-Path $bundle 'cache.tar'
    $manifestFile = Join-Path $bundle 'expected-manifest.txt'
    $timestampManifest = Join-Path $bundle 'expected-timestamps.json'
    if (-not [IO.File]::Exists((LongPath $transportArchive))) {
        throw 'Transported cache.tar is missing'
    }
    if (-not [IO.File]::Exists((LongPath $manifestFile))) {
        throw 'Independent pre-archive manifest is missing'
    }
    if (-not [IO.File]::Exists((LongPath $timestampManifest))) {
        throw 'Independent pre-archive timestamp matrix is missing'
    }
    & $sevenZip t -ttar $transportArchive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Transported TAR structure is invalid' }
    [IO.Directory]::CreateDirectory((LongPath $restored)) | Out-Null
    & $sevenZip x -ttar -y "-o$restored" $transportArchive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Transported TAR extraction failed: $LASTEXITCODE" }

    $expectedManifest = [IO.File]::ReadAllLines((LongPath $manifestFile), [Text.Encoding]::UTF8)
    $actualManifest = @(Manifest $restored)
    if ($expectedManifest.Length -eq 0 -or $expectedManifest.Length -ne $actualManifest.Count) {
        throw "Transported file count mismatch: $($expectedManifest.Length) expected, $($actualManifest.Count) restored"
    }
    for ($j = 0; $j -lt $expectedManifest.Length; $j++) {
        if (-not [string]::Equals($expectedManifest[$j], $actualManifest[$j], [StringComparison]::Ordinal)) {
            throw "Transported path or SHA256 mismatch: $($expectedManifest[$j]) != $($actualManifest[$j])"
        }
    }
    foreach ($relative in $paths) {
        if (-not [IO.Directory]::Exists((LongPath (Join-Path $restored $relative)))) {
            throw "Transported cache directory is missing: $relative"
        }
    }
    $transportedTimestamps = @([IO.File]::ReadAllText((LongPath $timestampManifest), [Text.Encoding]::UTF8) | ConvertFrom-Json)
    Assert-TimestampMatrix $transportedTimestamps $restored 'Transported TAR'
    Write-Host "PASS: GitHub Artifact transport preserved $($actualManifest.Count) paths and SHA256 hashes"
    Write-Host 'PASS: all four cache directories and timestamp fixtures survived independent restoration'
    return
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

$timestampReference = [datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
$timestampRecords = @(
    foreach ($fixture in $timestampFixtures) {
        $file = Join-Path $source $fixture.Relative
        Write-Data $file 'Timestamp precision probe'
        [IO.File]::SetLastWriteTimeUtc((LongPath $file), $timestampReference.AddTicks($fixture.FractionalTicks))
        [pscustomobject]@{
            Relative = $fixture.Relative
            UtcTicks = [IO.File]::GetLastWriteTimeUtc((LongPath $file)).Ticks
        }
    }
)
# Retain the original precision.bin fixture for POSIX TAR comparison.
$timestampFile = Join-Path $source '.ccache\precision.bin'
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

Assert-TimestampMatrix $timestampRecords $restored '7-Zip TAR'

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
if (-not [string]::IsNullOrWhiteSpace($ExportDirectory)) {
    $exportRoot = [IO.Path]::GetFullPath($ExportDirectory)
    [IO.Directory]::CreateDirectory((LongPath $exportRoot)) | Out-Null
    [IO.File]::Copy((LongPath $archive), (LongPath (Join-Path $exportRoot 'cache.tar')), $true)
    $expected = [string[]]@(Manifest $source)
    if ($expected.Length -eq 0) { throw 'Cannot export an empty manifest' }
    [IO.File]::WriteAllLines(
        (LongPath (Join-Path $exportRoot 'expected-manifest.txt')),
        $expected,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (LongPath (Join-Path $exportRoot 'expected-timestamps.json')),
        (ConvertTo-Json -InputObject $timestampRecords -Depth 3),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "PASS: exported TAR and independent $($expected.Length)-file manifest for cross-job verification"
}
Write-Host 'PASS: archive verification finished'
Write-Host "Test directory (ephemeral): $root"
