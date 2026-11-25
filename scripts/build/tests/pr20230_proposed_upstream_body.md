## What does this PR do?

Fixes #19773.

### Problem

The Windows artifact caching workflow previously used Windows `tar.exe` (libarchive) to create cache archives. Due to an NTFS file-index collision issue ([libarchive#1630](https://github.com/libarchive/libarchive/issues/1630)), input files may be silently omitted even when `tar.exe` exits with code 0.

An incomplete artifact can then be uploaded and restored by subsequent builds, causing missing cached files and downstream AssetProcessor failures.

Additionally, `--zeroAnalysisMode` prevents AssetProcessor from performing the analysis needed to identify and regenerate certain missing cached products.

### Changes

**1. Replace Windows TAR compression and extraction with 7-Zip**

File: `.github/workflows/windows-build.yml`

- Replace the Windows `tar.exe` writer and extractor with 7-Zip.
- Verify that `7z.exe` is available on the runner.
- Check the compression and extraction exit codes.
- Require the generated archive to exist and be nonempty.
- Remove `continue-on-error: true` from compression.
- Preserve the existing artifact-upload condition, which requires successful compression.
- On extraction failure, remove restored cache directories before attempting a clean-cache fallback.
- Preserve the archive name, input directories and artifact configuration.

The 7-Zip dependency applies only to GitHub Actions Windows runners. It does not introduce a general requirement for local O3DE development.

**2. Restore AssetProcessor cache analysis**

Files:

- `scripts/build/Platform/Windows/build_config.json`
- `scripts/build/Platform/Android/build_config.json`

Remove `--zeroAnalysisMode` from the `asset_profile` AssetProcessor options while preserving the remaining configuration.

This enables normal analysis of restored caches and allows missing products to be detected and regenerated.

### How was this PR tested?

**Completed: static verification**

- [x] Confirmed the changes were originally based on upstream `development` at `2462b90ee389939336931a14e234fc4e3b4cd534`.
- [x] Confirmed that the PR changes only the three intended files.
- [x] Validated both modified `build_config.json` files.
- [x] Confirmed removal of `--zeroAnalysisMode` from both affected configurations.
- [x] Verified the Windows workflow's 7-Zip availability, exit-code, archive-existence and nonempty-archive checks.
- [x] Verified that artifact upload remains conditional on successful compression.

**Completed: CI and local runtime validation**

- [x] [Validation workflow](https://github.com/o3de/o3de/actions/runs/40142529150) — SUCCESS.
- [x] [AR workflow #3441](https://github.com/o3de/o3de/actions/runs/40142529337) — SUCCESS on commit `36b5bb5df00028cf3454b14d2e22678dda42cc7d`.
- [x] Windows Profile, Release, Asset and Test jobs completed successfully.
- [x] Verified successful 7-Zip extraction in Windows CI logs (`Everything is Ok`).
- [x] Verified archive creation and successful artifact upload steps. The Windows Asset job compressed 45,618 files into an approximately 14 GiB TAR archive.
- [x] Verified a local 7-Zip TAR round trip containing 10,016 test files, including Unicode filenames, with matching file paths and SHA-256 hashes.
- [x] Verified a local archive round trip with a path exceeding 330 characters.
- [x] Verified local compatibility with a legacy POSIX TAR archive.
- [x] Verified local detection of a corrupted TAR and cleanup of partial isolated cache directories.
- [x] Verified local Windows AssetProcessor recovery after deliberately deleting `pr20230_cache_probe.mp4`: the missing product was detected, regenerated and verified against the original SHA-256.

**Additional CI evidence (isolated fork verification branch)**

- [x] [Fork verification run #41033257437](https://github.com/NYGsatoshi/o3de/actions/runs/41033257437) — **SUCCESS (6/6 jobs)** at `50bac95`. Tests include production compression/extraction contracts, expected upload suppression on 7-Zip failure, corrupted TAR cache cleanup, Unicode and long paths, file count/SHA-256 verification after independent Artifact transport, and isolated harness preflight.
- [x] The three production files in the **earlier** fork verification branch were byte-identical to the **previous** PR HEAD `671e439e986dd8a75a89578ca27f50ce04a9d36c`. Later revisions are documented below.
- [x] Simulated AssetProcessor harness state matrix (12 scenarios, including `--zeroAnalysisMode` baseline, PARTIAL, INCONCLUSIVE, timeout, revision mismatch) passed. **This does not execute O3DE's actual AssetProcessorBatch.exe**.

**Independent fork CI evidence (November 23, 2026; PR HEAD `9282bcc049561a21989063f1e6449cf0ca54d964`)**

- [x] Created the [isolated fork verification branch](https://github.com/NYGsatoshi/o3de/tree/test/pr20230-head-verification-20261123) from this exact PR HEAD, without modifying any of the three production files. The [workflow](https://github.com/NYGsatoshi/o3de/blob/test/pr20230-head-verification-20261123/.github/workflows/pr20230-head-verification.yml) and [validation notes](https://github.com/NYGsatoshi/o3de/blob/test/pr20230-head-verification-20261123/scripts/build/tests/PR20230_HEAD_VALIDATION.md) are fork-only.
- [x] [Fork CI run #45155595258](https://github.com/NYGsatoshi/o3de/actions/runs/45155595258) — **SUCCESS (5/5 jobs)** at verification commit `53734ba644d395194ad54f0c0a08727fcae47ce9`.
- [x] Git blob SHA identity of the Windows CI workflow and both Windows/Android `build_config.json` files with the November 23 upstream PR HEAD was confirmed. The `asset_profile` settings, platform targets, and absence of `--zeroAnalysisMode` were validated.
- [x] Windows 7-Zip TAR producer round trip preserved **20,021 files** (20,000 generated files plus 21 Unicode, long-path, and timestamp fixtures) with identical relative paths and SHA-256 content hashes, including a path longer than 330 characters.
- [x] A separate GitHub-hosted Windows runner downloaded the TAR and an independent pre-archive source manifest via GitHub Actions Artifacts; all **20,021 paths and SHA-256 hashes**, as well as all four production cache roots, survived restoration.
- [x] Exercised the actual Windows CI compression/extraction PowerShell step bodies on isolated valid, corrupt, and blocked TAR fixtures. Verified valid cache retention, corrupt TAR detection and cleanup of all four cache roots, nonzero compression failure, and the upload guard.
- [x] The recovery harness passed **16 simulated state-machine cases** with a compiled **fake** AssetProcessor executable and uploaded 16 JSON reports. **This is not evidence that real O3DE AssetProcessorBatch or Android processing succeeded.**

**Timestamp metadata observation:** The 7-Zip TAR again reduced subsecond mtimes by `0.1234567`, `0.4567890`, `0.7890123`, and `0.9876543` seconds across the four production cache roots, whereas the tested legacy POSIX-TAR fixture preserved the fractional timestamp (`0.0000000` seconds loss). These measurements demonstrate a precision difference, **not** a proven cache-hit or incremental processing performance regression.

**Artifacts from the 5/5 successful fork run:** `PR20230-HEAD-20K-ARCHIVE` (TAR/source manifest) and `PR20230-HEAD-SIMULATED-AP-REPORTS` (16 fake-AP reports). See the November 25 native Windows results and remaining checks below.

- [x] Obtain a full, successful real native Windows AssetProcessorBatch run on the current PR revision in an isolated short-path project and verify the baseline with and without `--zeroAnalysisMode` (November 25; evidence below).

**Pending validation**

- [x] Verified through GitHub-hosted Windows CI failure injection that compression failures prevent artifact uploads (the actual production compression code and upload condition were exercised on isolated fixtures).
- [x] Verified a long-path and file-integrity round-trip on GitHub-hosted Windows runners: Unicode and >330-character paths, source/file counts and SHA-256, including independent-runner GitHub Artifact transport.
- [x] Compare actual 7-Zip TAR restoration with timestamp-preserving restoration using a controlled native Windows AssetProcessor workload. No additional processing was observed in four pairs (one CopyAsset product, three cache files).
- [ ] Quantify the impact of timestamp precision and normal analysis on a representative larger workload if required for a general performance-regression claim.
- [x] Verify missing-product recovery on Android and compare behavior against a controlled baseline using `--zeroAnalysisMode` (November 25; Linux-hosted real AP, both Android and PC targets).

### Test limitations

The isolated local Windows AssetProcessorBatch runs returned exit code 1 because other asset-processing jobs failed.

Observed errors included:

- Generated paths exceeding the Windows 260-character limit due to the deeply nested temporary test directory.
- Shader compilation and preprocessing errors.
- Log-file write warnings.

However, the targeted MP4 recovery test succeeded independently:

1. Removed the previously generated cache product.
2. Confirmed AssetProcessor detected the missing product.
3. Confirmed the product was reprocessed and regenerated.
4. Verified the regenerated product's SHA-256 matched the source.

This demonstrates successful recovery of the targeted missing product, but **does not establish that the entire local AssetProcessor batch completed successfully**.

The Windows CI Asset job did complete successfully.

**Real AssetProcessor results on the November 23 revision (`9282bcc`)**

The [Linux-hosted fork run](https://github.com/NYGsatoshi/o3de/actions/runs/45162604424/job/137651681275) compiled AssetProcessorBatch and ran it against both `android` and `pc` products. In each case normal analysis regenerated the deleted MP4 with the original SHA-256. With `--zeroAnalysisMode` the file stayed missing. Both modes exited 1, so the two reports are **PARTIAL**. The cold runs each recorded 685 failed jobs outside the fixture, including assets still present as Git LFS pointers. The [reports and logs](https://github.com/NYGsatoshi/o3de/actions/runs/45162604424/artifacts/14826138236) were uploaded despite a broken pipe in the final file listing.

The single-product mtime probe recorded 741 processing log lines on each side for both targets. Android took 11.293 s before truncation and 11.244 s after. Linux-hosted `pc` took 11.643 s and 11.895 s. Each pair comes from one run per condition and the probe changed one product's mtime directly. The November 25 controlled TAR restoration is reported below.

The [native Windows fork job](https://github.com/NYGsatoshi/o3de/actions/runs/45163774257/job/137655422695) configured MSVC, then reached its 180-minute build-step timeout. The AssetProcessor test step was skipped.

**Upstream CI by revision**

- November 23, `9282bcc`: [Validation](https://github.com/o3de/o3de/actions/runs/45153768060) passed. [AR attempt 2](https://github.com/o3de/o3de/actions/runs/45153767993/attempts/2) passed with 14 successful jobs and two skipped tests (macOS and iOS).
- The [November 23 Windows Asset job](https://github.com/o3de/o3de/actions/runs/45153767993/job/138025614913) extracted 46,865 files from the 7-Zip TAR and ran AssetProcessor on `AutomatedTesting` for `pc,server`. The scanner assessed 7,373 files and counted zero old timestamps and zero modified dependencies. The batch processed 924 assets successfully, recorded zero failed assets, and took 277.776 s. This is a single production observation without a paired precision-preserving restore.
- November 25, `e6e62c0bbc14466b7bb54b5c485a25a347f2d4c3`: [Validation](https://github.com/o3de/o3de/actions/runs/45589895613) passed. [AR attempt 1](https://github.com/o3de/o3de/actions/runs/45589895681/attempts/1) ended with 13 successful jobs, 1 failed job and 2 skipped tests (macOS/iOS). The Windows-Test job failed in `Build test_cpu_profile`: `UdpTransportTests.FragmentTimeoutReleasesHighSequenceBeforeReuse` at `UdpTransportTests.cpp:160` returned dispatch result 0 instead of expected 2 (Success); 136/137 CTest entries passed. [Failure log](https://github.com/o3de/o3de/actions/runs/45589895681/job/139150621780). The PR changes no AzNetworking source or test files; causation has not been established. A failed-job rerun is needed; the GitHub integration was denied permission (403). [Previous Windows-Test run](https://github.com/o3de/o3de/actions/runs/45153767993/job/138025616397) on the November 23 revision passed 137/137 CTest entries.
- November 25 [Windows-Asset](https://github.com/o3de/o3de/actions/runs/45589895681/job/139135293566) passed. 7-Zip extracted 47,244 files; AssetProcessor assessed 7,373 files, reported zero old timestamps and zero modified dependencies, processed 929 assets successfully, failed 0, reported 177 warnings and 8 errors, and took 281.709991 s (AutomatedTesting, pc/server). This is a production observation, not a paired comparison.
- November 25 [Android-Asset](https://github.com/o3de/o3de/actions/runs/45589895681/job/139129982872) passed. It assessed 7,360 files, processed 473 assets successfully, failed 0, reported 89 warnings and 4 errors, and took 68.819 s. This is ordinary asset processing, not deliberate product deletion/recovery.
- [Linux-hosted Android/PC recovery](https://github.com/NYGsatoshi/o3de/actions/runs/45591465673) passed for both targets; detailed results below.

**November 25 native Windows controlled recovery and TAR comparison (exact PR HEAD `e6e62c0bbc14466b7bb54b5c485a25a347f2d4c3`)**

[Run #45591666674](https://github.com/NYGsatoshi/o3de/actions/runs/45591666674) — SUCCESS, verification commit `447c64b8939d617f4b17bcc7d7dbefbed2d4568d`. Downloaded and inspected the actual [report.json and 20 AP logs](https://github.com/NYGsatoshi/o3de/actions/runs/45591666674/artifacts/15019073289). The archive SHA-256 matches the upload log (`b8f34c075617bde235dcf29760873e181a634c3683cb14825b3fdb0735190e8f`). The report identifies the exact engine checkout and native binary SHA-256 `974e516bfbf07050fb8a6fbc7a9c363198536c3eb90987869d1f73aaf2dceafd`.

- All 20 real AP invocations exited 0, with zero failed assets, zero reported errors and complete batch markers.
- Cold run processed 1 asset; warm run processed 0. After restoring the same closed database/cache snapshot and deleting the product, normal analysis detected the missing product and processed 1 asset. The original and regenerated product SHA-256 both equal `5e653425a26ecc30a307510e528c810f1313405ee81809fa03240976357e2693`. The same deletion with `--zeroAnalysisMode` processed 0 assets and left the product absent.
- Four alternating intact-cache trials per mode: normal median 0.552058 s; zero-analysis median 0.547894 s; difference +0.004164 s. One CopyAsset product, same paths and snapshot.
- Four alternating timestamp-preserving vs real 7-Zip TAR restore pairs: all 3 cache files matched path/content; all 3 TAR files lost fractional timestamps, maximum loss 0.9876543 s. Both arms processed 0 assets in all four pairs, and the product hash matched in each run. Additional processed assets per pair: [0, 0, 0, 0].
- AP-only median times: precision-preserving control 0.6050655 s; TAR 0.5474695 s; median of paired TAR-minus-control differences -0.0076205 s. The timing excludes archive preparation and extraction. These results establish no extra processing in this isolated workload; they do not establish a performance improvement or a general large-project guarantee.

**November 25 Linux-hosted Android and PC controlled recovery (PR HEAD `e6e62c0bbc14466b7bb54b5c485a25a347f2d4c3`)**

[Run #45591465673](https://github.com/NYGsatoshi/o3de/actions/runs/45591465673) — SUCCESS, verification commit `c9157b1f264cdce469555fc572e9e95e03ceb2bb`. The workflow passed the engine revision/diff and syntax checks. Downloaded the [actual reports and AP logs](https://github.com/NYGsatoshi/o3de/actions/runs/45591465673/artifacts/15023404644). ZIP SHA-256 `7420c4031e455f3fbee6be805bc9c33e7cc6a05b43b519a905a931acccd17ace` matches the upload log; ZIP CRC validation passed. The recorded binary SHA-256 is `cba4b0b394e14025bd41d4619a74d6d2215b0890921e60ec07c71bf844a66773`. The revision manifest records both the verification commit and exact PR HEAD.

- Android and PC each passed 12 actual AssetProcessorBatch invocations (24 total), all exit 0, zero failed assets, zero reported errors and complete batch markers. All counters in the JSON reports were independently cross-checked against the 24 AP stdout logs.
- Each target processed 1 asset cold and 0 warm. Starting with the same closed cache/database snapshot and deleting the product, normal analysis detected and regenerated 1 product; the original and regenerated SHA-256 both equal `5e653425a26ecc30a307510e528c810f1313405ee81809fa03240976357e2693`. The zero-analysis arm processed 0 assets and left the deleted product absent for both targets.
- Four alternating intact-cache trials per mode per target: Android normal median 0.540156 s vs zero 0.5401915 s; PC normal median 0.565323 s vs zero 0.5654225 s. Both modes processed 0 assets throughout. The tiny median differences are not evidence of a performance improvement.
- Scope: one isolated CopyAsset product per target using the real Linux-hosted AP with Android and PC target flags; this is not an Android-device runtime test or a representative large-project benchmark.

Together with native Windows, all 44 controlled real AP invocations completed successfully. The upstream AR remains a separate required gate.

- [x] Current HEAD Validation passed.
- [ ] Current HEAD full AR passed (attempt 1 failed; rerun pending).

**Historical upstream CI status (previous PR HEAD `671e439`, October 29, 2026)**

[Validation run #40870129181](https://github.com/o3de/o3de/actions/runs/40870129181) passed. However, [AR run #40870129072](https://github.com/o3de/o3de/actions/runs/40870129072) **failed**: Windows-Profile and Mac-Asset exceeded the 330-minute build timeout; Android-Profile failed to install NDK `27.3.13750724` (downloaded archive reported as not a ZIP). Consequently Windows-Asset and Android-Asset were skipped. The failures have not been established to be caused by this PR. The previous fully successful AR #3441 cited above belongs to the earlier commit `36b5bb5`, not the current HEAD.

**Measured metadata difference (GitHub-hosted Windows runner)**

[Fork Windows CI #41053475713](https://github.com/NYGsatoshi/o3de/actions/runs/41053475713) verified 1,045 paths/SHA-256 hashes after separate-runner Artifact transport. On four timestamp fixtures across the four production cache directories, 7-Zip TAR lost respectively `0.1234567`, `0.4567890`, `0.7890123`, and `0.9876543` seconds; the independent restorer observed the same losses. Legacy POSIX TAR preserved the first fixture at `0.0000000` seconds loss. **This is a metadata precision measurement, not evidence of AssetProcessor cache invalidation or performance regression.** See the [fork verification procedure and evidence](https://github.com/NYGsatoshi/o3de/blob/test/pr20230-cache-archive-20261025/scripts/build/tests/PR20230_VALIDATION.md).

### Remaining considerations

**Archive completeness**

The current workflow detects 7-Zip failures and rejects missing or empty archives. It does not yet perform a complete comparison between the source file manifest and archived file contents.

Additional manifest or hash verification would provide stronger protection against silent file omission beyond the identified libarchive issue.

**Timestamp compatibility**

7-Zip TAR truncates fractional timestamps in the tested fixtures. The November 25 controlled Windows comparison found no extra processing for one CopyAsset product and three cache files; representative large-project impact is not established.

**AssetProcessor performance**

Removing `--zeroAnalysisMode` may increase analysis time. The controlled one-product comparison measured +0.004164 s in median intact-cache AP time; larger workload performance is not established.

### References

- Fixes #19773
- [[libarchive/libarchive#1630](https://github.com/libarchive/libarchive/issues/1630)](https://github.com/libarchive/libarchive/issues/1630)
- [Successful AR #3441](https://github.com/o3de/o3de/actions/runs/40142529337)