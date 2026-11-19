import argparse
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import tempfile

import numpy
from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise ValueError("Refusing to overwrite a control result")
    source = Path(__file__).with_name("compare-quiet-captures.py")
    specification = importlib.util.spec_from_file_location("quiet_comparison_controls", source)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    profile, reader, unused_png_reader = module.load_profile()
    checks = []

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        checks.append({"name": name, "status": "passed"})

    background = numpy.zeros((24, 24, 4), dtype=numpy.uint8)
    background[:, :, :3] = [31, 34, 41]
    background[:, :, 3] = 255
    check("flat_background_excluded", not module.foreground_mask(background, profile["mask_rules"]).any())
    quiet = background.copy()
    quiet[:, :, :3] = profile["mask_rules"]["quiet_srgb_seed"]
    check("pure_quiet_seed_included", module.foreground_mask(quiet, profile["mask_rules"]).all())
    island = background.copy()
    island[12, 12, :3] = [80, 90, 100]
    mask = module.foreground_mask(island, profile["mask_rules"])
    check("prewritten_edge_dilation_includes_foreground", bool(mask[12, 12]))
    check("edge_dilation_does_not_admit_far_background", not bool(mask[0, 0] or mask[-1, -1]))
    check("edge_dilation_is_clipped_not_wrapped", not bool(mask[0, -1] or mask[-1, 0]))

    first = numpy.full((2, 2, 3), 80, dtype=numpy.uint8)
    rules = profile["color_rules"]
    check("zero_increment_valid", not module.invalid_color_pixels(first, first, rules).any())
    check("neutral_step_5_valid", not module.invalid_color_pixels(first, first + 5, rules).any())
    check("prewritten_upper_step_8_valid", not module.invalid_color_pixels(first, first + 8, rules).any())
    check("step_9_rejected", module.invalid_color_pixels(first, first + 9, rules).all())
    check("negative_step_rejected", module.invalid_color_pixels(first, first - 1, rules).all())
    tinted = first + numpy.array([0, 0, 4], dtype=numpy.uint8)
    check("non_neutral_channel_span_rejected", module.invalid_color_pixels(first, tinted, rules).all())

    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        before_path, after_path = base / "before", base / "after"

        def comparison(name, dark, mask_value, rgb_step=0, alpha=255, original_alpha=255):
            scene = "control-dark" if dark else "control-light"
            rgba = numpy.full((2, 2, 4), 80, dtype=numpy.uint8)
            rgba[:, :, 3] = original_alpha
            after_rgba = rgba.copy()
            after_rgba[:, :, :3] += rgb_step
            after_rgba[:, :, 3] = alpha
            before_visible = rgba[:, :, :3] if original_alpha else numpy.full((2, 2, 3), 255, dtype=numpy.uint8)
            after_visible = after_rgba[:, :, :3] if alpha else numpy.full((2, 2, 3), 255, dtype=numpy.uint8)
            for path, pixels in ((before_path, rgba), (after_path, after_rgba)):
                for repeat in (1, 2):
                    target = path / scene / f"repeat-{repeat}"
                    target.mkdir(parents=True, exist_ok=True)
                    Image.fromarray(pixels).save(target / "capture.png")
            before = {scene: {"rgba": rgba, "visible": before_visible, "environment": {}}}
            after = {scene: {"rgba": after_rgba, "visible": after_visible, "environment": {}}}
            synthetic = dict(profile, scenes=[scene], affected_scenes=[scene] if dark else [])
            masks = {scene: numpy.full((2, 2), mask_value, dtype=bool)} if dark else {}
            result = module.compare(before_path, after_path, before, after, synthetic, masks, reader, "color")[0]
            return result

        check("unchanged_light_passes", comparison("light", False, False)["pass"])
        check("changed_light_rejected", not comparison("light-step", False, False, 5)["pass"])
        check("dark_foreground_neutral_step_passes", comparison("foreground", True, True, 5)["pass"])
        outside = comparison("outside", True, False, 5)
        check("mask_outside_rgba_and_visible_zero_tolerance", not outside["pass"] and outside["outside_allowed_rgba_pixels"] == outside["outside_allowed_visible_pixels"] == 4)
        check("alpha_change_rejected", not comparison("alpha", True, True, 0, 254)["pass"])
        invisible = comparison("invisible", True, True, 5, 0, 0)
        check("invisible_rgba_change_rejected", not invisible["pass"] and invisible["transparent_rgba_changed_pixels"] == 4)

    original_hash = module.PROFILE_SHA256
    module.PROFILE_SHA256 = "0" * 64
    try:
        module.load_profile()
    except ValueError:
        check("wrong_profile_anchor_rejected", True)
    else:
        raise AssertionError("wrong_profile_anchor_rejected")
    finally:
        module.PROFILE_SHA256 = original_hash

    report = {"status": "passed", "checked_at": datetime.now().astimezone().isoformat(timespec="seconds"),
              "control_count": len(checks), "checks": checks, "comparison_source_sha256": module.digest(source),
              "profile_sha256": original_hash, "synthetic_controls_not_GUI_evidence": True,
              "product_modified_by_controls": False}
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "checks"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
