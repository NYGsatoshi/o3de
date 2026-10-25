# Copyright (c) Contributors to the Open 3D Engine Project.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# PR #20230: execute the Windows CI production extraction step on isolated fixtures.
# No real O3DE caches or build products are modified.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$workflowPath = Join-Path $repoRoot '.github\workflows\windows-build.yml'
$sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
$cachePaths = @(
    '.ccache',
    '.o3de\python\downloaded_packages',
    '3rdParty\downloaded_packages',
    'AutomatedTesting\Cache'
)
if (-not [IO.File]::Exists($workflowPath)) { throw "Missing actual workflow: $workflowPath" }
if (-not [IO.File]::Exists($sevenZip)) { throw "Missing 7-Zip: $sevenZip" }

# Read the real production Extract artifact run block instead of duplicating it
# in the test. Fail closed if the GitHub Actions step is renamed/restructured.
$lines = [IO.File]::ReadAllLines($workflowPath)
$extractMarker = '      - name: Extract artifact'
$extractIndices = @(
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -eq $extractMarker) { $i }
    }
)
if ($extractIndices.Count -ne 1) { throw 'Cannot uniquely locate production Extract artifact step' }
$start = $extractIndices[0]
$finish = $lines.Length
for ($i = $start + 1; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -match '^      - name: ') {
        $finish = $i
        break
    }
}
$runLine = -1
for ($i = $start + 1; $i -lt $finish; $i++) {
    if ($lines[$i] -eq '        run: |') { $runLine = $i; break }
}
if ($runLine -lt 0) { throw 'Production extraction does not contain an inline run block' }
$bodyLines = [Collections.Generic.List[string]]::new()
for ($i = $runLine + 1; $i -lt $finish; $i++) {
    if ($lines[$i].StartsWith('          ')) {
        $bodyLines.Add($lines[$i].Substring(10))
    }
    elseif ($lines[$i].Trim().Length -eq 0) {
        $bodyLines.Add('')
    }
    else {
        throw "Unexpected indentation in the actual extraction step, line $($i + 1)"
    }
}
$productionBody = [string]::Join([Environment]::NewLine, $bodyLines)
foreach ($required in @('7-Zip\7z.exe', ' x -ttar ', 'Remove-Item -LiteralPath $cachePath -Recurse -Force', 'ccache --zero-stats --cleanup')) {
    if (-not $productionBody.Contains($required)) {
        throw "Production extraction contract changed; review required: $required"
    }
}
$extractStep = [scriptblock]::Create($productionBody)
Write-Host 'PASS: extracted actual production Windows CI restore script'

# Intercept only the unrelated ccache maintenance command. 7-Zip extraction
# and every cleanup operation execute unchanged from the production workflow.
$script:ccacheCalls = 0
function ccache {
    $script:ccacheCalls += 1
}
function Put-File([string]$path, [string]$content) {
    [IO.Directory]::CreateDirectory((Split-Path -Path $path -Parent)) | Out-Null
    [IO.File]::WriteAllText($path, $content)
}
$root = Join-Path $env:RUNNER_TEMP ("pr20230-recovery-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$source = Join-Path $root 'source'
[IO.Directory]::CreateDirectory($source) | Out-Null
$expectedFiles = @{
    '.ccache\manifest.bin' = 'ccache should be preserved after valid extraction'
    '.o3de\python\downloaded_packages\package.lock' = 'python package should be preserved'
    '3rdParty\downloaded_packages\thirdparty.lock' = 'third party package should be preserved'
    'AutomatedTesting\Cache\result.azasset' = 'asset cache should be preserved'
}
foreach ($cachePath in $cachePaths) {
    [IO.Directory]::CreateDirectory((Join-Path $source $cachePath)) | Out-Null
}
foreach ($key in $expectedFiles.Keys) {
    Put-File (Join-Path $source $key) $expectedFiles[$key]
}
# A partially extracted archive must report corruption, not just fail to find
# an end-of-archive marker in unused padding. Put real content in the TAR body.
[IO.File]::WriteAllBytes((Join-Path $source '.ccache\large.bin'), [byte[]]::new(131072))
$goodArchive = Join-Path $root 'valid-cache.tar'
Push-Location $source
try {
    & $sevenZip a -ttar -y $goodArchive @cachePaths | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create valid TAR fixture: $LASTEXITCODE" }
}
finally { Pop-Location }
& $sevenZip t -ttar $goodArchive | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Valid fixture failed TAR verification' }

$badArchive = Join-Path $root 'truncated-cache.tar'
$rawArchive = [IO.File]::ReadAllBytes($goodArchive)
if ($rawArchive.Length -lt 65536) { throw 'Fixture TAR too small to reliably truncate' }
$partialSize = 8192
[IO.File]::WriteAllBytes($badArchive, $rawArchive[0..($partialSize - 1)])
& $sevenZip t -ttar $badArchive | Out-Null
if ($LASTEXITCODE -eq 0) {
    throw 'Invalid corruption fixture: truncated TAR passed structural verification'
}
Write-Host "PASS: truncated fixture rejected by real 7-Zip (exit $LASTEXITCODE)"

function Invoke-RealExtraction([string]$workspace, [string]$sourceArchive, [bool]$shouldRecover) {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    # A pre-existing cache must be deleted completely on corruption.
    foreach ($cachePath in $cachePaths) {
        Put-File (Join-Path (Join-Path $workspace $cachePath) 'stale-marker.bin') 'must disappear on failed restore'
    }
    [IO.File]::Copy($sourceArchive, (Join-Path $workspace 'cache.tar'))
    $priorWorkspace = [Environment]::GetEnvironmentVariable('DEV_DRIVE_WORKSPACE')
    $env:DEV_DRIVE_WORKSPACE = $workspace
    $script:ccacheCalls = 0
    try {
        Push-Location $workspace
        try {
            $messages = @(& $extractStep 3>&1)
        }
        finally { Pop-Location }
    }
    finally {
        [Environment]::SetEnvironmentVariable('DEV_DRIVE_WORKSPACE', $priorWorkspace)
    }
    if ($script:ccacheCalls -ne 1) { throw "Production ccache call count was $script:ccacheCalls instead of 1" }
    if ([IO.File]::Exists((Join-Path $workspace 'cache.tar'))) {
        throw 'Production step left cache.tar after extraction'
    }
    $warningCount = @($messages | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count
    if ($shouldRecover) {
        if ($warningCount -ne 0) { throw 'Valid TAR unexpectedly triggered a recovery warning' }
        foreach ($file in $expectedFiles.Keys) {
            $target = Join-Path $workspace $file
            if (-not [IO.File]::Exists($target)) { throw "Valid cache lost file: $file" }
            if ([IO.File]::ReadAllText($target) -cne $expectedFiles[$file]) {
                throw "Valid cache corrupted file: $file"
            }
        }
        if (([IO.FileInfo](Join-Path $workspace '.ccache\large.bin')).Length -ne 131072) {
            throw 'Valid cache lost or truncated large.bin'
        }
        Write-Host 'PASS: actual production extraction retains all four valid caches'
    }
    else {
        if ($warningCount -eq 0) { throw 'Corrupt TAR was not reported as invalid by production step' }
        foreach ($cachePath in $cachePaths) {
            if ([IO.Directory]::Exists((Join-Path $workspace $cachePath))) {
                throw "Production step did not purge cache directory: $cachePath"
            }
        }
        Write-Host 'PASS: actual production extraction detects truncation and purges all four caches'
    }
}
Invoke-RealExtraction (Join-Path $root 'healthy-workspace') $goodArchive $true
Invoke-RealExtraction (Join-Path $root 'corrupt-workspace') $badArchive $false
Write-Host 'PASS: actual Windows CI cache restore regression suite'
