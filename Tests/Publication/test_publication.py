import contextlib
import importlib.util
import io
import pathlib
import subprocess
import tempfile
import tarfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("publication", ROOT / "scripts/check-public-source.py")
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)

export_spec = importlib.util.spec_from_file_location("exporter", ROOT / "scripts/export-public-source.py")
exporter = importlib.util.module_from_spec(export_spec)
export_spec.loader.exec_module(exporter)


class PublicationTests(unittest.TestCase):
    def test_sensitive_values_are_reported_without_echoing_them(self):
        value = b"sk-" + b"X" * 30
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertGreater(publication.findings("fixture", value), 0)
        self.assertNotIn(value.decode(), output.getvalue())

    def test_example_address_is_allowed_but_private_address_is_not(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(publication.findings("fixture", b"user@host.example /home/user/code"), 0)
            self.assertGreater(publication.findings("fixture", b"user@" + b"company.test"), 0)
            self.assertGreater(publication.findings("fixture", b"/Users/" + b"personal-name/project"), 0)

    def test_json_escaped_personal_path_is_detected_without_echoing(self):
        path = b"/Users/" + b"personal-name/project"
        escaped = path.replace(b"/", bytes([92, 47]))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertGreater(publication.findings("fixture.json", escaped), 0)
        self.assertNotIn("personal-name", output.getvalue())

    def test_export_ignored_parent_is_not_scanned_as_public_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "-q", directory], check=True)
            (root / ".gitattributes").write_text("private export-ignore\n")
            (root / "private/nested").mkdir(parents=True)
            (root / "private/nested/note.txt").write_text("private fixture")
            (root / "README.md").write_text("public fixture")
            paths = {str(p.relative_to(root)) for p in publication.publication_paths(root)}
            self.assertIn("README.md", paths)
            self.assertNotIn("private/nested/note.txt", paths)

    def link_archive(self, linkname):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w") as archive:
            member = tarfile.TarInfo("Sources/Agent.swift")
            data = b"// source fixture"
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
            link = tarfile.TarInfo("Tests/Agent.swift")
            link.type = tarfile.SYMTYPE
            link.linkname = linkname
            archive.addfile(link)
        return buffer.getvalue()

    def test_export_preserves_included_source_link_and_future_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            exporter.extract_source(self.link_archive("../Sources/Agent.swift"), root)
            output = root / "Tests/Agent.swift"
            self.assertTrue(output.is_symlink())
            self.assertEqual(output.read_bytes(), (root / "Sources/Agent.swift").read_bytes())
            (root / "Sources/Agent.swift").write_bytes(b"// updated source")
            self.assertEqual(output.read_bytes(), b"// updated source")

    def test_export_rejects_outside_absolute_and_excluded_link_targets(self):
        for target in ("../../outside.swift", "/Sources/Agent.swift", "../private/excluded.swift"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(ValueError, "included regular file"):
                    exporter.extract_source(self.link_archive(target), pathlib.Path(directory))

    def test_export_never_overwrites_an_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["python3", str(ROOT / "scripts/export-public-source.py"), directory], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"Destination exists", result.stderr)


if __name__ == "__main__":
    unittest.main()
