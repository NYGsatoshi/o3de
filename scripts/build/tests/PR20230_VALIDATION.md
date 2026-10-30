# PR #20230: isolated archive and AssetProcessor verification

This file belongs to the **fork-only test branch** `test/pr20230-cache-archive-20261025`. It is not part of the upstream three-file fix and should not be merged into the upstream PR as a production change.

## Evidence and coverage

- The upstream fix is [o3de/o3de#20230](https://github.com/o3de/o3de/pull/20230). The latest production workflow and both platform build configurations were compared byte-for-byte with upstream PR HEAD `671e439e986dd8a75a89578ca27f50ce04a9d36c` on 2026-10-30.
- [Fork validation run 41010524374](https://github.com/NYGsatoshi/o3de/actions/runs/41010524374) passed 6/6 Windows jobs: 7-Zip TAR integrity, Unicode names, >330-character paths, SHA-256 and manifest comparisons across independent artifact upload/download runners, failure-induced upload suppression, real production restore/compression step contracts, local harness preflight, and fake-binary state tests.
- The AssetProcessor state matrix **does not execute O3DE's real AssetProcessorBatch.exe**. It only checks the test harness's status reporting and failure handling.
- [Upstream AR run 40870129072](https://github.com/o3de/o3de/actions/runs/40870129072) failed at HEAD `671e439`: Windows-Profile and Mac-Asset hit their 330-minute action limits; Android-Profile failed to install the Android NDK due to an invalid ZIP. Windows-Asset and Android-Asset were skipped. These observations do **not** demonstrate a PR-induced failure, but they prevent a claim that the latest upstream AR is fully green.

## Real AssetProcessorBatch test on Windows

The host must already have a **real, built O3DE** `AssetProcessorBatch.exe` at `<BuildRoot>\bin\profile\AssetProcessorBatch.exe`. Confirm that `EngineSource` is the source checkout from which this binary was built; a matching Git checkout alone does not prove that a pre-existing binary was rebuilt. Running the scripts on the GitHub-hosted test runner without this binary only exercises preflight or the explicit test double.

The recommended full test uses an **isolated synthetic project** in a short, new directory. It never injects assets into an existing project or deletes an existing engine cache.

```powershell
# Download the independent harness, not an untested script from the PR branch.
$script = Join-Path $HOME 'pr20230_asset_processor_recovery.ps1'
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/NYGsatoshi/o3de/test/pr20230-cache-archive-20261025/scripts/build/tests/pr20230_asset_processor_recovery.ps1' -OutFile $script

# Check the actual engine revision before declaring PR-level evidence.
git -C "$HOME\o3de-src" rev-parse HEAD

# Run against a binary that was compiled from the intended PR revision.
& $script `
    -EngineSource "$HOME\o3de-src" `
    -BuildRoot "$HOME\o3de-build" `
    -WorkRoot "$HOME\p30" `
    -ExpectedEngineCommit '671e439' `
    -AssetTimeoutSeconds 5400 `
    -MaxJobs 1 `
    -WarmRun `
    -CompareZeroAnalysisBaseline `
    -KeepCache
$LASTEXITCODE
```

`-ExpectedEngineCommit` is intentionally strict. If the local source is on a different commit, do **not** remove this gate and report the result as validation of `671e439`. Instead, use an accurately identified matching source/binary pair. The limited `-MaxJobs 1` setting is appropriate for memory-constrained Windows machines; `0` leaves AssetProcessor's default unchanged.

The harness records the source commit, AssetProcessor binary SHA-256/mtime, the command-line arguments, exit code and elapsed seconds of each process, product hashes, diagnostics and a machine-readable `evidence/report.json` under a unique directory in `WorkRoot`. Keeping cache is optional; logs and the JSON report are preserved without `-KeepCache`.

## Acceptance rules

| Exit | Status | Interpretation |
| --- | --- | --- |
| `0` | `PASS` | Every **normal-analysis** AssetProcessor run exited 0 and the missing product was restored with matching SHA-256. When the optional zero-analysis comparison is requested, a successful zero-analysis control must also leave the deleted product missing. |
| `1` | `FAIL` | Safety check, initial production, restoration, hash, timeout or another required assertion failed. |
| `2` | `PARTIAL` | The targeted missing product recovered correctly, but one or more normal-analysis AssetProcessor runs exited nonzero. This is **not** a complete AssetProcessor PASS. |
| `3` | `INCONCLUSIVE` | Normal recovery succeeded, but the zero-analysis control did not provide a clean contrast; a baseline execution error or unexpected regeneration cannot be counted as evidence. |

The zero-analysis comparison uses the **same Windows PC platform synthetic project** with the newly regenerated product deleted for a second time. It does not establish Android recovery, and a successful control is not a substitute for a warm-cache performance benchmark. The optional `-MaterialPipelineProbe` requires actual Material Type Builder intermediates; the minimal project's default Gem configuration may not provide them.

## Remaining proof

1. Run real AssetProcessorBatch against an appropriately built PR revision and obtain `PASS`, or preserve the `PARTIAL`/`INCONCLUSIVE` report with logs for diagnosis.
2. Reproduce Android missing-product recovery and compare behavior with and without `--zeroAnalysisMode`.
3. Measure archive timestamp precision effects on real incremental cache hits and cold/warm analysis runtime.
4. Recheck upstream AR results after the unrelated/profile build failures are addressed; do not substitute historical success for current-head success.

**Never promote fork-only simulation successes to actual engine/Android acceptance.**
