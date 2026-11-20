from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import tarfile
import sys


root = Path(sys.argv[1])
records = []
for directory, folders, names in os.walk(root):
    folders[:] = sorted(name for name in folders if not name.endswith(".app"))
    for name in sorted(names):
        path = Path(directory) / name
        assert not path.is_symlink()
        payload = path.read_bytes()
        records.append({"path": path.relative_to(root).as_posix(), "bytes": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest()})
manifest = {"schema_version": 1, "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "job": root.name, "app_bundle_excluded": True, "files": records}
manifest_path = Path(str(root) + ".archive-manifest.json")
with manifest_path.open("x") as output:
    json.dump(manifest, output, indent=2)
    output.write("\n")
archive = Path(str(root) + ".raw.tar.gz")
with tarfile.open(archive, "w:gz") as output:
    for record in records:
        output.add(root / record["path"], arcname=root.name + "/" + record["path"], recursive=False)
    output.add(manifest_path, arcname=root.name + ".archive-manifest.json", recursive=False)
print(json.dumps({"archive": archive.name, "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                  "original_files": len(records)}))
