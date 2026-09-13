import importlib.util
import pathlib
import unittest
spec = importlib.util.spec_from_file_location('batch', pathlib.Path(__file__).with_name('run.py'))
batch = importlib.util.module_from_spec(spec); spec.loader.exec_module(batch)
spec = importlib.util.spec_from_file_location('verify', pathlib.Path(__file__).with_name('verify.py'))
verify = importlib.util.module_from_spec(spec); spec.loader.exec_module(verify)
import sys
sys.modules.setdefault('verify', verify)
spec = importlib.util.spec_from_file_location('ingest', pathlib.Path(__file__).with_name('ingest.py'))
ingest = importlib.util.module_from_spec(spec); spec.loader.exec_module(ingest)

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
        # Azur spine background 0x18202b: not black, so a darkness test misses it.
        edges = verify.bars(self.frame((120, 60, 400, 230), matte=(24, 32, 43)))
        self.assertEqual(edges, {'top': 60, 'bottom': 58, 'left': 120, 'right': 112})
    def test_matte_down_part_of_an_edge_is_caught(self):
        # Nagisa: black for the top of the left edge only, so no column is
        # wholly matte. Requiring one passed this as clean.
        im = self.frame((0, 0, 512, 288))
        im.paste((0, 0, 0), (0, 0, 9, 110))
        self.assertEqual(verify.bars(im)['left'], 9)
    def test_angled_wedge_reports_its_deepest_point(self):
        im = self.frame((0, 0, 512, 288))
        px = im.load()
        for y in range(288):
            for x in range(max(0, 40 - y // 4)):
                px[511 - x, y] = (0, 0, 0)
        self.assertEqual(verify.bars(im)['right'], 40)
    def test_scattered_dark_art_at_the_edge_is_not_matte(self):
        # An outline or dark hair touching the frame for a few lines.
        im = self.frame((0, 0, 512, 288))
        im.paste((0, 0, 0), (0, 140, 30, 150))
        self.assertEqual(verify.bars(im)['left'], 0)
    def test_near_black_painted_texture_is_not_matte(self):
        # Sakurako's shadowed stone: dark, but grain from 4 to 11, never flat.
        im = self.frame((0, 0, 512, 288))
        px = im.load()
        for y in range(120):
            for x in range(512):
                v = 1 + (x * 7 + y * 3) % 3
                px[x, y] = (v, v + 1, v + 2)
        self.assertEqual(verify.bars(im)['top'], 0)
    def test_encoded_void_colour_still_matches(self):
        edges = verify.bars(self.frame((120, 60, 400, 230), matte=(25, 32, 43)))
        self.assertEqual(edges, {'top': 60, 'bottom': 58, 'left': 120, 'right': 112})

class CropCameraTests(unittest.TestCase):
    def mapped(self, camera, p):
        # render.js: a stage point at frame fraction p lands at 0.5 + (p - c) * zoom.
        zoom, cx, cy = camera
        return 0.5 + (p[0] - cx) * zoom, 0.5 + (p[1] - cy) * zoom
    def test_crop_box_fills_the_new_frame(self):
        base = [1.3, 0.45, 0.55]
        box = [0.2, 0.1, 0.5, 0.5]
        camera = ingest.crop_to_camera(base, box)
        # The box's corners, as stage points under the base camera...
        def stage(q): return (base[1] + (q[0] - 0.5) / base[0], base[2] + (q[1] - 0.5) / base[0])
        top_left = self.mapped(camera, stage((0.2, 0.1)))
        bottom_right = self.mapped(camera, stage((0.7, 0.6)))
        # ...land on the new frame's edges.
        for got, want in zip(top_left + bottom_right, (0, 0, 1, 1)):
            self.assertAlmostEqual(got, want, places=3)
    def test_whole_frame_is_the_same_camera(self):
        self.assertEqual(ingest.crop_to_camera([2.0, 0.4, 0.6], [0, 0, 1, 1]), [2.0, 0.4, 0.6])
        self.assertEqual(ingest.crop_to_camera(None, [0, 0, 1, 1]), [1.0, 0.5, 0.5])
    def test_box_that_is_not_16_9_is_shown_whole(self):
        zoom, _, _ = ingest.crop_to_camera(None, [0.25, 0, 0.5, 1])
        self.assertEqual(zoom, 1.0)
    def test_rejects_a_box_outside_the_frame(self):
        with self.assertRaises(SystemExit):
            ingest.crop_to_camera(None, [0.8, 0, 0.5, 1])
    def test_recipe_for_one_animation_leaves_the_others(self):
        cams = {'A_home': [1.2, 0.5, 0.5]}
        result = ingest.with_recipe(cams, 'A_home', 'Idle_02', [2, 0.4, 0.4])
        self.assertEqual(result['A_home'], {'default': [1.2, 0.5, 0.5], 'Idle_02': [2, 0.4, 0.4]})
        self.assertEqual(ingest.recipe_for(result, 'A_home', 'Idle_01'), [1.2, 0.5, 0.5])
        self.assertEqual(cams, {'A_home': [1.2, 0.5, 0.5]}, 'input is not mutated')

class PaintedAreaTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('calibrate', pathlib.Path(__file__).with_name('calibrate.py'))
        self.calibrate = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.calibrate)
    def scene(self, box, notch=None, dark=None):
        from PIL import Image, ImageDraw
        im = Image.new('RGB', (1920, 1080), 'black')
        d = ImageDraw.Draw(im)
        d.rectangle(box, fill=(120, 160, 200))
        if notch: d.rectangle(notch, fill='black')
        if dark: d.rectangle(dark, fill=(0, 0, 0))
        return im
    def test_box_stays_inside_the_painted_area(self):
        mask = self.calibrate.matte_mask(self.scene((200, 100, 1700, 1000)))
        x, y, w, h = self.calibrate.largest_box([mask])
        self.assertGreaterEqual(x, 200 / 1920); self.assertGreaterEqual(y, 100 / 1080)
        self.assertLessEqual(x + w, 1700 / 1920 + 1e-9); self.assertLessEqual(y + h, 1000 / 1080 + 1e-9)
        self.assertGreater(h, 0.75)
    def test_dark_art_inside_the_picture_is_not_matte(self):
        mask = self.calibrate.matte_mask(self.scene((0, 0, 1920, 1080), dark=(800, 400, 1100, 700)))
        self.assertEqual(self.calibrate.largest_box([mask]), (0.0, 0.0, 1.0, 1.0))
    def test_a_corner_notch_shrinks_the_box_without_recentering_on_it(self):
        full = self.calibrate.matte_mask(self.scene((0, 0, 1920, 1080), notch=(0, 800, 300, 1080)))
        x, y, w, h = self.calibrate.largest_box([full])
        self.assertGreater(w, 0.7)
        self.assertTrue(x * 1920 >= 300 or (y + h) * 1080 <= 800)
    def test_every_frame_of_the_loop_counts(self):
        a = self.calibrate.matte_mask(self.scene((0, 0, 1920, 1080), notch=(0, 0, 400, 1080)))
        b = self.calibrate.matte_mask(self.scene((0, 0, 1920, 1080), notch=(1520, 0, 1920, 1080)))
        x, y, w, h = self.calibrate.largest_box([a, b])
        self.assertGreaterEqual(x * 1920, 400); self.assertLessEqual((x + w) * 1920, 1520 + 1e-6)

class SmoothEdgeTests(unittest.TestCase):
    from PIL import Image, ImageDraw, ImageFilter
    import smooth_edges

    def pages(self):
        """A diagonal silhouette stepped every 2px (one source pixel at 2x), and the smooth diagonal a mask would give."""
        stepped = self.Image.new('L', (160, 160), 0)
        draw = self.ImageDraw.Draw(stepped)
        for y in range(160):
            draw.line([(0, y), ((y // 2) * 2, y)], fill=255)
        smooth = self.Image.new('L', (160, 160), 0)
        self.ImageDraw.Draw(smooth).polygon([(0, 0), (160, 160), (0, 160)], fill=255)
        return stepped.filter(self.ImageFilter.BoxBlur(0.5)), smooth.filter(self.ImageFilter.BoxBlur(0.5))

    def test_stepped_outline_takes_the_mask(self):
        alpha, mask = self.pages()
        out = self.smooth_edges.blend(alpha, mask)
        value = out.getpixel((81, 80))
        self.assertLess(abs(value - mask.getpixel((81, 80))), abs(value - alpha.getpixel((81, 80))))

    def test_reshaped_area_keeps_the_painted_alpha(self):
        alpha, _ = self.pages()
        mask = self.Image.new('L', alpha.size, 255)  # the model filled a gap that should stay open
        out = self.smooth_edges.blend(alpha, mask)
        self.assertEqual(out.getpixel((120, 40)), alpha.getpixel((120, 40)))

    def test_lace_keeps_the_painted_alpha(self):
        lace = self.Image.new('L', (160, 160), 0)
        draw = self.ImageDraw.Draw(lace)
        for x in range(0, 160, 3):
            for y in range(0, 160, 3):
                draw.point((x, y), fill=255)
        lace = lace.filter(self.ImageFilter.BoxBlur(1))
        mask = lace.filter(self.ImageFilter.BoxBlur(2))
        out = self.smooth_edges.blend(lace, mask)
        self.assertEqual(out.getpixel((80, 80)), lace.getpixel((80, 80)))

if __name__ == '__main__': unittest.main()
