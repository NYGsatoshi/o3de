# PR #20230 — Real AssetProcessor integration verification (fork-only)

This branch exists solely to validate [upstream PR #20230](https://github.com/o3de/o3de/pull/20230). The upstream PR and its three production files must remain unchanged.

## Source and provenance

- PR production HEAD: `9282bcc049561a21989063f1e6449cf0ca54d964`.
- Fork branch: `test/pr20230-real-ap-android-windows-20261123` (branched from `test/pr20230-head-verification-20261123`, which itself descends from the production HEAD).
- The workflow must compare the blobs of `.github/workflows/windows-build.yml`, `scripts/build/Platform/Windows/build_config.json`, and `scripts/build/Platform/Android/build_config.json` against the PR HEAD. All must remain identical.
- The native `AssetProcessorBatch` must be compiled **within the same workflow** from this checkout, using the project's Linux-host CMake target `AssetProcessorBatch`. Do not use a fake binary or a binary from a different revision.
- Prior upstream [AR run #45153767993](https://github.com/o3de/o3de/actions/runs/45153767993), Android-Asset/Build, successfully invoked real Linux-host `AssetProcessorBatch --platforms=android` **without** `--zeroAnalysisMode`, scanned 7,360 files, and completed. This is normal Android asset processing; it is not a missing-product recovery/negative-control experiment.

## Tests

1. Run Python syntax and isolated-project preflight on GitHub-hosted Linux. A preflight PASS is **not** real AP evidence.
2. Compile the real O3DE Linux-host `AssetProcessorBatch` with `LY_PROJECTS=AutomatedTesting`, `--config profile`. Log source SHA and binary hash.
3. Create fresh, short-path synthetic projects **outside the checkout**, with one deterministic MP4 CopyAsset fixture and unique isolated cache per test.
4. Android target: run cold/warm real AP scans, perturb the isolated cached product's subsecond mtime and compare another real AP scan, delete the product and verify real normal-analysis regeneration and SHA-256, delete it again and run `--zeroAnalysisMode` as the controlled negative case.
5. Repeat a **Linux-host pc-platform** smoke/contrast. This does not replace a Windows-native AssetProcessorBatch run.
6. Publish only structured reports and text logs as artifacts (no huge caches, copied source, build trees or third-party binaries).

## Acceptance interpretation

The Python script uses four explicit outcomes, recorded under a unique `/tmp/p30/r*/<platform>/logs/report.json`:

| Exit | Status | Interpretation |
| --- | --- | --- |
| 0 | PASS | All real normal-analysis AP runs exit 0; deleted product restored with matching SHA-256; a successful zero-analysis control leaves it absent |
| 1 | FAIL | Preflight, build, product integrity, fault injection or runtime assertion fails |
| 2 | PARTIAL | Product did recover but one or more full normal-analysis AP runs returned nonzero |
| 3 | INCONCLUSIVE | Real normal recovery succeeded but the zero-analysis control failed or did not distinguish |

**Limitations:**

- The minimal MP4 copy-job fixture is narrower than the original Material Type Builder / `.azsl` failure. Do not claim a material-pipeline recovery result from it.
- A single cache-product mtime-only probe is **not** a real TAR restore and does not establish whole-project cache invalidation/performance. Record measured times and job-line counts, but do not assume a causal speed regression from them.
- This workflow does not compile Windows-native AssetProcessorBatch.exe; the Windows-specific full exit-0 checkbox remains open until native Windows AP is tested.
- Real AP build can fail due to GitHub-hosted runner disk/memory, package server or unrelated shader compilation. Preserve failure logs and clearly distinguish those from AP correctness.
- Only update upstream PR checkboxes after independently verifying real evidence; simulation and CI queueing are not substitutes.

## Related evidence

- [Previous fork verification #45155595258](https://github.com/NYGsatoshi/o3de/actions/runs/45155595258): 5/5 green for archive fidelity, 20,021 paths/SHA-256 and a **simulated** AP harness.
- [This branch's integration workflow](../../../.github/workflows/pr20230-real-ap-integration.yml).
