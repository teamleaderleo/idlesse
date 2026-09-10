import importlib.util
import pathlib
import unittest
spec = importlib.util.spec_from_file_location('batch', pathlib.Path(__file__).with_name('run.py'))
batch = importlib.util.module_from_spec(spec); spec.loader.exec_module(batch)

class AtlasTests(unittest.TestCase):
    def test_scale_pixel_coordinates_preserves_rotation_and_names(self):
        source = 'sheet2.png\nsize: 2048,1024\nregion42\n  rotate: 90\n  xy: 3,5\n  size: 7,9\n  orig: 10,12\n  offset: -1,2\n  index: 4\n'
        result = batch.scale_atlas(source)
        self.assertIn('size: 4096,2048', result)
        self.assertIn('offset: -2,4', result)
        self.assertIn('rotate: 90', result)
        self.assertIn('region42', result)
        self.assertIn('index: 4', result)
    def test_spine42_packed_fields(self):
        self.assertEqual(batch.scale_atlas('bounds: 1,2,3,4\noffsets: -2,3,8,9'),
                         'bounds: 2,4,6,8\noffsets: -4,6,16,18\n')

if __name__ == '__main__': unittest.main()
