import hashlib
from pathlib import Path
import runpy


WRAPPER_SHA256 = "49ed5d26e810739fe44314499c0fdb04296eb3143ce24e7a3d7e65f03e5c9ea2"


def main():
    source = Path.cwd() / "docs/design/20x-style-rounds/round-6/contracts/capture-matrix.py"
    if hashlib.sha256(source.read_bytes()).hexdigest() != WRAPPER_SHA256:
        raise ValueError("Protected round 6 capture wrapper hash mismatch")
    runpy.run_path(str(source), run_name="__main__")


if __name__ == "__main__":
    main()
