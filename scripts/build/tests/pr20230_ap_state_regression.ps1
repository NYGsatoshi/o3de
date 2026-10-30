# Copyright (c) Contributors to the Open 3D Engine Project.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Executes the real PR20230 PowerShell recovery harness against a simulated
# AssetProcessorBatch.exe. This is a state-machine test, NOT an O3DE AP test.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$harness = Join-Path $PSScriptRoot 'pr20230_asset_processor_recovery.ps1'
$fakeProject = Join-Path $PSScriptRoot 'pr20230_fixtures\FakeAssetProcessor.csproj'
$temp = Join-Path $env:RUNNER_TEMP ('pr20230-ap-matrix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$build = Join-Path $temp 'fake-binary'
$bin = Join-Path $build 'bin\profile'
[IO.Directory]::CreateDirectory($bin) | Out-Null

& dotnet build $fakeProject --configuration Release --output $bin --nologo --property:RestoreIgnoreFailedSources=true
$buildExit = $LASTEXITCODE
if ($buildExit -ne 0) { throw "Cannot build fake AssetProcessorBinary: $buildExit" }
if (-not [IO.File]::Exists((Join-Path $bin 'AssetProcessorBatch.exe'))) {
    # The csproj assembly name is FakeAssetProcessor by default; retain all
    # runtime dependencies and rename the apphost/DLL consistently.
    $originalExe = Join-Path $bin 'FakeAssetProcessor.exe'
    if (-not [IO.File]::Exists($originalExe)) { throw 'Fake AP apphost was not generated' }
    [IO.File]::Copy($originalExe, (Join-Path $bin 'AssetProcessorBatch.exe'))
    # The apphost points to FakeAssetProcessor.dll, which remains in the dir.
}
$fake = Join-Path $bin 'AssetProcessorBatch.exe'
if (-not [IO.File]::Exists($fake)) { throw "Missing mock AP at $fake" }
Write-Host 'PASS: compiled isolated, framework-dependent fake AssetProcessorBatch.exe'

$matrix = @(
    [pscustomobject]@{ name='success'; mode='pass'; expected='PASS'; code=0; runs=2; warm=$false; material=$false; hash=$true; materialHash=$null; errorPattern=$null },
    [pscustomobject]@{ name='partial'; mode='nonzero-but-restored'; expected='PARTIAL'; code=2; runs=2; warm=$false; material=$false; hash=$true; materialHash=$null; errorPattern=$null },
    [pscustomobject]@{ name='missing-copy'; mode='missing-copy'; expected='FAIL'; code=1; runs=2; warm=$false; material=$false; hash=$false; materialHash=$null; errorPattern='NOT regenerated' },
    [pscustomobject]@{ name='bad-copy'; mode='bad-copy'; expected='FAIL'; code=1; runs=2; warm=$false; material=$false; hash=$false; materialHash=$null; errorPattern='SHA256 does not match' },
    [pscustomobject]@{ name='initial-missing'; mode='initial-product-missing'; expected='FAIL'; code=1; runs=1; warm=$false; material=$false; hash=$false; materialHash=$null; errorPattern='Initial copy-job product missing' },
    [pscustomobject]@{ name='warm-material-success'; mode='pass'; expected='PASS'; code=0; runs=3; warm=$true; material=$true; hash=$true; materialHash=$true; errorPattern=$null },
    [pscustomobject]@{ name='missing-azsl'; mode='missing-azsl'; expected='FAIL'; code=1; runs=2; warm=$false; material=$true; hash=$true; materialHash=$false; errorPattern='AZSL intermediate was NOT regenerated' },
    [pscustomobject]@{ name='bad-azsl'; mode='bad-azsl'; expected='FAIL'; code=1; runs=2; warm=$false; material=$true; hash=$true; materialHash=$false; errorPattern='AZSL intermediate SHA256 mismatch' }
)
$oldMode = [Environment]::GetEnvironmentVariable('PR20230_FAKE_AP_MODE')
try {
    foreach ($case in $matrix) {
        $env:PR20230_FAKE_AP_MODE = $case.mode
        $work = Join-Path $temp ("state " + $case.name)
        # A hashtable is required for named-parameter splatting. An array
        # would bind these tokens positionally and corrupt parameter values.
        $parameters = @{
            EngineSource = $repo
            BuildRoot = $build
            WorkRoot = $work
            AssetTimeoutSeconds = 120
        }
        if ($case.warm) { $parameters['WarmRun'] = $true }
        if ($case.material) { $parameters['MaterialPipelineProbe'] = $true }

        & $harness @parameters
        $actualExit = $LASTEXITCODE
        $reports = @(Get-ChildItem -LiteralPath $work -Filter 'report.json' -Recurse -File -ErrorAction Stop)
        if ($reports.Count -ne 1) {
            throw "[$($case.name)] expected one JSON report, got $($reports.Count)"
        }
        $report = Get-Content -LiteralPath $reports[0].FullName -Raw | ConvertFrom-Json
        if ($actualExit -ne $case.code -or $report.status -cne $case.expected) {
            throw "[$($case.name)] exit/status $actualExit/$($report.status), expected $($case.code)/$($case.expected)"
        }
        if (@($report.runs).Count -ne $case.runs) {
            throw "[$($case.name)] unexpected run count $(@($report.runs).Count), expected $($case.runs)"
        }
        if ([bool]$report.sha256_matches -ne [bool]$case.hash) {
            throw "[$($case.name)] incorrect restored copy-job hash status"
        }
        if ($case.material) {
            if ([bool]$report.material_pipeline_sha256_matches -ne [bool]$case.materialHash) {
                throw "[$($case.name)] incorrect restored Material Builder AZSL status"
            }
        }
        if ($case.errorPattern -and [string]$report.error -notmatch $case.errorPattern) {
            throw "[$($case.name)] unexpected failure diagnostic: $($report.error)"
        }
        if ($report.status -eq 'PARTIAL' -and $report.batch_full_success) {
            throw 'PARTIAL incorrectly reports full Batch success'
        }
        if ($report.status -eq 'PASS' -and -not $report.batch_full_success) {
            throw 'PASS incorrectly reports an unsuccessful Batch'
        }
        Write-Host "PASS: state $($case.name) -> $($report.status), exit $actualExit, $($case.runs) attempt(s)"
    }
}
finally {
    [Environment]::SetEnvironmentVariable('PR20230_FAKE_AP_MODE', $oldMode)
}
Write-Host "PASS: $($matrix.Count) AssetProcessor harness state-machine cases"
exit 0
