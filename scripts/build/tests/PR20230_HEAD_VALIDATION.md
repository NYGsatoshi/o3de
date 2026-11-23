# PR #20230 — current HEAD independent verification (2026-11-23)

This directory of tests is **fork-only** and must not be merged into the three-file upstream PR.

## Provenance and isolation

- Upstream PR: https://github.com/o3de/o3de/pull/20230
- PR source HEAD at branch creation: `9282bcc049561a21989063f1e6449cf0ca54d964`
- Isolated fork branch: `test/pr20230-head-verification-20261123`, created from that exact commit.
- Original independently validated harness: `test/pr20230-cache-archive-20261025` at `44fcb422addc73c5401d82ba1a577d3a56563c04`.
- Six test/harness files were copied from that specific commit without editing their contents. Production source files and upstream PR are unchanged.

The workflow checks that the three modified production files (`.github/workflows/windows-build.yml`, `scripts/build/Platform/Windows/build_config.json`, `scripts/build/Platform/Android/build_config.json`) have exactly the same Git blob hashes as the pinned upstream PR HEAD. It fails closed if the pinned commit is no longer an ancestor or these files differ. This is necessary because this branch contains additional test-only commits.

## Fork Actions verification

Workflow: [PR20230 Current HEAD Independent Verification](../../../.github/workflows/pr20230-head-verification.yml)

- **Provenance/config**: same production file contents, parse Windows/Android JSON, no `--zeroAnalysisMode` in `asset_profile`, unchanged platform selection.
- **20,000-file archive**: run the existing tested Windows 7-Zip archive harness against all four production cache roots, Unicode filenames, >330-character path, manifest SHA-256, plus TAR mtime fixture matrix.
- **Cross-runner artifact transport**: upload the real archive and manifest, download on an independent Windows runner, re-extract and verify all paths, checksums and timestamps.
- **Production PowerShell steps**: execute extraction and compression blocks extracted from the current `windows-build.yml`, verify valid TAR, corruption cleanup, blocked archive write handling and upload guard.
- **AssetProcessor harness**: PowerShell parser/preflight and 16 fake-AssetProcessor state tests, including timestamp perturbation, zero-analysis negative control, PARTIAL/INCONCLUSIVE, timeout and material cache scenarios. The binary here is **a test double, not real O3DE**.

## What success does and does not mean

Passing this workflow strengthens evidence for archive transport integrity and for the integrity of the test harness on the **latest production diff**. It does **not** close the three remaining upstream PR checkboxes:

1. A complete real O3DE `AssetProcessorBatch` PASS and an actual baseline A/B test on a binary built from the intended revision.
2. Empirical performance / cache-hit comparison with real AP before and after TAR's subsecond timestamp truncation.
3. Real Android-target AssetProcessor recovery with and without `--zeroAnalysisMode`.

The accompanying `pr20230_asset_processor_recovery.ps1` supports real Windows AP tests if a matching compiled `AssetProcessorBatch.exe` is available. Do not report the 16-case simulated state suite as real AP/Android acceptance.

## Outcomes

Record the workflow run URL, commit SHA and per-job results after the run. Do not mark any PR checkbox complete just because a workflow was scheduled or a test script has been copied.
