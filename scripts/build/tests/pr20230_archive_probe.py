# Copyright (c) Contributors to the Open 3D Engine Project.
# SPDX-License-Identifier: Apache-2.0 OR MIT

"""Compare a timestamp-preserving cache restore with the production 7-Zip TAR path."""

import hashlib
import os
from pathlib import Path
import shutil
import stat
import statistics
import subprocess
import tempfile


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def manifest(root):
    # The cache belongs to this invocation. Refuse links before copying the tree.
    records = {}
    for parent, directories, names in os.walk(root):
        for name in directories + names:
            path = Path(parent, name)
            info = path.lstat()
            if path.is_symlink() or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ValueError(f"Unexpected link in probe cache: {path}")
            if name in names:
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError(f"Unexpected non-file: {path}")
                records[path.relative_to(root).as_posix()] = (file_digest(path), info.st_mtime_ns)
    return records


def verify_restore(reference, actual, *, archived):
    if actual.keys() != reference.keys():
        raise ValueError("Restored cache has missing or additional files")
    losses = []
    for name, (digest, old_ns) in reference.items():
        new_digest, new_ns = actual[name]
        if new_digest != digest:
            raise ValueError(f"Restored file content differs: {name}")
        if new_ns != old_ns:
            if not archived or new_ns != old_ns // 1_000_000_000 * 1_000_000_000:
                raise ValueError(f"Unexpected mtime after restore: {name} ({old_ns} -> {new_ns})")
            losses.append(old_ns - new_ns)
    return {"files": len(actual), "rounded_files": len(losses), "max_loss_ns": max(losses, default=0)}


def measure(*, cache: Path, product: Path, run_ap, work: Path, user: Path = None):
    """Replay four alternating pairs at identical absolute paths from one closed-AP snapshot."""
    seven_zip = Path(os.environ["ProgramFiles"], "7-Zip", "7z.exe")
    cache = cache.resolve(strict=True)
    product = product.resolve(strict=True)
    work = work.resolve(strict=True)
    user = user.resolve(strict=True) if user is not None else None
    owned = [cache] if user is None else [cache, user]
    if not all(work != path and path not in work.parents for path in owned):
        raise ValueError("Archive scratch area overlaps an active directory")
    if user and (user == cache or user in cache.parents or cache in user.parents):
        raise ValueError("User and cache snapshots must be independent")
    relative_product = product.relative_to(cache)
    product_digest = file_digest(product)
    rows = []
    result = {
        "status": "INCONCLUSIVE",
        "scope": "isolated Copy builder fixture on Windows",
        "timing_scope": "AssetProcessorBatch process only, excluding snapshot preparation and extraction",
        "pairs": rows,
    }
    if not seven_zip.is_file():
        raise FileNotFoundError(seven_zip)
    with tempfile.TemporaryDirectory(prefix="arc-", dir=work) as scratch_name:
        scratch = Path(scratch_name)
        # Rename the originals out of the way. Only temporary clones see AP writes.
        # Keep all paths on the same volume so a rename cannot partially copy a snapshot.
        originals = []
        try:
            for index, active in enumerate(owned):
                saved = scratch / f"original-{index}"
                active.rename(saved)
                originals.append((active, saved))
            original_cache = originals[0][1]
            original_manifest = manifest(original_cache)
            seed = scratch / "seed" / cache.name
            shutil.copytree(original_cache, seed)
            # NTFS supports 100 ns resolution. Check the precision-preserving control
            # before seeding one known fraction shared by both arms of the experiment.
            verify_restore(original_manifest, manifest(seed), archived=False)
            seed_product = seed / relative_product
            original_time = seed_product.stat()
            seeded_ns = original_time.st_mtime_ns // 1_000_000_000 * 1_000_000_000 + 987_654_300
            os.utime(seed_product, ns=(original_time.st_atime_ns, seeded_ns))
            reference = manifest(seed)
            if reference[relative_product.as_posix()][1] != seeded_ns:
                raise ValueError("Could not seed a fractional mtime on the selected filesystem")

            archive = scratch / "cache.tar"
            subprocess.run([str(seven_zip), "a", "-ttar", "-y", str(archive), seed.name],
                           cwd=seed.parent, check=True, timeout=180)
            result["archive_sha256"] = file_digest(archive)
            result["seed_files"] = len(reference)
            for pair_number in range(1, 5):
                order = ("control", "tar") if pair_number % 2 else ("tar", "control")
                row = {"pair": pair_number, "order": list(order)}
                rows.append(row)
                for arm in order:
                    if user is not None:
                        shutil.copytree(originals[1][1], user)
                    if arm == "control":
                        shutil.copytree(seed, cache)
                    else:
                        subprocess.run([str(seven_zip), "x", "-ttar", "-y", f"-o{cache.parent}", str(archive)],
                                       check=True, timeout=180)
                    meta = verify_restore(reference, manifest(cache), archived=arm == "tar")
                    observed = run_ap(f"archive-pair-{pair_number}-{arm}")
                    row[arm] = {
                        "restore": meta,
                        "exit_code": observed["exit_code"],
                        "elapsed_seconds": observed["elapsed_seconds"],
                        "processed_assets": observed.get("processed_assets"),
                        "product_hash_matches": product.is_file() and file_digest(product) == product_digest,
                    }
                    if observed["exit_code"] != 0 or not row[arm]["product_hash_matches"]:
                        result["status"] = "FAIL"
                        return result
                    shutil.rmtree(cache)
                    if user is not None:
                        shutil.rmtree(user)
        finally:
            for active, saved in reversed(originals):
                if active.exists():
                    shutil.rmtree(active)
                saved.rename(active)
    deltas = [row["tar"]["elapsed_seconds"] - row["control"]["elapsed_seconds"] for row in rows]
    result["median_tar_minus_control_seconds"] = statistics.median(deltas)
    for arm in ("control", "tar"):
        result[f"median_{arm}_seconds"] = statistics.median(row[arm]["elapsed_seconds"] for row in rows)
    if all(row["tar"]["restore"]["rounded_files"] > 0 for row in rows) and all(
        isinstance(row[arm]["processed_assets"], int) for row in rows for arm in ("control", "tar")
    ):
        result["additional_jobs_per_pair"] = [
            row["tar"]["processed_assets"] - row["control"]["processed_assets"] for row in rows
        ]
        result["status"] = "PASS" if max(result["additional_jobs_per_pair"]) <= 0 else "FAIL"
    return result
