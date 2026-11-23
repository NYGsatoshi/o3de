#!/usr/bin/env python3
# Copyright (c) Contributors to the Open 3D Engine Project.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Fork-only REAL O3DE AssetProcessorBatch recovery probe for PR #20230.

Not a mock: requires a locally built Linux AssetProcessorBatch produced from
the pinned PR production code. Uses only unique short-path synthetic projects.
A zero-analysis contrast that regenerates the missing product is INCONCLUSIVE,
not success. The mtime-only probe does not replicate actual TAR restoration.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

BASE_SHA = "9282bcc049561a21989063f1e6449cf0ca54d964"
PRODUCTION = (
    ".github/workflows/windows-build.yml",
    "scripts/build/Platform/Windows/build_config.json",
    "scripts/build/Platform/Android/build_config.json",
)

def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as fd:
        for b in iter(lambda: fd.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args],
                                   text=True, stderr=subprocess.STDOUT).strip()

def verify_provenance(engine):
    head = git(engine, "rev-parse", "HEAD")
    git(engine, "cat-file", "-e", BASE_SHA + "^{commit}")
    subprocess.run(["git", "-C", str(engine), "merge-base",
                    "--is-ancestor", BASE_SHA, "HEAD"], check=True)
    blobs = {}
    for f in PRODUCTION:
        old = git(engine, "rev-parse", BASE_SHA + ":" + f)
        cur = git(engine, "rev-parse", "HEAD:" + f)
        if old != cur:
            raise RuntimeError("Production code modified relative to PR HEAD: " + f)
        blobs[f] = cur
    return head, blobs

def scan_counters(logfile):
    data = logfile.read_text(encoding="utf-8", errors="replace")
    m = re.findall(r"Assessing files from scanner complete\. Total files:\s*(\d+).*?"
                   r"Old timestamps:\s*(\d+).*?Modified dependencies:\s*(\d+)", data)
    return {
        "scanned_files": int(m[-1][0]) if m else None,
        "old_timestamps": int(m[-1][1]) if m else None,
        "modified_dependencies": int(m[-1][2]) if m else None,
        "processing_log_lines": len(re.findall(r"AssetProcessor:\s+Processing\s+", data)),
        "batch_complete_marker": "Asset Processor Batch Processing complete" in data,
    }

def invoke(label, binary, args, logs, seconds):
    dest = logs / (label + ".log")
    start = time.monotonic()
    rc = None
    timed_out = False
    with dest.open("wb") as out:
        try:
            result = subprocess.run([str(binary), *args], stdout=out, stderr=subprocess.STDOUT,
                                    timeout=seconds, cwd=str(binary.parent), check=False)
            rc = result.returncode
        except subprocess.TimeoutExpired:
            rc = 124
            timed_out = True
    elapsed = round(time.monotonic() - start, 3)
    result = {"name": label, "exit_code": rc, "timed_out": timed_out,
              "elapsed_seconds": elapsed, "log": str(dest),
              "scan": scan_counters(dest)}
    print(f"[REAL AP] {label}: exit={rc}, elapsed={elapsed}s, "
          f"processing-log-lines={result['scan']['processing_log_lines']}", flush=True)
    return result

def run():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--engine-source", type=Path, required=True)
    p.add_argument("--build-root", type=Path, required=True)
    p.add_argument("--work-root", type=Path, default=Path("/tmp/p30"))
    p.add_argument("--platform", choices=("android", "pc"), required=True)
    p.add_argument("--timeout-seconds", type=int, default=1200)
    p.add_argument("--max-jobs", type=int, default=2)
    p.add_argument("--preflight-only", action="store_true")
    args = p.parse_args()
    if args.timeout_seconds < 1 or args.max_jobs < 1 or args.max_jobs > 8:
        p.error("timeout-seconds and max-jobs must be positive, max-jobs <= 8")
    engine = args.engine_source.resolve(strict=True)
    build = args.build_root.resolve(strict=True)
    work = args.work_root.resolve(strict=False)
    if not (engine / "engine.json").is_file():
        raise RuntimeError("This source does not contain O3DE engine.json")
    if work == engine or work == build or engine in work.parents or build in work.parents:
        raise RuntimeError("Work root cannot overlap engine or build directory")
    if len(str(work)) > 45:
        raise RuntimeError("Use a short work-root path to avoid long asset names")
    head, blobs = verify_provenance(engine)
    case = work / ("r" + uuid.uuid4().hex[:7]) / args.platform
    if case.exists():
        raise RuntimeError("Refusing to reuse a preexisting test case")
    case.mkdir(parents=True)
    project, cache, user, logs = (case / k for k in ("p", "c", "u", "logs"))
    for root in (project / "Assets", project / "Registry", cache, user, logs):
        root.mkdir(parents=True, exist_ok=True)
    spec = {
        "project_name": "Pr20230AndroidProbe" if args.platform == "android" else "Pr20230PcProbe",
        "display_name": "PR20230 real AP isolated probe",
        "project_id": "{" + str(uuid.uuid4()) + "}",
        "version": "1.0.0",
        "engine": "o3de",
        "gem_names": [],
        "external_subdirectories": [],
    }
    (project / "project.json").write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")
    asset = project / "Assets" / "pr20230_cache_probe.mp4"
    asset.write_bytes(b"PR20230 actual O3DE Android cache-recovery integration fixture\n")
    reference = sha256(asset)
    product = cache / args.platform / "assets" / asset.name
    binary = build / "bin" / "profile" / "AssetProcessorBatch"
    report = {
        "test": "PR20230 real O3DE AssetProcessorBatch Linux host",
        "status": "NOT_STARTED",
        "platform": args.platform, "source_revision": head, "production_base": BASE_SHA,
        "production_blobs": blobs, "engine_source": str(engine),
        "binary": str(binary), "binary_sha256": None, "work_case": str(case),
        "source_sha256": reference, "product": str(product), "runs": [],
        "normal_recovery_sha256_matches": False, "zero_analysis_contrast": None,
        "timestamp_isolated_probe": None, "error": None,
        "limits": ["single synthetic CopyAsset fixture only",
                   "mtime change is not real 7-Zip TAR restore",
                   "one warm/mtime pair is not a statistically valid performance benchmark"],
    }
    location = logs / "report.json"
    try:
        print(f"Verified PR source ancestor={BASE_SHA}, checkout={head}", flush=True)
        if args.preflight_only:
            report["status"] = "PREFLIGHT_PASS"
            return 0
        if not binary.is_file():
            raise RuntimeError("Real Linux AssetProcessorBatch not found: " + str(binary))
        report["binary_sha256"] = sha256(binary)
        opts = [
            "--project-path=" + str(project),
            "--engine-path=" + str(engine),
            "--project-cache-path=" + str(cache),
            "--project-user-path=" + str(user),
            "--project-log-path=" + str(logs),
            "--platforms=" + args.platform,
            "--ignoreFutureAssetDatabaseVersionError",
            '--regset="/Amazon/AssetProcessor/Settings/Jobs/maxJobs='
                + str(args.max_jobs) + '"',
        ]
        report["normal_args"] = opts
        report["baseline_args"] = [*opts, "--zeroAnalysisMode"]
        normal_rc = []
        def normal(label):
            item = invoke(label, binary, opts, logs, args.timeout_seconds)
            report["runs"].append(item)
            normal_rc.append(item["exit_code"])
            if item["timed_out"]:
                raise RuntimeError("Real AP timed out during " + label)
            return item
        normal("cold")
        if not product.is_file():
            raise RuntimeError("Cold pass did not create the expected real product: " + str(product))
        if sha256(product) != reference:
            raise RuntimeError("Cold pass produced mismatching SHA-256")
        normal("warm")
        if not product.is_file() or sha256(product) != reference:
            raise RuntimeError("Warm pass did not retain correct product")
        # Controlled metadata-only probe. Change only this unique test cache's
        # single MP4 product; never touch source or shared project caches.
        seeded_ns = (time.time_ns() // 1_000_000_000) * 1_000_000_000 + 987_654_321
        os.utime(product, ns=(seeded_ns, seeded_ns))
        normal("mtime-control")
        if not product.is_file() or sha256(product) != reference:
            raise RuntimeError("Product failed metadata-only control scan")
        before_ns = product.stat().st_mtime_ns
        truncated_ns = before_ns // 1_000_000_000 * 1_000_000_000
        os.utime(product, ns=(truncated_ns, truncated_ns))
        mtime_result = normal("mtime-truncated")
        if not product.is_file() or sha256(product) != reference:
            raise RuntimeError("Cache product missing/changed after timestamp truncation")
        control = report["runs"][-2]
        report["timestamp_isolated_probe"] = {
            "method": "mtime-only single isolated product, no TAR round trip",
            "mtime_loss_seconds": (before_ns - truncated_ns) / 1_000_000_000,
            "warm_seconds": control["elapsed_seconds"],
            "truncated_seconds": mtime_result["elapsed_seconds"],
            "warm_processing_log_lines": control["scan"]["processing_log_lines"],
            "truncated_processing_log_lines": mtime_result["scan"]["processing_log_lines"],
            "interpretation": "Observational; cannot establish production cache hit or rebuild regression",
        }
        product.unlink()
        if product.exists():
            raise RuntimeError("Could not inject the normal-analysis missing-product fault")
        normal("missing-product-recovery")
        report["normal_recovery_sha256_matches"] = product.is_file() and sha256(product) == reference
        if not report["normal_recovery_sha256_matches"]:
            raise RuntimeError("Normal AP did not restore deleted product with correct SHA-256")
        product.unlink()
        baseline = invoke("zero-analysis-control", binary, [*opts, "--zeroAnalysisMode"], logs, args.timeout_seconds)
        report["runs"].append(baseline)
        if baseline["timed_out"]:
            raise RuntimeError("ZeroAnalysisMode control timed out")
        remains = product.is_file()
        report["zero_analysis_contrast"] = {
            "exit_code": baseline["exit_code"], "product_regenerated": remains,
            "regenerated_sha256_matches": sha256(product) == reference if remains else None,
            "contrasts_with_normal": baseline["exit_code"] == 0 and not remains,
        }
        if any(rc != 0 for rc in normal_rc):
            report["status"] = "PARTIAL"
            return 2
        if not report["zero_analysis_contrast"]["contrasts_with_normal"]:
            report["status"] = "INCONCLUSIVE"
            return 3
        report["status"] = "PASS"
        return 0
    except Exception as exc:
        report["status"] = "FAIL"
        report["error"] = f"{type(exc).__name__}: {exc}"
        print("[REAL AP] " + report["error"], file=sys.stderr, flush=True)
        return 1
    finally:
        location.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                            encoding="utf-8")
        print("Saved actual O3DE AP test report: " + str(location), flush=True)

if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as exc:
        print("PRECHECK FAILED: " + repr(exc), file=sys.stderr)
        sys.exit(1)
