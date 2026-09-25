import importlib.util
import pathlib
import unittest
root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('efforts',root/'scripts/configure-verified-efforts.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class EffortTests(unittest.TestCase):
    def test_preserves_credentials_and_other_settings_exactly(self):
        text='[providers.p]\napi_key = "fixture-key"\n[models."p/model"]\nprovider = "p"\nmodel = "model"\n'
        changes={'p/model':{'support_efforts':['low','high']}}
        result=module.updated_config(text,changes)
        self.assertTrue(result.startswith(text))
        parsed=module.tomllib.loads(result)
        self.assertEqual(parsed['models']['p/model']['overrides']['support_efforts'],['low','high'])
        self.assertEqual(module.updated_config(result,changes),result)
    def test_never_overwrites_existing_metadata(self):
        with self.assertRaises(ValueError): module.updated_config('[models.m]\nsupport_efforts=["high"]\n', {'m':{'support_efforts':['low']}})
    def test_unknown_model_is_not_created(self):
        with self.assertRaises(ValueError): module.updated_config('', {'missing':{'support_efforts':['low']}})
    def test_existing_override_table_is_preserved(self):
        with self.assertRaises(ValueError): module.updated_config('[models.m.overrides]\nmax_context_size=100\n', {'m':{'support_efforts':['low']}})
