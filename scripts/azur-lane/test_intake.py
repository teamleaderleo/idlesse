import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('fetch_viewer',Path(__file__).with_name('fetch-viewer.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ModelReferences(unittest.TestCase):
 def test_nested_assets_are_preserved(self):
  self.assertEqual(module.relative('textures/texture_00.png'),'textures/texture_00.png')
 def test_rejects_external_and_traversing_assets(self):
  for value in ['../file','textures/../../file','/tmp/file','https://example.com/file','C:\\file']:
   with self.subTest(value=value),self.assertRaises(ValueError):module.relative(value)

if __name__=='__main__':unittest.main()
