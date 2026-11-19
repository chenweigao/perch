import hashlib
import importlib.util
from pathlib import Path


SOURCE_SHA256 = "43d8934fcf70b190e6e5bb6a448e8a9418cd6b6a558e0a940e208a8e7687fc5f"
SCENARIO_LINE = 'arguments += ["-scenario", "日常"]'
FIRST_USE_LINE = 'arguments += ["-scenario", "首次使用" if settings.get("PERCH_STYLE_FIRST_USE") == "1" else "日常"]'


def load_capture_module():
    source = Path.cwd() / "scripts/capture-style-loop.py"
    content = source.read_bytes()
    if hashlib.sha256(content).hexdigest() != SOURCE_SHA256:
        raise ValueError("Existing capture driver hash mismatch")
    text = content.decode()
    if text.count(SCENARIO_LINE) != 1:
        raise ValueError("Expected one existing Workbench scenario argument line")
    specification = importlib.util.spec_from_file_location("style_capture", source)
    if specification is None or specification.loader is None:
        raise RuntimeError("Unable to load the existing style capture driver")
    capture_module = importlib.util.module_from_spec(specification)
    exec(compile(text.replace(SCENARIO_LINE, FIRST_USE_LINE), str(source), "exec"), capture_module.__dict__)
    capture_module.VARIANTS.extend([
        ("english-dark", {"PERCH_STYLE_LOCALE": "en", "PERCH_STYLE_DARK": "1"}),
        ("english-large-type", {"PERCH_STYLE_LOCALE": "en", "PERCH_STYLE_LARGE_TYPE": "1"}),
        ("english-large-type-dark", {
            "PERCH_STYLE_LOCALE": "en", "PERCH_STYLE_LARGE_TYPE": "1", "PERCH_STYLE_DARK": "1",
        }),
        ("large-type-dark", {"PERCH_STYLE_LARGE_TYPE": "1", "PERCH_STYLE_DARK": "1"}),
    ])
    capture_module.PREVIEW_VARIANTS["workbench"] = list(capture_module.VARIANTS) + [
        ("empty-" + variant, dict(settings, PERCH_STYLE_FIRST_USE="1"))
        for variant, settings in capture_module.VARIANTS if variant != "light"
    ]
    return capture_module


def main():
    load_capture_module().main()


if __name__ == "__main__":
    main()
