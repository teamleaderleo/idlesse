import unittest
from pathlib import Path
from fidelity import requested_bit_depth, stream_matches_bit_depth


class BitDepthPolicyTests(unittest.TestCase):
    def test_default_is_main10(self):
        self.assertEqual(requested_bit_depth({}), 10)

    def test_explicit_eight_bit_compatibility(self):
        self.assertEqual(requested_bit_depth({'IDLESSE_EXPORT_BIT_DEPTH': '8'}), 8)

    def test_invalid_depth_is_rejected(self):
        for value in ('', '9', 'ten'):
            with self.assertRaises(ValueError):
                requested_bit_depth({'IDLESSE_EXPORT_BIT_DEPTH': value})

    def test_main10_requires_profile_and_ten_bit_pixels(self):
        self.assertTrue(stream_matches_bit_depth({'codec_name':'hevc','profile':'Main 10','pix_fmt':'yuv420p10le'},10))
        self.assertTrue(stream_matches_bit_depth({'codec_name':'hevc','profile':'Main 10','pix_fmt':'p010le'},10))
        self.assertFalse(stream_matches_bit_depth({'codec_name':'hevc','profile':'Main 10','pix_fmt':'yuv420p'},10))
        self.assertFalse(stream_matches_bit_depth({'codec_name':'hevc','profile':'Main','pix_fmt':'yuv420p10le'},10))

    def test_eight_bit_route_rejects_main10(self):
        self.assertTrue(stream_matches_bit_depth({'codec_name':'hevc','profile':'Main','pix_fmt':'yuv420p'},8))
        self.assertFalse(stream_matches_bit_depth({'codec_name':'hevc','profile':'Main 10','pix_fmt':'yuv420p10le'},8))

    def test_every_export_route_has_an_explicit_fidelity_guard(self):
        root=Path(__file__).parent
        web=(root/'fast-export.js').read_text()
        frame=(root/'Render.swift').read_text()
        render=(root/'render.js').read_text()
        x265=(root/'encode_x265.py').read_text()
        self.assertIn('canEncodeVideo',web)
        self.assertIn('hvc1.2.4.L153.B0',web)
        self.assertIn('fullCodecString',web)
        self.assertIn("fast==='pipe-png'",render)
        self.assertIn('yuv420p10le',frame)
        self.assertIn('require_stream_bit_depth(partial_path, 10)',x265)


if __name__ == '__main__':
    unittest.main()
