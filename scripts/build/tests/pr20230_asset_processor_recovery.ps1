# Copyright (c) Contributors to the Open 3D Engine Project.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Independent AssetProcessorBatch cache-regeneration probe for PR #20230.
# Requires a locally built AssetProcessorBatch.exe for full integration mode.
# Never modifies an existing project's assets, cache, or engine source.

#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$EngineSource = (Join-Path $HOME 'o3de-src'),
    [string]$BuildRoot = (Join-Path $HOME 'o3de-build'),
    [string]$WorkRoot = (Join-Path $HOME 'p30'),
    [ValidateRange(60, 14400)][int]$AssetTimeoutSeconds = 5400,
    [switch]$PreflightOnly,
    [switch]$WarmRun,
    [switch]$MaterialPipelineProbe,
    [switch]$KeepCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Summarize-Errors([string[]]$Paths) {
    $find = 'exceeds the max path length|Too long header name|Can.t open include file|fatal error:|JOB LOG:.*ERROR|Builder indicated that the job has failed'
    $out = [Collections.Generic.List[string]]::new()
    foreach ($file in $Paths) {
        if (-not [IO.File]::Exists($file)) { continue }
        foreach ($entry in (Select-String -LiteralPath $file -Pattern $find | Select-Object -First 18)) {
            if ($out.Count -ge 30) { break }
            $line = [string]$entry.Line
            if ($line.Length -gt 700) { $line = $line.Substring(0, 700) }
            $out.Add($line)
        }
    }
    return $out.ToArray()
}

function Invoke-IsolatedBatch([int]$Attempt, [string]$Exe, [string[]]$Arguments, [string]$LogDirectory, [int]$TimeoutSeconds) {
    $out = Join-Path $LogDirectory ('ap-{0}-stdout.txt' -f $Attempt)
    $err = Join-Path $LogDirectory ('ap-{0}-stderr.txt' -f $Attempt)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory (Split-Path -Parent $Exe) -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru -ErrorAction Stop
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Only terminate the child process started by this harness.
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            throw "AssetProcessorBatch timed out on attempt $Attempt after $TimeoutSeconds seconds"
        }
        $process.WaitForExit()
        $process.Refresh()
        $code = [int]$process.ExitCode
    }
    finally {
        $stopwatch.Stop()
        $process.Dispose()
    }
    Write-Host ("AssetProcessor attempt {0}: exit={1}, elapsed={2:N1}s" -f $Attempt, $code, $stopwatch.Elapsed.TotalSeconds)
    return [pscustomobject]@{
        attempt = $Attempt
        exit_code = $code
        elapsed_seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        stdout = $out
        stderr = $err
    }
}

$report = [ordered]@{
    test = 'O3DE PR20230 AssetProcessorCacheRecovery'
    generated_utc = [DateTime]::UtcNow.ToString('o')
    status = 'NOT_STARTED'
    engine_source = $EngineSource
    build_root = $BuildRoot
    work_root = $WorkRoot
    expected_probe_relative_path = 'pc/assets/pr20230_cache_probe.mp4'
    product_restored = $false
    sha256_matches = $false
    material_pipeline_requested = [bool]$MaterialPipelineProbe
    material_pipeline_restored = $null
    material_pipeline_sha256_matches = $null
    batch_full_success = $false
    runs = @()
    diagnostics = @()
    error = $null
}

$runId = 'r' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$caseRoot = $null
$cache = $null
$reportPath = $null
$probe = $null
$sourceHash = $null
$productPath = $null
$materialPath = $null
$materialHash = $null
$runResults = [Collections.Generic.List[object]]::new()
$exitStatus = 1
$createdCase = $false

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This probe must run on Windows.' }
    $EngineSource = [IO.Path]::GetFullPath($EngineSource).TrimEnd('\')
    $BuildRoot = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\')
    $WorkRoot = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
    if (-not [IO.File]::Exists((Join-Path $EngineSource 'engine.json'))) {
        throw "O3DE engine.json not found: $EngineSource"
    }
    foreach ($forbidden in @($EngineSource, $BuildRoot)) {
        if ($WorkRoot.Equals($forbidden, [StringComparison]::OrdinalIgnoreCase) -or $WorkRoot.StartsWith(($forbidden + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "WorkRoot must not be inside the O3DE source/build directory: $WorkRoot"
        }
    }

    $caseRoot = Join-Path $WorkRoot $runId
    $project = Join-Path $caseRoot 'p'
    $cache = Join-Path $caseRoot 'c'
    $user = Join-Path $caseRoot 'u'
    $logs = Join-Path $caseRoot 'logs'
    $evidence = Join-Path $caseRoot 'evidence'
    $reportPath = Join-Path $evidence 'report.json'

    # Reproduce the long material-canvas product path from the previous failed
    # local run before starting expensive processing.
    $worstKnown = Join-Path $cache 'Intermediate Assets\materialcanvas\graphdata\nodes\materialoutputs\standardpbr\materialgraphname_lowendpipeline_forwardpass_standardlighting_customz.azsl'
    $report.expected_worst_known_path_length = $worstKnown.Length
    Write-Host "Isolated root: $caseRoot"
    Write-Host "Previous 260-char failure-path estimate: $($worstKnown.Length) characters"
    if ($worstKnown.Length -ge 240) {
        throw "Isolated root is too long ($($worstKnown.Length) chars); choose a shorter -WorkRoot"
    }
    if ([IO.Directory]::Exists($caseRoot) -or [IO.File]::Exists($caseRoot)) {
        throw "Refusing to reuse a pre-existing test directory: $caseRoot"
    }

    foreach ($directory in @($project, $cache, $user, $logs, $evidence, (Join-Path $project 'Assets'), (Join-Path $project 'Registry'))) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $createdCase = $true
    $report.engine_source = $EngineSource
    $report.build_root = $BuildRoot
    $report.work_root = $WorkRoot
    $report.case_root = $caseRoot

    $metadata = [ordered]@{
        project_name = 'Pr20230CacheProbe'
        display_name = 'PR20230 cache recovery'
        project_id = ([guid]::NewGuid().ToString('B'))
        version = '1.0.0'
        engine = 'o3de'
        gem_names = @()
        external_subdirectories = @()
    }
    [IO.File]::WriteAllText((Join-Path $project 'project.json'), ($metadata | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $probe = Join-Path $project 'Assets\pr20230_cache_probe.mp4'
    [IO.File]::WriteAllBytes($probe, [Text.Encoding]::UTF8.GetBytes('PR20230 deterministic cache recovery probe'))
    $sourceHash = Get-Sha256 $probe
    $report.source_sha256 = $sourceHash
    $productPath = Join-Path $cache 'pc\assets\pr20230_cache_probe.mp4'
    Write-Host "Probe source SHA256: $sourceHash"

    $args = @(
        ('--project-path="' + $project + '"'),
        ('--engine-path="' + $EngineSource + '"'),
        ('--project-cache-path="' + $cache + '"'),
        ('--project-user-path="' + $user + '"'),
        ('--project-log-path="' + $logs + '"'),
        '--platforms=pc',
        '--ignoreFutureAssetDatabaseVersionError'
    )
    if (@($args | Where-Object { $_ -match 'zeroAnalysisMode' }).Count -gt 0) {
        throw 'zeroAnalysisMode must not be enabled during recovery validation'
    }
    $report.arguments = $args

    if ($PreflightOnly) {
        $report.status = 'PREFLIGHT_PASS'
        $exitStatus = 0
        Write-Host 'PASS: short-path synthetic project, CLI flags, source hash and safety guards'
    }
    else {
        $ap = Join-Path $BuildRoot 'bin\profile\AssetProcessorBatch.exe'
        if (-not [IO.File]::Exists($ap)) { throw "AssetProcessorBatch.exe not found: $ap" }

        $cold = Invoke-IsolatedBatch -Attempt 1 -Exe $ap -Arguments $args -LogDirectory $logs -TimeoutSeconds $AssetTimeoutSeconds
        $runResults.Add($cold)
        if (-not [IO.File]::Exists($productPath)) {
            throw "Initial copy-job product missing: $productPath"
        }
        $initialHash = Get-Sha256 $productPath
        if ($initialHash -cne $sourceHash) {
            throw 'Initial AssetProcessor product SHA256 differs from input'
        }
        Write-Host 'PASS: initial isolated project product SHA256 equals source'

        if ($MaterialPipelineProbe) {
            # The original poisoned cache affected Material Type Builder's
            # intermediate AZSL outputs, not just simple copy-job products.
            # Choose one actual generated AZSL file after the first AP scan.
            $materialRoot = Join-Path $cache 'Intermediate Assets\materials\types'
            if (-not [IO.Directory]::Exists($materialRoot)) {
                throw "No Material Type Builder intermediate cache directory: $materialRoot"
            }
            $candidates = @(Get-ChildItem -LiteralPath $materialRoot -Filter '*.azsl' -Recurse -File -ErrorAction Stop | Sort-Object FullName)
            if ($candidates.Count -eq 0) {
                throw 'MaterialPipelineProbe requires an actual generated .azsl intermediate output; none were found'
            }
            $materialPath = $candidates[0].FullName
            $materialHash = Get-Sha256 $materialPath
            $report.material_pipeline_product = $materialPath
            $report.material_pipeline_original_sha256 = $materialHash
            Write-Host "Material Type Builder intermediate fixture: $materialPath"
        }

        if ($WarmRun) {
            $warm = Invoke-IsolatedBatch -Attempt 2 -Exe $ap -Arguments $args -LogDirectory $logs -TimeoutSeconds $AssetTimeoutSeconds
            $runResults.Add($warm)
            if (-not [IO.File]::Exists($productPath) -or (Get-Sha256 $productPath) -cne $sourceHash) {
                throw 'Warm-run cache integrity check failed'
            }
            if ($MaterialPipelineProbe -and (-not [IO.File]::Exists($materialPath) -or (Get-Sha256 $materialPath) -cne $materialHash)) {
                throw 'Material Type Builder intermediate cache changed or disappeared on warm scan'
            }
            Write-Host 'PASS: unchanged asset remains correct on warm scan'
        }
        $recoveryAttempt = if ($WarmRun) { 3 } else { 2 }
        Remove-Item -LiteralPath $productPath -Force -ErrorAction Stop
        if ([IO.File]::Exists($productPath)) { throw 'Could not delete the isolated product fixture' }
        if ($MaterialPipelineProbe) {
            Remove-Item -LiteralPath $materialPath -Force -ErrorAction Stop
            if ([IO.File]::Exists($materialPath)) { throw 'Could not remove the isolated AZSL intermediate' }
            Write-Host 'Injected fault: removed both synthetic copy-job product and one actual Material Type Builder AZSL'
        }
        else {
            Write-Host 'Injected fault: removed only the synthetic cache product'
        }
        $recovery = Invoke-IsolatedBatch -Attempt $recoveryAttempt -Exe $ap -Arguments $args -LogDirectory $logs -TimeoutSeconds $AssetTimeoutSeconds
        $runResults.Add($recovery)

        $restored = [IO.File]::Exists($productPath)
        $matching = $restored -and ((Get-Sha256 $productPath) -cne $sourceHash) -eq $false
        $report.product_restored = [bool]$restored
        $report.sha256_matches = [bool]$matching
        $report.batch_full_success = (@($runResults | Where-Object { $_.exit_code -ne 0 }).Count -eq 0)
        if (-not $restored) { throw 'Isolated missing product was NOT regenerated' }
        if (-not $matching) { throw 'Regenerated product SHA256 does not match source' }
        Write-Host 'PASS: deleted isolated product regenerated with matching SHA256'
        if ($MaterialPipelineProbe) {
            $materialRestored = [IO.File]::Exists($materialPath)
            $materialMatching = $materialRestored -and ((Get-Sha256 $materialPath) -ceq $materialHash)
            $report.material_pipeline_restored = [bool]$materialRestored
            $report.material_pipeline_sha256_matches = [bool]$materialMatching
            if (-not $materialRestored) { throw 'Material Type Builder AZSL intermediate was NOT regenerated' }
            if (-not $materialMatching) { throw 'Regenerated AZSL intermediate SHA256 mismatch' }
            Write-Host 'PASS: missing Material Type Builder AZSL intermediate regenerated with matching SHA256'
        }

        if ($report.batch_full_success) {
            $report.status = 'PASS'
            $exitStatus = 0
            Write-Host 'PASS: all AssetProcessorBatch invocations exited 0'
        }
        else {
            $report.status = 'PARTIAL'
            $exitStatus = 2
            Write-Warning 'Target cache was correctly recovered, but other AssetProcessor jobs exited nonzero.'
        }
    }
}
catch {
    $report.status = 'FAIL'
    $report.error = $_.Exception.Message
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    $exitStatus = 1
}
finally {
    $report.runs = @($runResults.ToArray())
    if ($caseRoot -and $createdCase) {
        if ($cache) {
            $logsFound = @($runResults | ForEach-Object { $_.stdout; $_.stderr })
            $report.diagnostics = @(Summarize-Errors -Paths $logsFound)
        }
        try {
            $json = ConvertTo-Json -InputObject $report -Depth 8
            [IO.File]::WriteAllText($reportPath, $json, [Text.UTF8Encoding]::new($false))
            Write-Host "Machine-readable report: $reportPath"
        }
        catch {
            Write-Warning "Unable to save report: $($_.Exception.Message)"
        }
        # Keep evidence even when dropping generated caches; never touch
        # global or existing O3DE assets. Use -KeepCache for detailed analysis.
        if (-not $KeepCache -and $cache -and [IO.Directory]::Exists($cache)) {
            try {
                Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction Stop
                Write-Host 'Removed only this run isolated cache (logs/report preserved)'
            }
            catch {
                Write-Warning "Unable to remove isolated cache: $($_.Exception.Message)"
            }
        }
    }
}
exit $exitStatus
