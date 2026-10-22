import struct
import unittest
from pathlib import Path


ICON_PATH = Path(__file__).resolve().parents[1] / "resources" / "claude-tray-windows.ico"
SIZES = {16, 20, 24, 32, 40, 48, 64, 128, 256}


class WindowsTrayIconTests(unittest.TestCase):
    def test_all_sizes_have_orange_background_white_mark_and_transparency(self):
        data = ICON_PATH.read_bytes()
        reserved, kind, count = struct.unpack_from("<HHH", data)
        self.assertEqual((reserved, kind, count), (0, 1, len(SIZES)))
        sizes = set()
        previous_end = 6 + 16 * count
        for index in range(count):
            width, height, _, _, _, depth, length, offset = struct.unpack_from(
                "<BBBBHHII", data, 6 + 16 * index
            )
            width, height = width or 256, height or 256
            with self.subTest(size=width):
                self.assertEqual(width, height)
                self.assertEqual(depth, 32)
                self.assertGreaterEqual(offset, previous_end)
                self.assertLessEqual(offset + length, len(data))
                header, dib_width, dib_height, planes, bpp, compression = struct.unpack_from(
                    "<IiiHHI", data, offset
                )
                self.assertEqual((header, dib_width, dib_height), (40, width, height * 2))
                self.assertEqual((planes, bpp, compression), (1, 32, 0))
                self.assertGreaterEqual(length, header + width * height * 4)
                pixels = list(struct.iter_unpack(
                    "<BBBB", data[offset + header:offset + header + width * height * 4]
                ))
                orange = sum(a > 128 and r > 170 and 60 < g < 180 and b < 160 for b, g, r, a in pixels)
                white = sum(a > 128 and r > 220 and g > 210 and b > 180 for b, g, r, a in pixels)
                self.assertGreater(orange, width * height * 0.4)
                self.assertGreater(white, width * height * 0.05)
                self.assertLess(pixels[0][3], 65)
                sizes.add(width)
                previous_end = offset + length
        self.assertEqual(sizes, SIZES)
        self.assertEqual(previous_end, len(data))


if __name__ == "__main__":
    unittest.main()
