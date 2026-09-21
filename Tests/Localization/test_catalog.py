import importlib.util
from pathlib import Path
import tempfile
import unittest

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('catalog', root / 'scripts/check-localization.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class CatalogChecks(unittest.TestCase):
    def parse(self, contents):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Localizable.strings'
            path.write_text(contents)
            return catalog.table_entries(path)

    def test_rejects_interpolation_type_change(self):
        with self.assertRaises(ValueError):
            self.parse('"%lld 个 SSH" = "%@ SSH";')

    def test_rejects_duplicate_key(self):
        with self.assertRaises(ValueError):
            self.parse('"工作台" = "Workspace";\n"工作台" = "Other";')

    def test_positional_reordering_preserves_types(self):
        self.parse('"%@ has %lld" = "%2$lld for %1$@";')

    def test_shipped_languages_have_matching_keys(self):
        self.assertEqual(set(catalog.table_entries(catalog.EN_TABLE)),
                         set(catalog.table_entries(catalog.ZH_TABLE)))


if __name__ == '__main__':
    unittest.main()
