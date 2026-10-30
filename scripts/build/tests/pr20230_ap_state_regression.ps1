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
    [pscustomobject]@{ name='baseline-contrast'; mode='pass'; expected='PASS'; code=0; runs=3; warm=$false; material=$false; hash=$true; materialHash=$null; errorPattern=$null },
    [pscustomobject]@{ name='baseline-inconclusive'; mode='baseline-regenerates'; expected='INCONCLUSIVE'; code=3; runs=3; warm=$false; material=$false; hash=$true; materialHash=$null; errorPattern=$null },
    [pscustomobject]@{ name='missing-copy'; mode='missing-copy'; expected='FAIL'; code=1; runs=2; warm=$false; material=$false; hash=$false; materialHash=$null; errorPattern='NOT regenerated' },
    [pscustomobject]@{ name='bad-copy'; mode='bad-copy'; expected='FAIL'; code=1; runs=2; warm=$false; material=$false; hash=$false; materialHash=$null; errorPattern='SHA256 does not match' },
    [pscustomobject]@{ name='initial-missing'; mode='initial-product-missing'; expected='FAIL'; code=1; runs=1; warm=$false; material=$false; hash=$false; materialHash=$null; errorPattern='Initial copy-job product missing' },
    [pscustomobject]@{ name='warm-material-success'; mode='pass'; expected='PASS'; code=0; runs=3; warm=$true; material=$true; hash=$true; materialHash=$true; errorPattern=$null },
    [pscustomobject]@{ name='missing-azsl'; mode='missing-azsl'; expected='FAIL'; code=1; runs=2; warm=$false; material=$true; hash=$true; materialHash=$false; errorPattern='AZSL intermediate was NOT regenerated' },
    [pscustomobject]@{ name='bad-azsl'; mode='bad-azsl'; expected='FAIL'; code=1; runs=2; warm=$false; material=$true; hash=$true; materialHash=$false; errorPattern='AZSL intermediate SHA256 mismatch' },
    [pscustomobject]@{ name='timeout'; mode='slow-timeout'; expected='FAIL'; code=1; runs=1; warm=$false; material=$false; hash=$false; materialHash=$null; errorPattern='timed out on attempt 1' },
    [pscustomobject]@{ name='revision-mismatch'; mode='pass'; expected='FAIL'; code=1; runs=0; warm=$false; material=$false; hash=$false; materialHash=$null; errorPattern='Engine revision mismatch' }
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
        if ($case.name -like 'baseline-*') { $parameters['CompareZeroAnalysisBaseline'] = $true }
        if ($case.material) { $parameters['MaterialPipelineProbe'] = $true }
        if ($case.name -eq 'success') { $parameters['MaxJobs'] = 2 }
        if ($case.name -eq 'timeout') { $parameters['AssetTimeoutSeconds'] = 1 }
        if ($case.name -eq 'revision-mismatch') { $parameters['ExpectedEngineCommit'] = '0000000000000000000000000000000000000000' }

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
        if ($case.name -eq 'timeout' -and (@($report.runs).Count -ne 1 -or -not $report.runs[0].timed_out -or $report.runs[0].exit_code -ne 124)) {
            throw '[timeout] the timed-out child was not recorded with exit code 124'
        }
        if ($case.name -ne 'revision-mismatch' -and (-not $report.asset_processor_binary_sha256 -or $report.asset_processor_binary_sha256.Length -ne 64)) {
            throw "[$($case.name)] missing binary SHA256 provenance"
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
        if ($case.name -like 'baseline-*') {
            $shouldDistinguish = ($case.name -eq 'baseline-contrast')
            if ([bool]$report.zero_analysis_comparison_distinguishes -ne $shouldDistinguish) {
                throw "[$($case.name)] incorrect zeroAnalysisMode baseline contrast"
            }
            if (@($report.zero_analysis_baseline_arguments | Where-Object { $_ -eq '--zeroAnalysisMode' }).Count -ne 1 -or $report.zero_analysis_baseline_exit_code -ne 0) {
                throw "[$($case.name)] zeroAnalysisMode was not executed exactly once with exit code 0"
            }
            if ([bool]$report.zero_analysis_baseline_restored -eq $shouldDistinguish) {
                throw "[$($case.name)] unexpected baseline cache product state"
            }
        }
        if ($case.name -eq 'success') {
            if ($report.max_jobs_override -ne 2 -or @($report.arguments | Where-Object { $_ -match 'maxJobs=2' }).Count -ne 1) {
                throw '[success] maxJobs override did not reach the AssetProcessor command line'
            }
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
Write-Host "PASS: $($matrix.Count) AssetProcessor harness state-machine cases (including baseline contrast, timeout, and engine revision mismatch)"
exit 0
