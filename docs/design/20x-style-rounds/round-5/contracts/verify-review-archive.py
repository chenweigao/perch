import argparse
import hashlib
import json
import os
import stat
import subprocess
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
ROUND = ROOT / "docs/design/20x-style-rounds/round-5"
REVIEW_SHA256 = "281f695742acc952a223968c3dda85498c426505c7ca84fb71290bcaa47a52e0"
SEAL_SHA256 = "f6bc4e54703a2e73faa39cd67bf0cdc298b56fa2c4d5b5d37e16f24df453b89e"
TESTED_HEAD = "0b05897bad0dfaa22aef446422bbd3a5c31f92ea"
SNAPSHOTS = {
    "docs/design/20x-style-loop/INDEX.md": "INDEX.md",
    "docs/design/20x-style-rounds/round-5/README.md": "README.md",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity(path):
    metadata = path.lstat()
    kind = "symlink" if stat.S_ISLNK(metadata.st_mode) else "file"
    content = os.readlink(path).encode() if kind == "symlink" else path.read_bytes()
    return hashlib.sha256(content).hexdigest(), oct(stat.S_IMODE(metadata.st_mode)), kind


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--allow-authored-snapshots", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    review_path = ROUND / "review-5.json"
    seal_path = ROUND / "contracts/review-input-seal.json"
    assert digest(review_path) == REVIEW_SHA256
    assert digest(seal_path) == SEAL_SHA256
    review = json.loads(review_path.read_text())
    seal = json.loads(seal_path.read_text())
    assert review["verdict"] == "PASS_LIMITED"
    assert review["finding_counts"] == {"P1": 0, "P2": 0, "P3": 1}
    assert not review["blocking_findings"]
    assert review["all_required_frozen_contract_and_visual_checks_completed"]
    assert len(seal["files"]) == seal["input_count"] == 6914
    preserved = []
    for entry in seal["files"]:
        path = ROOT / entry["file"]
        if args.allow_authored_snapshots and entry["file"] in SNAPSHOTS:
            path = ROUND / "contracts/review-original-authored" / SNAPSHOTS[entry["file"]]
            preserved.append({"source": entry["file"], "snapshot": str(path.relative_to(ROOT)), "sha256": entry["sha256"]})
        assert identity(path) == (entry["sha256"], entry["mode"], entry["kind"]), entry["file"]
    historical_reviews = review["history_and_accounting"]["original_reviews"]
    for historical in historical_reviews:
        assert digest(ROOT / historical["source"]) == historical["source_sha256"]
        assert len(historical["findings"]) == historical["original_finding_count"]
    assert sum(item["original_finding_count"] for item in historical_reviews) == 18
    supplement = review["history_and_accounting"]["round4_new_limited_image_supplement"]
    assert digest(ROOT / supplement["file"]) == supplement["sha256"]
    finding = review["findings"][0]
    assert finding["id"] == "S03-R5-F01"
    assert hashlib.sha256(finding["finding_verbatim"].encode()).hexdigest() == finding["finding_utf8_sha256"]
    if args.allow_authored_snapshots:
        disposition = (ROUND / "review-disposition.md").read_text()
        assert finding["finding_verbatim"] in disposition
        assert "原process数字退出码" in disposition
    branch = subprocess.check_output(["git", "branch", "--show-current"], cwd=ROOT, text=True).strip()
    assert branch == "style/loop-main"
    protected_source_diff = subprocess.check_output([
        "git", "diff", "--name-only", TESTED_HEAD, "--", "Sources", "Tests", "scripts", ".github", "Package.swift", "Package.resolved", "AGENTS.md"
    ], cwd=ROOT, text=True)
    assert not protected_source_diff, protected_source_diff
    result = {
        "schema_version": 1,
        "verified_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "branch": branch,
        "real_tested_head": TESTED_HEAD,
        "current_archive_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "verdict": "PASS_LIMITED",
        "review_sha256": REVIEW_SHA256,
        "seal_sha256": SEAL_SHA256,
        "protected_hash_mode_kind_records_verified": 6914,
        "authored_document_originals_preserved": preserved,
        "all_other_inputs_unchanged": True,
        "source_tests_scripts_CI_package_diff_from_real_tested_head": "ZERO",
        "new_findings": review["finding_counts"],
        "finding_id": finding["id"],
        "finding_utf8_sha256": finding["finding_utf8_sha256"],
        "disposition_verbatim_verified": args.allow_authored_snapshots,
        "historical_reviews_and_18_findings_preserved": True,
        "all_uncertified_boundaries_retained": review["uncertified_boundaries"],
        "aesthetic_approval": False,
        "new_build_GUI_or_remote_session_execution": False,
        "remaining_rounds_before_exact_archive_push": 16,
        "counter_advanced_by_this_verifier": False,
    }
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print("PASS: 6914 protected identities, original reviews and source scope; only explicit authored snapshots allowed")


if __name__ == "__main__":
    main()
