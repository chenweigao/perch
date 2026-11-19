import importlib.util
from pathlib import Path


def main():
    source = Path.cwd() / "scripts/capture-style-loop.py"
    specification = importlib.util.spec_from_file_location("style_capture", source)
    if specification is None or specification.loader is None:
        raise RuntimeError("Unable to load the existing style capture driver")
    capture_module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(capture_module)
    capture_module.VARIANTS.extend([
        ("english-dark", {"PERCH_STYLE_LOCALE": "en", "PERCH_STYLE_DARK": "1"}),
        ("english-large-type", {"PERCH_STYLE_LOCALE": "en", "PERCH_STYLE_LARGE_TYPE": "1"}),
        ("english-large-type-dark", {
            "PERCH_STYLE_LOCALE": "en", "PERCH_STYLE_LARGE_TYPE": "1", "PERCH_STYLE_DARK": "1",
        }),
        ("large-type-dark", {"PERCH_STYLE_LARGE_TYPE": "1", "PERCH_STYLE_DARK": "1"}),
    ])
    capture_module.PREVIEW_VARIANTS["workbench"] = list(capture_module.VARIANTS)
    capture_module.main()


if __name__ == "__main__":
    main()
