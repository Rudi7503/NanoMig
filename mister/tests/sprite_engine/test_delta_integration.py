"""End-to-end regressions for the formats introduced in dbfd692."""
import unittest
import numpy as np
import sprite_ref_model as m
import build_spacecraft_test as b


class DeltaIntegration(unittest.TestCase):
    def render(self, fmt, words, skip=True):
        desc = m.SpriteDescriptor(0, 0, 0x1000, 1, len(words)//4, fmt, 195, 255, 0)
        return m.render_scanline(0, [desc], {0x1000+i*8:w for i,w in enumerate(words)},
                                 [0]*256, clip_xmax=128, zero_word_skip_en=skip)

    def test_new_formats_draw_and_reserved_formats_do_not(self):
        for fmt in (17,18,19):
            words=[0xffffffffffffffff]*4
            self.assertTrue(any(self.render(fmt,words)),fmt)
            self.assertEqual(self.render(fmt,words),self.render(fmt,words,False))
        for fmt in range(20,256):
            self.assertFalse(any(self.render(fmt,[0xffffffffffffffff]*4)),fmt)

    def test_encoder_uses_low_half_delta_codes_without_palette_anchors(self):
        # 8-bit delta code 1 is the best choice from black for black:
        # all channels clamp to zero. A white palette must never affect it.
        rgb=np.zeros((1,3),dtype=np.uint8)
        words=b.encode_ham_row_fmt(rgb,np.ones(1,dtype=bool),19,[0xffffff]*256,0)
        self.assertEqual(words[0]>>56,1)

    def test_encoder_is_palette_independent_and_preserves_gaps(self):
        rng=np.random.default_rng(17)
        rgb=rng.integers(0,256,(83,3),dtype=np.uint8)
        opaque=np.ones(83,dtype=bool);opaque[25:50]=False
        for fmt in (17,18,19):
            words=b.encode_ham_row_fmt(rgb,opaque,fmt,[0]*256,0)
            self.assertEqual(words,b.encode_ham_row_fmt(rgb,opaque,fmt,[0xffffff]*256,0))
            line=self.render(fmt,words)
            self.assertTrue(any(line[:25]))
            self.assertEqual(line[25:50],[0]*25)
            self.assertEqual(line[83:],[0]*45)
            self.assertEqual(line,self.render(fmt,words,False))

    def test_showcase_includes_delta_formats(self):
        self.assertTrue({17,18,19}.issubset(b.SHOWCASE_FORMATS))


if __name__ == '__main__':
    unittest.main()
