# PR #20230 — native Windows real AssetProcessorBatch acceptance (fork-only)

The branch `test/pr20230-real-windows-native-20261123` descends from the upstream PR HEAD `9282bcc049561a21989063f1e6449cf0ca54d964` via the isolated archive-verification branch. The original upstream PR and all three production files are left unchanged.

## Plan and scope

- Verify that the Windows GitHub workflow and both platform `build_config.json` Git blob IDs match upstream PR HEAD.
- Use the upstream Windows 2022 DevDrive/MSVC toolchain; compile the **real** O3DE `AssetProcessorBatch.exe` in the same GitHub Actions job from the test-branch checkout. No fake executable may stand in for the target binary.
- Execute `scripts/build/tests/pr20230_asset_processor_recovery.ps1` with a unique synthetic project in a short directory on the DevDrive.
- Request `-WarmRun`, `-TimestampTruncationProbe`, and `-CompareZeroAnalysisBaseline` (cold, warm, real mtime perturbation, missing-product recovery, zero-analysis negative control). Preserve logs, product hashes and machine-readable JSON.
- Respect harness status: `PASS` full batch exit=0 and negative control distinguishes; `PARTIAL` target restored but unrelated batch errors; `INCONCLUSIVE` failed negative-control contrast; `FAIL` other errors. Never mark full native AP validation complete based only on MP4 restoration.
- This test exercises Windows-native AP on PC (not Android). The separate [Android real AP workflow](https://github.com/NYGsatoshi/o3de/blob/test/pr20230-real-ap-android-windows-20261123/.github/workflows/pr20230-real-ap-integration.yml) covers the Android target using a real Linux-host AP.

## Constraints

- A source checkout SHA matching the test branch is necessary, but not by itself proof of a rebuilt binary: the native compilation step must finish before the harness runs and the binary's SHA-256 must be recorded.
- This is a resource-intensive Visual Studio build; compiler/SDK/package failures and CI timeouts should be classified separately from AP behavior.
- The timestamp probe changes only an isolated cache product; it does not perform a full TAR restore or prove production-wide performance.
- The minimal synthetic project covers a copy-job MP4; original Material Type Builder intermediate `.azsl` recovery remains a separate, more specific possible extension.
- The three production files and original PR are never edited by this branch.

Workflow: [Real Windows Native AP Acceptance](../../../.github/workflows/pr20230-real-windows-ap.yml).
