import argparse
import hashlib
import json
from pathlib import Path


CANDIDATE = "7e66eb2e5a9dac92eea8d6178e55e7ab5f38e554"
BASELINE = "2ded248b7f3d6993841b05c88b33f36add451a92"
NATIVE_IMAGES = {
    "native-light.png", "native-dark.png", "native-fit-light.png", "native-fit-dark.png",
    "native-inspector-closed-light.png", "native-compact-light.png", "native-narrow-light.png",
    "native-cite-light.png", "native-cite-dark.png", "native-task-overview-light.png",
    "native-task-overview-expanded-light.png", "sidebar-hover-preview.png",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gates", type=Path, required=True)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    directory = Path(__file__).resolve().parent
    log = (arguments.gates / "style-r6-gates-v1.log").read_text()
    assert (arguments.gates / "style-r6-gates-v1.done").exists()
    assert log.splitlines()[-1] == "exit=0"
    fields = dict(line.split("=", 1) for line in log.splitlines() if "=" in line and not line.startswith(" "))
    assert fields["code_head"] == CANDIDATE
    assert fields["pre_porcelain"] == fields["post_porcelain"] == "0"
    assert fields["build"] == fields["workbench_checks"] == fields["native_design"] == "passed"
    assert fields["cold_launches"] == "5/5"
    cold = json.loads((arguments.gates / "app-launch/result.json").read_text())
    assert cold["passed"] and cold["completed_launches"] == 5
    assert cold["revision"] == fields["bundle_describe_stamp"]
    assert cold["revision"] != CANDIDATE
    images = sorted((arguments.gates / "native-design").glob("*.png"))
    assert {source.name for source in images} == NATIVE_IMAGES
    assert all(source.read_bytes().startswith(b"\x89PNG\r\n\x1a\n") for source in images)
    assert json.loads((arguments.gates / "native-design/native-layout.json").read_text())
    assert (arguments.gates / "sources-redline.diff").read_bytes() == b""
    assert (arguments.gates / "measurement-ci-redline.diff").read_bytes() == b""
    for filename in ("build.log", "workbench-checks.log", "radius.log", "localization.log", "native-design.log"):
        assert (arguments.gates / filename).exists()
    comparison = json.loads((arguments.gates / "before-after-comparison.json").read_text())
    assert comparison["status"] == "passed" and comparison["mode"] == "header"
    assert comparison["before_head"] == BASELINE and comparison["after_head"] == CANDIDATE
    assert comparison["before_repeat_byte_pairs"] == comparison["after_repeat_byte_pairs"] == 34
    assert comparison["before_original_pngs"] == comparison["after_original_pngs"] == 68
    assert len(comparison["groups"]) == 34
    assert all(group["outside_allowed_rgba_pixels"] == group["outside_allowed_visible_pixels"] == 0 for group in comparison["groups"])
    unaffected = sorted(group["group"] for group in comparison["groups"] if not group["group"].startswith("workbench-"))
    assert len(unaffected) == 18
    for scene in unaffected:
        for repeat in (1, 2):
            relative = f"{scene}/repeat-{repeat}/capture.png"
            assert digest(arguments.before / relative) == digest(arguments.after / relative)
    scope = json.loads((directory / "source-scope.json").read_text())
    source = directory.parents[4] / "Tests/WorkbenchPreview/App.swift"
    assert digest(source) == scope["source_after_sha256"]
    report = {"status": "passed", "candidate_head": CANDIDATE, "code_sha256": digest(source),
              "mac_gates_exit": 0, "build": "passed", "workbench_checks": "passed",
              "cold_launches": "5/5", "build_describe_stamp": cold["revision"],
              "native_design": "passed", "native_original_pngs": len(images),
              "before_after_original_pngs": 136, "total_original_pngs": 148,
              "cross_job_unchanged_byte_groups": unaffected,
              "original_code_unchanged_since_gui_candidate": True,
              "round_counted_complete": False, "rounds_remaining": 15,
              "certification_boundary": "Actual frozen offline contracts only; not global OS switching, full compositor optics, real sessions/permissions or performance."}
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("PASS: actual Mac gates, 5/5 launches, 12 native originals, source and 18 unchanged byte groups")


if __name__ == "__main__":
    main()
