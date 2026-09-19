"""Tests de la herramienta de presets de plugins de Logic (FASE E del plan).

Usan los MAPAS reales (así también se valida su forma) con archivos .pst
sintéticos: no dependen del disco de Edgar.

    python3 -m unittest discover -s Scripts/logic_presets -v
"""

import json
import shutil
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import logic_presets as lp  # noqa: E402


def pst(plugin_id: int, values: list[float], tail: bytes = b"") -> bytes:
    body = struct.pack("<" + "f" * len(values), *values)
    size = lp.HEADER + len(body) + len(tail)
    return struct.pack("<III", size, 1, len(values)) + lp.MAGIC + struct.pack("<I", plugin_id) + body + tail


class Fixture:
    def __init__(self):
        self.dir = Path(tempfile.mkdtemp())
        self.root = self.dir / "Plug-In Settings"
        comp = [0.0] * 31
        comp[1], comp[2], comp[25] = -20.0, 2.1, 100.0
        self.write("Compressor", "Base", pst(154, comp))
        eq = [0.0] * 52
        eq[2], eq[6], eq[33] = 20.0, 75.0, 0.0
        self.eq_tail = b"\x12\x34\x56\x78\x08\x00\x00\x00"
        self.write("Channel EQ", "Base", pst(236, eq, self.eq_tail))
        self.write("ChromaVerb", "Base", pst(287, [0.0] * 81))

    def write(self, plugin, name, blob):
        folder = self.root / plugin
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"{name}.pst").write_bytes(blob)

    def clone(self, plugin, name="Nuevo", sets=(), **kw):
        kw.setdefault("factory_root", None)          # hermetic: never the real Logic app
        return lp.clone(self.root, plugin, "Base", name, list(sets), **kw)

    def cleanup(self):
        shutil.rmtree(self.dir)


class FormatTests(unittest.TestCase):
    def test_round_trip_with_and_without_tail(self):
        for blob in (pst(154, [1.5] * 31), pst(236, [0.25] * 52, b"\x01\x02\x03\x04\x05\x06\x07\x08")):
            self.assertEqual(lp.encode(lp.parse(blob)), blob)

    def test_rejects_a_file_without_the_magic(self):
        with self.assertRaises(lp.PresetError):
            lp.parse(b"\x00" * 40)

    def test_rejects_an_inconsistent_header(self):
        blob = bytearray(pst(154, [0.0] * 31))
        blob[0:4] = struct.pack("<I", 999)
        with self.assertRaises(lp.PresetError):
            lp.parse(bytes(blob))


class MapTests(unittest.TestCase):
    def test_every_map_is_well_formed(self):
        for path in lp.MAPS_DIR.glob("*.json"):
            m = json.loads(path.read_text(encoding="utf-8"))
            indices = [p["index"] for p in m["params"].values()]
            self.assertEqual(len(indices), len(set(indices)), f"{path.name}: índices repetidos")
            self.assertTrue(all(0 <= i < m["param_count"] for i in indices), path.name)
            for key, p in m["params"].items():
                self.assertIn(p["evidence"], {"censo", "default_unico", "inferido"}, f"{path.name}:{key}")


class CloneTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()

    def tearDown(self):
        self.f.cleanup()

    def read(self, path):
        return lp.parse(path.read_bytes())

    def test_changes_only_the_requested_index(self):
        out, changes, _ = self.f.clone("Compressor", sets=["threshold=-31.5"])
        base = self.read(self.f.root / "Compressor" / "Base.pst")["values"]
        new = self.read(out)["values"]
        self.assertEqual([i for i, (a, b) in enumerate(zip(base, new)) if a != b], [1])
        self.assertEqual(new[1], -31.5)
        self.assertEqual(changes, [("threshold", 1, -20.0, -31.5)])

    def test_output_lands_in_the_claude_subfolder(self):
        out, _, _ = self.f.clone("Compressor")
        self.assertEqual(out, self.f.root / "Compressor" / "Claude" / "Nuevo.pst")

    def test_the_channel_eq_tail_survives_byte_for_byte(self):
        out, _, _ = self.f.clone("Channel EQ", sets=["peak3_gain=-5.5", "gain=1.3"])
        self.assertEqual(self.read(out)["tail"], self.f.eq_tail)

    def test_never_overwrites(self):
        out, _, _ = self.f.clone("Compressor")
        before = out.read_bytes()
        with self.assertRaises(lp.PresetError):
            self.f.clone("Compressor", sets=["ratio=8"])
        self.assertEqual(out.read_bytes(), before)

    def test_refuses_an_inferred_parameter(self):
        with self.assertRaises(lp.PresetError) as ctx:
            self.f.clone("Channel EQ", sets=["hpf_on=1"])
        self.assertIn("deducido", str(ctx.exception))
        self.assertFalse((self.f.root / "Channel EQ" / "Claude" / "Nuevo.pst").exists())

    def test_refuses_a_preset_of_another_plugin(self):
        self.f.write("Compressor", "Impostor", pst(287, [0.0] * 31))     # ChromaVerb id, Compressor folder
        with self.assertRaises(lp.PresetError) as ctx:
            lp.clone(self.f.root, "Compressor", "Impostor", "X", ["ratio=4"])
        self.assertIn("287", str(ctx.exception))

    def test_refuses_a_different_parameter_count(self):
        self.f.write("Compressor", "Otra", pst(154, [0.0] * 30))
        with self.assertRaises(lp.PresetError):
            lp.clone(self.f.root, "Compressor", "Otra", "X", ["ratio=4"])

    def test_enum_by_label_and_screen_order_warning(self):
        out, _, warnings = self.f.clone("Compressor", sets=["circuito=Vintage Opto"])
        self.assertEqual(self.read(out)["values"][10], 6.0)
        self.assertEqual(warnings, [])
        _, _, warnings = self.f.clone("Compressor", name="Otro", sets=["circuito=Vintage FET"])
        self.assertEqual(len(warnings), 1)
        self.assertIn("ORDEN en pantalla", warnings[0])

    def test_unknown_parameter_lists_what_is_mapped(self):
        with self.assertRaises(lp.PresetError) as ctx:
            self.f.clone("ChromaVerb", sets=["reverb_mágico=3"])
        self.assertIn("decay", str(ctx.exception))

    def test_non_numeric_value_is_refused(self):
        with self.assertRaises(lp.PresetError):
            self.f.clone("ChromaVerb", sets=["decay=largo"])

    def test_a_factory_preset_is_a_valid_base_and_the_clone_lands_in_claude(self):
        factory = self.f.dir / "Factory"
        (factory / "ChromaVerb" / "Chambers").mkdir(parents=True)
        values = [0.0] * 81
        values[6] = 2.5
        (factory / "ChromaVerb" / "Chambers" / "Guitar Chamber.pst").write_bytes(pst(287, values))
        for ref in ("Guitar Chamber", "Chambers/Guitar Chamber"):
            out, changes, _ = lp.clone(self.f.root, "ChromaVerb", ref, f"Larga {len(ref)}",
                                       ["decay=4"], factory_root=factory)
            self.assertEqual(out.parent, self.f.root / "ChromaVerb" / "Claude")
            self.assertEqual(changes, [("decay", 6, 2.5, 4.0)])
        self.assertEqual(len(list((factory / "ChromaVerb").rglob("*.pst"))), 1)   # factory untouched

    def test_dry_run_writes_nothing(self):
        out, changes, _ = self.f.clone("ChromaVerb", sets=["decay=3.5"], dry_run=True)
        self.assertFalse(out.exists())
        self.assertEqual(changes[0][:2], ("decay", 6))


if __name__ == "__main__":
    unittest.main()
