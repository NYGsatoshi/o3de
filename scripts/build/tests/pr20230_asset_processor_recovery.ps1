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
    [ValidateRange(1, 14400)][int]$AssetTimeoutSeconds = 5400,
    [string]$ExpectedEngineCommit = '',
    [ValidateRange(0, 64)][int]$MaxJobs = 0,
    [switch]$CompareZeroAnalysisBaseline,
    [switch]$TimestampTruncationProbe,
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

# Approximate the TAR writer's second-only mtime precision *without*
# deleting, replacing, or following content outside this unique test cache.
# This is a metadata-perturbation probe, not an actual TAR restore.
function Truncate-CacheFileTimestamps([string]$CacheDirectory) {
    if (-not [IO.Directory]::Exists($CacheDirectory)) { throw "Missing isolated cache: $CacheDirectory" }
    $seen = 0
    $changed = 0
    $maxLoss = 0.0
    foreach ($file in [IO.Directory]::EnumerateFiles($CacheDirectory, '*', [IO.SearchOption]::AllDirectories)) {
        $attributes = [IO.File]::GetAttributes($file)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to alter a reparse-point file in isolated cache: $file"
        }
        $before = [IO.File]::GetLastWriteTimeUtc($file)
        $newTicks = $before.Ticks - ($before.Ticks % [TimeSpan]::TicksPerSecond)
        $rounded = [datetime]::new($newTicks, [DateTimeKind]::Utc)
        $seen++
        if ($rounded.Ticks -ne $before.Ticks) {
            [IO.File]::SetLastWriteTimeUtc($file, $rounded)
            $actual = [IO.File]::GetLastWriteTimeUtc($file)
            if ($actual.Ticks -ne $rounded.Ticks) {
                throw "File mtime did not round to the requested second: $file"
            }
            $changed++
            $maxLoss = [Math]::Max($maxLoss, ($before - $actual).TotalSeconds)
        }
    }
    return [pscustomobject]@{
        files_seen = $seen
        files_changed = $changed
        maximum_timestamp_loss_seconds = [Math]::Round($maxLoss, 7)
    }
}

function Read-AssetScanCounters([string]$StandardOutput) {
    # Optional: O3DE can log scan stats elsewhere. Missing logs are unknown,
    # never treat an absent counter as zero jobs or as a cache hit.
    if (-not [IO.File]::Exists($StandardOutput)) { return $null }
    $pattern = 'Assessing files from scanner complete\. Total files: (\d+)\. Assets with new builders: (\d+)\. Unregistered/new files: (\d+)\. Old timestamps: (\d+)\. Modified dependencies: (\d+)\.'
    $matchLine = Select-String -LiteralPath $StandardOutput -Pattern $pattern | Select-Object -Last 1
    if (-not $matchLine) { return $null }
    $found = [regex]::Match($matchLine.Line, $pattern)
    if (-not $found.Success) { return $null }
    return [pscustomobject]@{
        total_files = [int]$found.Groups[1].Value
        builders_changed = [int]$found.Groups[2].Value
        new_files = [int]$found.Groups[3].Value
        old_timestamps = [int]$found.Groups[4].Value
        modified_dependencies = [int]$found.Groups[5].Value
    }
}

function Invoke-IsolatedBatch([int]$Attempt, [string]$Exe, [string[]]$Arguments, [string]$LogDirectory, [int]$TimeoutSeconds) {
    $out = Join-Path $LogDirectory ('ap-{0}-stdout.txt' -f $Attempt)
    $err = Join-Path $LogDirectory ('ap-{0}-stderr.txt' -f $Attempt)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory (Split-Path -Parent $Exe) -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru -ErrorAction Stop
    $timedOut = $false
    try {
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            # Only terminate the process tree started by this harness.
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            if (-not $process.WaitForExit(10000)) { throw "Failed to stop timed-out AssetProcessorBatch process $($process.Id)" }
        }
        else { $process.WaitForExit() }
        $process.Refresh()
        $code = if ($timedOut) { 124 } else { [int]$process.ExitCode }
    }
    finally {
        $stopwatch.Stop()
        $process.Dispose()
    }
    Write-Host ("AssetProcessor attempt {0}: exit={1}, elapsed={2:N1}s" -f $Attempt, $code, $stopwatch.Elapsed.TotalSeconds)
    return [pscustomobject]@{
        attempt = $Attempt
        exit_code = $code
        timed_out = [bool]$timedOut
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
    engine_git_head = $null
    expected_engine_commit = $ExpectedEngineCommit
    max_jobs_override = $MaxJobs
    zero_analysis_comparison_requested = [bool]$CompareZeroAnalysisBaseline
    timestamp_probe_requested = [bool]$TimestampTruncationProbe
    timestamp_probe_method = 'seconds-only mtime truncation in a unique isolated cache (not a TAR restore)'
    timestamp_probe_files_seen = $null
    timestamp_probe_files_changed = $null
    timestamp_probe_max_loss_seconds = $null
    timestamp_probe_normal_warm_seconds = $null
    timestamp_probe_post_truncation_seconds = $null
    timestamp_probe_elapsed_ratio = $null
    timestamp_probe_warm_scan_counters = $null
    timestamp_probe_post_scan_counters = $null
    timestamp_probe_post_exit_code = $null
    timestamp_probe_product_sha256_matches = $null
    zero_analysis_baseline_arguments = $null
    zero_analysis_baseline_exit_code = $null
    zero_analysis_baseline_restored = $null
    zero_analysis_baseline_sha256_matches = $null
    zero_analysis_comparison_distinguishes = $null
    asset_processor_binary_sha256 = $null
    asset_processor_binary_last_write_utc = $null
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
    if ($TimestampTruncationProbe -and -not $WarmRun) {
        throw 'TimestampTruncationProbe requires -WarmRun to establish an unchanged-cache baseline'
    }
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

    # The source revision is recorded alongside binary provenance. If a SHA
    # is supplied, reject a build checkout from an unintended PR revision.
    $gitExecutable = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $gitExecutable) {
        $rev = @(& git -C $EngineSource rev-parse --verify HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $rev.Count -eq 1 -and $rev[0] -match '^[0-9a-fA-F]{40}$') {
            $report.engine_git_head = $rev[0]
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedEngineCommit)) {
        if ($ExpectedEngineCommit -notmatch '^[0-9a-fA-F]{7,40}$') {
            throw 'ExpectedEngineCommit must be a hexadecimal Git SHA prefix (7 to 40 characters)'
        }
        if (-not $report.engine_git_head -or -not $report.engine_git_head.StartsWith($ExpectedEngineCommit, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Engine revision mismatch: expected $ExpectedEngineCommit; actual $($report.engine_git_head)"
        }
    }

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
    if ($MaxJobs -gt 0) {
        # Limit AssetProcessor workers on memory-constrained local machines.
        # 0 retains the engine's automatic default from settings.assetprocessorbatch.setreg.
        $args += ('--regset="/Amazon/AssetProcessor/Settings/Jobs/maxJobs=' + $MaxJobs + '"')
        Write-Host "AssetProcessor maxJobs override: $MaxJobs"
    }
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
        $apInfo = [IO.FileInfo]::new($ap)
        $report.asset_processor_binary_sha256 = Get-Sha256 $ap
        $report.asset_processor_binary_last_write_utc = $apInfo.LastWriteTimeUtc.ToString('o')
        Write-Host "AssetProcessor binary SHA256: $($report.asset_processor_binary_sha256)"

        $cold = Invoke-IsolatedBatch -Attempt 1 -Exe $ap -Arguments $args -LogDirectory $logs -TimeoutSeconds $AssetTimeoutSeconds
        $runResults.Add($cold)
        if ($cold.timed_out) { throw "AssetProcessorBatch timed out on attempt 1 after $AssetTimeoutSeconds seconds" }
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
            if ($warm.timed_out) { throw "AssetProcessorBatch timed out on attempt 2 after $AssetTimeoutSeconds seconds" }
            if (-not [IO.File]::Exists($productPath) -or (Get-Sha256 $productPath) -cne $sourceHash) {
                throw 'Warm-run cache integrity check failed'
            }
            if ($MaterialPipelineProbe -and (-not [IO.File]::Exists($materialPath) -or (Get-Sha256 $materialPath) -cne $materialHash)) {
                throw 'Material Type Builder intermediate cache changed or disappeared on warm scan'
            }
            Write-Host 'PASS: unchanged asset remains correct on warm scan'
        }
        if ($TimestampTruncationProbe) {
            # The warm scan above is the reference. Seed a deterministic
            # fractional mtime on one isolated product so the experiment
            # cannot silently become a no-op on a whole-second filesystem.
            $preRound = [IO.File]::GetLastWriteTimeUtc($productPath)
            $seedTicks = $preRound.Ticks - ($preRound.Ticks % [TimeSpan]::TicksPerSecond) + 1234567
            [IO.File]::SetLastWriteTimeUtc($productPath, [datetime]::new($seedTicks, [DateTimeKind]::Utc))
            if ((Get-Sha256 $productPath) -cne $sourceHash) {
                throw 'Timestamp fixture unexpectedly changed product content'
            }
            $changedTimes = Truncate-CacheFileTimestamps $cache
            $report.timestamp_probe_files_seen = $changedTimes.files_seen
            $report.timestamp_probe_files_changed = $changedTimes.files_changed
            $report.timestamp_probe_max_loss_seconds = $changedTimes.maximum_timestamp_loss_seconds
            $report.timestamp_probe_normal_warm_seconds = $warm.elapsed_seconds
            $report.timestamp_probe_warm_scan_counters = Read-AssetScanCounters $warm.stdout
            if ($changedTimes.files_changed -eq 0) { throw 'Timestamp probe did not alter any cache file mtimes' }
            $postAttempt = 3
            $post = Invoke-IsolatedBatch -Attempt $postAttempt -Exe $ap -Arguments $args -LogDirectory $logs -TimeoutSeconds $AssetTimeoutSeconds
            $runResults.Add($post)
            $report.timestamp_probe_post_exit_code = $post.exit_code
            $report.timestamp_probe_post_truncation_seconds = $post.elapsed_seconds
            $report.timestamp_probe_post_scan_counters = Read-AssetScanCounters $post.stdout
            if ($warm.elapsed_seconds -gt 0) {
                $report.timestamp_probe_elapsed_ratio = [Math]::Round($post.elapsed_seconds / $warm.elapsed_seconds, 3)
            }
            if ($post.timed_out) { throw "AssetProcessorBatch timed out on timestamp probe after $AssetTimeoutSeconds seconds" }
            $hashMatches = [IO.File]::Exists($productPath) -and ((Get-Sha256 $productPath) -ceq $sourceHash)
            $report.timestamp_probe_product_sha256_matches = [bool]$hashMatches
            if (-not $hashMatches) { throw 'Timestamp probe product SHA256 mismatch or missing product' }
            Write-Host ("PASS: timestamp-only probe preserved product SHA256; {0}/{1} cache file mtimes changed, post/warm duration ratio={2}" -f $changedTimes.files_changed, $changedTimes.files_seen, $report.timestamp_probe_elapsed_ratio)
            Write-Host 'NOTE: timing/scan counters are observational, not a proof of cache-hit equivalence'
        }
        $recoveryAttempt = 2 + [int][bool]$WarmRun + [int][bool]$TimestampTruncationProbe
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
        if ($recovery.timed_out) { throw "AssetProcessorBatch timed out on attempt $recoveryAttempt after $AssetTimeoutSeconds seconds" }

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


        # Negative control: remove the successfully recovered isolated product
        # again, then scan exactly the same project/cache with zeroAnalysisMode.
        # Do not treat a nonzero baseline process as evidence for the flag:
        # an unrelated failure could also prevent regeneration.
        if ($CompareZeroAnalysisBaseline) {
            Remove-Item -LiteralPath $productPath -Force -ErrorAction Stop
            if ([IO.File]::Exists($productPath)) { throw 'Could not inject baseline missing-product fault' }
            $baselineArgs = @($args) + @('--zeroAnalysisMode')
            $report.zero_analysis_baseline_arguments = $baselineArgs
            $baseline = Invoke-IsolatedBatch -Attempt ($recoveryAttempt + 1) -Exe $ap -Arguments $baselineArgs -LogDirectory $logs -TimeoutSeconds $AssetTimeoutSeconds
            $runResults.Add($baseline)
            if ($baseline.timed_out) { throw "zeroAnalysisMode baseline timed out after $AssetTimeoutSeconds seconds" }
            $baselineRestored = [IO.File]::Exists($productPath)
            $baselineHashMatches = $baselineRestored -and ((Get-Sha256 $productPath) -ceq $sourceHash)
            $report.zero_analysis_baseline_exit_code = $baseline.exit_code
            $report.zero_analysis_baseline_restored = [bool]$baselineRestored
            $report.zero_analysis_baseline_sha256_matches = if ($baselineRestored) { [bool]$baselineHashMatches } else { $null }
            $report.zero_analysis_comparison_distinguishes = [bool](($baseline.exit_code -eq 0) -and -not $baselineRestored)
            if ($baselineRestored -and -not $baselineHashMatches) {
                throw 'zeroAnalysisMode baseline generated a product with mismatching SHA256'
            }
            Write-Host ("Baseline zeroAnalysisMode: exit={0}, product regenerated={1}, distinguishes={2}" -f $baseline.exit_code, $baselineRestored, $report.zero_analysis_comparison_distinguishes)
        }

        if ($report.batch_full_success) {
            if ($CompareZeroAnalysisBaseline -and -not $report.zero_analysis_comparison_distinguishes) {
                $report.status = 'INCONCLUSIVE'
                $exitStatus = 3
                Write-Warning 'Real recovery succeeded, but zeroAnalysisMode baseline did not establish a clean negative control.'
            }
            else {
                $report.status = 'PASS'
                $exitStatus = 0
                Write-Host 'PASS: all normal-analysis AssetProcessorBatch invocations exited 0'
                if ($CompareZeroAnalysisBaseline) { Write-Host 'PASS: the successful zeroAnalysisMode baseline did not regenerate the removed product' }
            }
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
