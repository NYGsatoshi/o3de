#!/usr/bin/env python3
# Copyright (c) Contributors to the Open 3D Engine Project.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Exercise the PR's AssetProcessor options against an isolated real CopyAsset product."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid


def digest(path):
    with path.open("rb") as stream:
        h = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def native_summary(text):
    def counter(name):
        matches = re.findall(r"^AssetProcessor:\s+" + name + r":\s*(\d+)\.", text, re.M)
        return int(matches[-1]) if matches else None

    return {
        "processed_assets": counter("Number of Assets Successfully Processed"),
        "failed_assets": counter("Number of Assets Failed to Process"),
        "reported_errors": counter("Number of Errors Reported"),
        "batch_complete": "Asset Processor Batch Processing complete" in text,
    }


def execute(args, output, report):
    engine = args.engine_source.resolve(strict=True)
    build = args.build_root.resolve(strict=True)
    exe = "AssetProcessorBatch.exe" if os.name == "nt" else "AssetProcessorBatch"
    binary = (args.binary or build / "bin" / "profile" / exe).resolve(strict=True)
    target = "Android" if args.platform == "android" else "Windows"
    config = engine / "scripts" / "build" / "Platform" / target / "build_config.json"
    profile = json.loads(config.read_text(encoding="utf-8"))["asset_profile"]["PARAMETERS"]
    flags = shlex.split(profile["ASSET_PROCESSOR_OPTIONS"])
    if "--zeroAnalysisMode" in flags or args.platform not in profile["ASSET_PROCESSOR_PLATFORMS"].split(","):
        raise ValueError("PR asset_profile settings do not match the requested target")
    work = args.work_root.resolve()
    work.mkdir(parents=True, exist_ok=True)
    case = Path(tempfile.mkdtemp(prefix="p", dir=work))
    project, sources, cache, user = (case / name for name in ("p", "a", "c", "u"))
    for directory in (project, sources, cache, user):
        directory.mkdir()

    spec = {"project_name": "PR20230Probe", "project_id": "{" + str(uuid.uuid4()) + "}",
            "engine": "o3de", "version": "1.0.0", "gem_names": [], "external_subdirectories": []}
    (project / "project.json").write_text(json.dumps(spec), encoding="utf-8")
    source = sources / "pr20230_cache_probe.mp4"
    source.write_bytes(b"O3DE PR20230 CopyAsset recovery probe\n")
    reference = digest(source)
    # AssetProcessor writes outputs relative to the source scan folder.
    product = cache / args.platform / source.name
    flags = [
        *flags, f"--project-path={project}", f"--engine-path={engine}",
        f"--project-cache-path={cache}", f"--project-user-path={user}",
        f"--platforms={args.platform}", "--noConfigScanFolders", "--noGemScanFolders",
        f"--scanfolders={sources}",
    ]
    revision = subprocess.check_output(["git", "-C", str(engine), "rev-parse", "HEAD"], text=True).strip()
    report.update(platform=args.platform, host=os.name, checkout=revision, options_source=str(config),
                  options_source_sha256=digest(config), binary=str(binary), binary_sha256=digest(binary),
                  fixture_sha256=reference, case=str(case), product=str(product), normal_args=flags)
    runs = report["runs"]

    def run_ap(label, zero=False):
        argv = [str(binary), *flags]
        if zero:
            argv.append("--zeroAnalysisMode")
        filename = output / (label + ".log")
        start = time.perf_counter()
        with filename.open("wb") as log:
            try:
                rc = subprocess.run(argv, cwd=binary.parent, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=args.timeout_seconds, check=False).returncode
            except subprocess.TimeoutExpired:
                rc = 124
        seconds = time.perf_counter() - start
        logtext = filename.read_text(encoding="utf-8", errors="replace")
        result = dict(label=label, zero_analysis=zero, exit_code=rc, elapsed_seconds=round(seconds, 6),
                      log=filename.name, **native_summary(logtext))
        runs.append(result)
        print(json.dumps(result), flush=True)
        if rc != 0 or not result["batch_complete"] or result["failed_assets"] != 0 or result["processed_assets"] is None:
            diagnostics = [line for line in logtext.splitlines() if re.search(r"^AssetProcessor: Failed |\| ERROR \|", line)]
            result["first_errors"] = diagnostics[:12]
            raise RuntimeError(f"{label}: incomplete or failing AP batch; see {filename.name}")
        return result

    def require_product():
        if not product.is_file() or digest(product) != reference:
            raise RuntimeError(f"Expected original SHA-256 at {product}")

    run_ap("cold")
    require_product()
    run_ap("warm")
    require_product()
    # Restore the closed database and all products to the very same paths before each trial.
    snapshot = case / "snapshot"
    snapshot.mkdir()
    for directory in (cache, user):
        shutil.copytree(directory, snapshot / directory.name)

    def restore():
        for directory in (cache, user):
            shutil.rmtree(directory)
            shutil.copytree(snapshot / directory.name, directory)
        require_product()

    restore()
    product.unlink()
    run_ap("missing-normal")
    require_product()
    report["regenerated_sha256"] = digest(product)
    restore()
    product.unlink()
    run_ap("missing-zero", zero=True)
    report["zero_product_present"] = product.exists()
    if product.is_file():
        report["zero_product_sha256"] = digest(product)

    trials = {"normal": [], "zero": []}
    for index in range(4):
        order = ("normal", "zero") if index % 2 == 0 else ("zero", "normal")
        for mode in order:
            restore()
            result = run_ap(f"intact-{index+1}-{mode}", zero=mode == "zero")
            require_product()
            trials[mode].append(result["elapsed_seconds"])
    medians = {mode: statistics.median(times) for mode, times in trials.items()}
    report["intact_mode_comparison"] = {
        "trial_seconds": trials, "median_seconds": medians,
        "median_normal_minus_zero_seconds": medians["normal"] - medians["zero"],
        "scope": "one CopyAsset product, same warm snapshot and paths for each invocation",
    }
    archive_status = None
    if args.archive_probe:
        from pr20230_archive_probe import measure
        restore()
        area = case / "archive"
        area.mkdir()
        report["archive_probe"] = measure(cache=cache, product=product, run_ap=run_ap, work=area, user=user)
        archive_status = report["archive_probe"]["status"]
    if report["zero_product_present"] or (args.archive_probe and archive_status != "PASS"):
        return "INCONCLUSIVE"
    return "PASS"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-source", required=True, type=Path)
    parser.add_argument("--build-root", required=True, type=Path)
    parser.add_argument("--platform", choices=("android", "pc"), required=True)
    parser.add_argument("--work-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="Dedicated report and stdout directory")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--archive-probe", action="store_true")
    parser.add_argument("--timeout-seconds", type=int, default=300)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = {"status": "FAIL", "runs": []}
    try:
        report["status"] = execute(args, out, report)
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
        print(report["error"], flush=True)
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"{args.platform}: {report['status']}", flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
