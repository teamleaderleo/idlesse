import importlib.util
import pathlib
import unittest
spec = importlib.util.spec_from_file_location('batch', pathlib.Path(__file__).with_name('run.py'))
batch = importlib.util.module_from_spec(spec); spec.loader.exec_module(batch)
spec = importlib.util.spec_from_file_location('verify', pathlib.Path(__file__).with_name('verify.py'))
verify = importlib.util.module_from_spec(spec); spec.loader.exec_module(verify)

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

class EdgeBarTests(unittest.TestCase):
    def frame(self, box=None, matte='black'):
        """A frame of `matte` with a gradient 'artwork' pasted at `box`.

        The artwork is deliberately non-uniform: real exports never have four
        matching corners unless something really is matted.
        """
        from PIL import Image
        im = Image.new('RGB', (512, 288), matte)
        if box:
            w, h = box[2] - box[0], box[3] - box[1]
            art = Image.new('RGB', (w, h))
            px = art.load()
            for y in range(h):
                for x in range(w):
                    px[x, y] = (40 + (200 * x) // max(w - 1, 1), 90, 200 - (150 * y) // max(h - 1, 1))
            im.paste(art, box[:2])
        return im
    def test_full_bleed_frame_has_no_dead_edges(self):
        self.assertEqual(verify.bars(self.frame((0, 0, 512, 288))), {'top': 0, 'bottom': 0, 'left': 0, 'right': 0})
    def test_offcentre_camera_leaves_measurable_bars(self):
        self.assertEqual(verify.bars(self.frame((0, 106, 333, 288))), {'top': 106, 'bottom': 0, 'left': 0, 'right': 179})
    def test_wholly_black_frame_reports_full_span(self):
        self.assertEqual(verify.bars(self.frame()), {'top': 288, 'bottom': 288, 'left': 512, 'right': 512})
    def test_renderer_void_is_caught_like_letterboxing(self):
        edges = verify.bars(self.frame((120, 60, 400, 230), matte=(24, 32, 43)))
        self.assertEqual(edges, {'top': 60, 'bottom': 58, 'left': 120, 'right': 112})

class FidelityTests(unittest.TestCase):
    def test_main10_requires_profile_and_ten_bit_pixels(self):
        self.assertTrue(verify.is_main10({'codec_name': 'hevc', 'profile': 'Main 10', 'pix_fmt': 'yuv420p10le'}))
        self.assertTrue(verify.is_main10({'codec_name': 'hevc', 'profile': 'Main 10', 'pix_fmt': 'p010le'}))
        self.assertFalse(verify.is_main10({'codec_name': 'hevc', 'profile': 'Main 10', 'pix_fmt': 'yuv420p'}))
        self.assertFalse(verify.is_main10({'codec_name': 'hevc', 'profile': 'Main', 'pix_fmt': 'yuv420p10le'}))
    def test_gradient_levels_count_vertical_channel_precision(self):
        from PIL import Image
        image=Image.new('RGB',(4,10))
        pixels=image.load()
        for y in range(10):
            for x in range(4):pixels[x,y]=(255,y,80)
        self.assertEqual(verify.gradient_levels(image,[0,3],'g'),[10,10])
        self.assertEqual(verify.gradient_levels(image,[1],'r'),[1])
    def test_gradient_columns_are_bounded(self):
        from PIL import Image
        with self.assertRaises(ValueError):verify.gradient_levels(Image.new('RGB',(4,4)),[4],'g')

if __name__ == '__main__': unittest.main()
