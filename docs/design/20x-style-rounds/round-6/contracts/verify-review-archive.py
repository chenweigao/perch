import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


ROOT = Path(__file__).resolve().parents[5]
ROUND = ROOT / "docs/design/20x-style-rounds/round-6"
TESTED_HEAD = "7e66eb2e5a9dac92eea8d6178e55e7ab5f38e554"
BASELINE_HEAD = "2ded248b7f3d6993841b05c88b33f36add451a92"
CONTRACT_SHA256 = "3b1d333c9414f2c87a92159ba22dd98cb6c24620c158f7cf9e6183591329ac60"
SNAPSHOTS = {
    "docs/design/20x-style-loop/INDEX.md": "INDEX.md",
    "docs/design/20x-style-rounds/round-6/README.md": "README.md",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity(path):
    metadata = path.lstat()
    kind = "symlink" if stat.S_ISLNK(metadata.st_mode) else "file"
    assert kind == "symlink" or stat.S_ISREG(metadata.st_mode), str(path.relative_to(ROOT))
    content = os.readlink(path).encode() if kind == "symlink" else path.read_bytes()
    return hashlib.sha256(content).hexdigest(), oct(stat.S_IMODE(metadata.st_mode)), kind


def git_output(*arguments):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    return subprocess.check_output(["git", *arguments], cwd=ROOT, text=True, env=environment).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seal-sha256", required=True)
    parser.add_argument("--review-sha256")
    parser.add_argument("--inputs-only", action="store_true")
    parser.add_argument("--allow-authored-snapshots", action="store_true")
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    seal_path = ROUND / "contracts/review-input-seal.json"
    assert digest(seal_path) == arguments.seal_sha256
    seal = json.loads(seal_path.read_text())
    assert seal["head"] == TESTED_HEAD and seal["baseline_head"] == BASELINE_HEAD
    assert seal["frozen_contract_sha256"] == CONTRACT_SHA256
    assert len(seal["files"]) == seal["input_count"]
    assert len({entry["file"] for entry in seal["files"]}) == seal["input_count"]
    snapshots = []
    for entry in seal["files"]:
        source = ROOT / entry["file"]
        if arguments.allow_authored_snapshots and entry["file"] in SNAPSHOTS:
            source = ROUND / "contracts/review-original-authored" / SNAPSHOTS[entry["file"]]
            snapshots.append({"source": entry["file"], "snapshot": str(source.relative_to(ROOT)),
                              "sha256": entry["sha256"]})
        assert identity(source) == (entry["sha256"], entry["mode"], entry["kind"]), entry["file"]
    assert git_output("branch", "--show-current") == "style/loop-main"
    if not arguments.allow_authored_snapshots:
        assert git_output("rev-parse", "HEAD") == TESTED_HEAD
        assert digest(ROOT / git_output("rev-parse", "--git-path", "index")) == seal["git_index_sha256"]
    protected_diff = git_output("diff", "--name-only", TESTED_HEAD, "--", "Sources", "Tests", "scripts",
                                ".github", "Package.swift", "Package.resolved", "AGENTS.md")
    assert not protected_diff, protected_diff
    ledger_path = ROUND / "contracts/historical-findings.json"
    ledger = json.loads(ledger_path.read_text())
    assert ledger["original_finding_count"] == 19
    assert sum(len(entry["findings"]) for entry in ledger["original_reviews"]) == 19
    for entry in ledger["original_reviews"]:
        original_path = ROOT / entry["source"]
        assert digest(original_path) == entry["source_sha256"]
        original = json.loads(original_path.read_text())
        assert entry["findings"] == original["findings"]
        assert entry["verdict"] == original["verdict"]
    supplement = ledger["round4_image_supplement"]
    assert digest(ROOT / supplement["source"]) == supplement["source_sha256"]
    assert json.loads((ROOT / supplement["source"]).read_text())["verdict"] == "PASS_LIMITED"
    report = {"status": "passed", "verified_at": datetime.now().astimezone().isoformat(timespec="seconds"),
              "branch": "style/loop-main", "real_tested_head": TESTED_HEAD,
              "current_archive_head": git_output("rev-parse", "HEAD"),
              "seal_sha256": arguments.seal_sha256,
              "protected_hash_mode_kind_records_verified": seal["input_count"],
              "original_historical_findings_verified": 19,
              "round4_original_FAIL_and_image_supplement_preserved": True,
              "authored_original_snapshots": snapshots,
              "protected_product_and_scripts_diff": "ZERO", "counter_advanced_by_this_verifier": False,
              "rounds_remaining_before_exact_archive_push": 15}
    if not arguments.inputs_only:
        assert arguments.review_sha256
        review_path = ROUND / "review-6.json"
        assert digest(review_path) == arguments.review_sha256
        review = json.loads(review_path.read_text())
        assert review["verdict"] == "PASS_LIMITED"
        assert review["all_required_frozen_contract_and_visual_checks_completed"]
        assert not review["blocking_findings"]
        assert review["finding_counts"]["P1"] == review["finding_counts"]["P2"] == 0
        assert review["historical_findings_ledger_sha256"] == digest(ledger_path)
        for finding in review["findings"]:
            assert finding["severity"] == "P3" and not finding["blocking"]
            assert hashlib.sha256(finding["finding_verbatim"].encode()).hexdigest() == finding["finding_utf8_sha256"]
            if arguments.allow_authored_snapshots:
                assert finding["finding_verbatim"] in (ROUND / "review-disposition.md").read_text()
        assert len(review["findings"]) == review["finding_counts"]["P3"]
        report.update(verdict=review["verdict"], review_sha256=arguments.review_sha256,
                      new_findings=review["finding_counts"], finding_disposition_verified=arguments.allow_authored_snapshots,
                      all_uncertified_boundaries_retained=review["uncertified_boundaries"])
    if arguments.output:
        assert not arguments.output.exists()
        arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
