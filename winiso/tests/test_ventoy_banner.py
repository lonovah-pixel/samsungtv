"""Тесты ventoy_banner.py на временных папках (без физических носителей).
Запуск: python3 -m unittest discover -s tests -p 'test_*.py'
"""
import hashlib
import json
import shutil
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ventoy"))
import ventoy_banner as vb  # noqa: E402


def write_png(path: Path, w=1024, h=768, ctype=2, interlace=0, rgb=(10, 20, 30)):
    """Минимальный PNG без сторонних библиотек."""
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    bpp = 3 if ctype == 2 else 4
    px = bytes(rgb) + (b"\xff" if bpp == 4 else b"")
    raw = b"".join(b"\x00" + px * w for _ in range(h))
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, interlace))
    data += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    path.write_bytes(data)
    return path


def tree_digest(root: Path):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}


class VentoyBannerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / "usb"
        (self.root / "ventoy").mkdir(parents=True)
        (self.root / "iso").mkdir()
        (self.root / "iso" / "a.iso").write_bytes(b"x" * 100)
        self.banner = write_png(self.tmp / "banner.png")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_png_validation(self):
        self.assertEqual(vb.png_info(self.banner)["problems"], [])
        bad = write_png(self.tmp / "inter.png", w=8, h=8, interlace=1)
        self.assertTrue(vb.png_info(bad)["problems"])
        notpng = self.tmp / "x.png"
        notpng.write_text("not a png")
        with self.assertRaises(vb.Fail):
            vb.png_info(notpng)

    def test_new_theme_preserves_other_keys_and_rolls_back(self):
        vj = self.root / "ventoy" / "ventoy.json"
        original = {"control": [{"VTOY_MENU_TIMEOUT": "10"}], "menu_alias": [{"image": "/iso/a.iso", "alias": "Альфа"}]}
        vj.write_text(json.dumps(original, ensure_ascii=False), encoding="utf-8")
        before = tree_digest(self.root)
        res = vb.inspect(self.root)
        self.assertEqual(res["mode"], "new-theme")
        plan = vb.build_plan(res, self.banner, "auto")
        bdir = vb.apply(self.root, plan, None)
        after = json.loads(vj.read_text(encoding="utf-8"))
        self.assertEqual({k: v for k, v in after.items() if k != "theme"}, original)
        self.assertEqual(after["theme"]["file"], "/ventoy/themes/winiso/theme.txt")
        self.assertEqual(after["theme"].get("ventoy_color"), None if vb.bottom_is_dark(self.banner) is None else "#9ec5ff")
        self.assertTrue((self.root / "ventoy/themes/winiso/background.png").is_file())
        # повторный inspect видит нашу тему как существующую
        self.assertEqual(vb.inspect(self.root)["mode"], "replace-existing")
        vb.rollback(self.root, bdir.name)
        restored = tree_digest(self.root)
        restored = {k: v for k, v in restored.items() if not k.startswith(vb.BACKUP_DIR_REL)}
        self.assertEqual(restored, before)
        self.assertFalse((self.root / "ventoy/themes").exists())

    def test_replace_existing_theme_only_touches_desktop_image(self):
        tdir = self.root / "ventoy" / "mytheme"
        tdir.mkdir()
        (tdir / "theme.txt").write_text('desktop-image: "bg.png"\n+ boot_menu { left = 10% }\n', encoding="utf-8")
        write_png(tdir / "bg.png", w=1920, h=1080, rgb=(200, 200, 200))
        (tdir / "other.png").write_bytes(b"keep")
        vj = self.root / "ventoy" / "ventoy.json"
        vj.write_text('{"theme": {"file": "/ventoy/mytheme/theme.txt", "gfxmode": "1920x1080"}}', encoding="utf-8")
        before = tree_digest(self.root)
        res = vb.inspect(self.root)
        self.assertEqual(res["mode"], "replace-existing")
        plan = vb.build_plan(res, self.banner)
        self.assertEqual([w["dst"].name for w in plan["writes"]], ["bg.png"])
        self.assertIsNone(plan["json_change"])
        self.assertTrue(any("1920x1080" in n for n in plan["notes"]))
        bdir = vb.apply(self.root, plan, None)
        changed = {k for k, v in tree_digest(self.root).items() if before.get(k) != v and not k.startswith(vb.BACKUP_DIR_REL)}
        self.assertEqual(changed, {"ventoy/mytheme/bg.png"})
        vb.rollback(self.root, bdir.name)
        self.assertEqual({k: v for k, v in tree_digest(self.root).items() if not k.startswith(vb.BACKUP_DIR_REL)}, before)

    def test_relative_theme_path_resolution(self):
        self.assertEqual(vb.resolve_theme_path(self.root, "t/theme.txt"), self.root / "ventoy" / "t" / "theme.txt")
        self.assertEqual(vb.resolve_theme_path(self.root, "/x/theme.txt"), self.root / "x" / "theme.txt")

    def test_invalid_json_is_not_touched(self):
        vj = self.root / "ventoy" / "ventoy.json"
        vj.write_text('{"control": [ }', encoding="utf-8")
        with self.assertRaises(vb.Fail):
            vb.inspect(self.root)
        self.assertEqual(vj.read_text(encoding="utf-8"), '{"control": [ }')

    def test_broken_theme_reference_stops(self):
        (self.root / "ventoy" / "ventoy.json").write_text('{"theme": {"file": "/nope/theme.txt"}}', encoding="utf-8")
        res = vb.inspect(self.root)
        self.assertEqual(res["mode"], "broken-theme")
        with self.assertRaises(vb.Fail):
            vb.build_plan(res, self.banner)

    def test_bad_banner_rejected(self):
        bad = write_png(self.tmp / "pal.png", w=4, h=4, ctype=6, interlace=1)
        with self.assertRaises(vb.Fail):
            vb.build_plan(vb.inspect(self.root), bad)

    def test_stage_folder(self):
        out = self.tmp / "stage"
        vb.stage(out, self.banner, "default")
        self.assertTrue((out / "usb-root/ventoy/themes/winiso/theme.txt").is_file())
        self.assertTrue((out / "INSTRUCTIONS.md").is_file())
        snippet = json.loads((out / "ventoy.json.theme-snippet.json").read_text(encoding="utf-8"))
        self.assertEqual(snippet, {"theme": {"file": "/ventoy/themes/winiso/theme.txt"}})

    def test_base_theme_integrity(self):
        sums = (vb.BASE_THEME / "SHA256SUMS").read_text().split("\n")
        for line in filter(None, sums):
            h, name = line.split()
            self.assertEqual(hashlib.sha256((vb.BASE_THEME / name).read_bytes()).hexdigest(), h, name)


if __name__ == "__main__":
    unittest.main()
