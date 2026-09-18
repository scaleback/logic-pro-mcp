"""Tests del escritor de presets de AmpliTube (FASE A del plan).

Corren sobre presets SINTÉTICOS con la misma estructura que los de fábrica —
no se redistribuyen archivos de IK, y los tests no dependen del disco de Edgar.

    python3 -m unittest discover -s Scripts/amplitube -v
"""

import json
import plistlib
import shutil
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import amplitube as at  # noqa: E402

EMPTY = at.EMPTY_SLOT
AMP_ONE = "aaaaaaaa-0000-0000-0000-000000000001"
AMP_TWO = "aaaaaaaa-0000-0000-0000-000000000002"
AMP_THREE = "aaaaaaaa-0000-0000-0000-000000000003"
OVERDRIVE = "bbbbbbbb-0000-0000-0000-000000000001"
COMP = "bbbbbbbb-0000-0000-0000-000000000002"
DELAY = "cccccccc-0000-0000-0000-000000000001"


def preset_xml(amp_guid, amp_suffix, gain, stomp0, slot0, rack0, rack_slot0, midi="", mic_distance="0"):
    empty_slots = "".join(f'<Slot{i} />' for i in range(1, 6))
    empty_refs = " ".join(f'Stomp{i}="{EMPTY}"' for i in range(1, 6))
    return f"""<?xml version="1.0" ?>
<Preset Version="1" Format="at5p" GUID="11111111-1111-1111-1111-111111111111" PresetBPM="120" ProgramChange="-1">
    <Chain Preset="Chain11" MonoChainDualCab="0" DIBeforeAmp="0" />
    <StompA1 Bypass="0" Mute="0" OutputVolume="1" Stomp0="{stomp0}" {empty_refs}>
        {slot0}{empty_slots}
    </StompA1>
    <AmpA Bypass="0" Mute="0" OutputVolume="1" Model="{amp_guid}">
        <Amp Gain_{amp_suffix}="{gain}" Bass_{amp_suffix}="5" Switch_{amp_suffix}="LEFT" />
    </AmpA>
    <CabA Bypass="0" Mute="0" CabModel="dddddddd-0000-0000-0000-000000000001" SpeakerModel0="e1">
        <Cab Mic0Distance="{mic_distance}" Mic0Level="-6" RoomType="Hall" />
    </CabA>
    <RackA Bypass="0" Mute="0" OutputVolume="1" Stomp0="{rack0}" {empty_refs}>
        {rack_slot0}{empty_slots}
    </RackA>
    <MidiAssignments>{midi}</MidiAssignments>
    <MetaInfo Description="" Style="Rock" SoundCharacter="Crunch" Instrument="None" />
</Preset>
"""


class Fixture:
    def __init__(self):
        self.dir = Path(tempfile.mkdtemp())
        self.root = self.dir / "Presets"
        (self.root / "Fabrica").mkdir(parents=True)
        (self.root / "Fabrica" / "Base.at5p").write_text(preset_xml(
            AMP_ONE, "AmpOne", "6",
            OVERDRIVE, '<Slot0 Bypass="0" Drive="5" Tone="4" />',
            DELAY, '<Slot0 Bypass="0" Time="300" Mix="20" />',
            midi=f'<Assignment0 ControlName="Overdrive X - Bypass" GUID="{OVERDRIVE}" '
                 f'ChainSlot="StompA1" ChainSubSlot="0" MessageType="CC" Number="20" Parameter="Bypass" />',
        ))
        (self.root / "Fabrica" / "Otro.at5p").write_text(preset_xml(
            AMP_TWO, "AmpTwo", "3",
            COMP, '<Slot0 Bypass="1" Comp="35" Level="0.5" />',
            DELAY, '<Slot0 Bypass="0" Time="500" Mix="40" />',
        ))
        # A second use of AmpOne and the overdrive, so ranges exist to test
        # against (a single observation makes every change "out of range").
        (self.root / "Fabrica" / "Tercero.at5p").write_text(preset_xml(
            AMP_ONE, "AmpOne", "2",
            OVERDRIVE, '<Slot0 Bypass="0" Drive="8" Tone="4" />',
            DELAY, '<Slot0 Bypass="0" Time="300" Mix="20" />',
            mic_distance="0.5",
        ))
        # Claude's own output must never shape the vocabulary.
        (self.root / at.CLAUDE_DIR).mkdir()
        (self.root / at.CLAUDE_DIR / "Mio.at5p").write_text(preset_xml(
            AMP_ONE, "AmpOne", "99",
            OVERDRIVE, '<Slot0 Bypass="0" Drive="99" Tone="4" />',
            DELAY, '<Slot0 Bypass="0" Time="9999" Mix="20" />',
        ))
        self.vocab = at.build_vocab(self.root, confirmed_file=None, license_plist=None)

    def clone(self, *args, **kwargs):
        return at.clone_preset(self.root, self.vocab, *args, **kwargs)

    def cleanup(self):
        shutil.rmtree(self.dir)


class VocabTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()

    def tearDown(self):
        self.f.cleanup()

    def test_claude_folder_is_excluded(self):
        self.assertEqual(self.f.vocab["presets_read"], 3)
        gain = self.f.vocab["models"][AMP_ONE]["params"]["Gain_AmpOne"]
        self.assertEqual((gain["min"], gain["max"]), (2.0, 6.0))     # Claude's 99 not counted
        delay_time = self.f.vocab["models"][DELAY]["params"]["Time"]
        self.assertEqual((delay_time["min"], delay_time["max"]), (300.0, 500.0))

    def test_amp_internal_name_comes_from_the_param_suffix(self):
        self.assertEqual(self.f.vocab["models"][AMP_ONE]["internal_name"], "AmpOne")
        self.assertEqual(self.f.vocab["models"][AMP_ONE]["kind"], "ampli")

    def test_effects_have_no_internal_name_but_get_midi_display_names(self):
        od = self.f.vocab["models"][OVERDRIVE]
        self.assertEqual(od["kind"], "efecto")
        self.assertIsNone(od["internal_name"])
        self.assertEqual(od["display_name"], "Overdrive X")
        self.assertIn("IK", od["display_source"])

    def test_confirmed_names_win_and_carry_their_source(self):
        names = self.f.dir / "confirmados.json"
        names.write_text(json.dumps({AMP_ONE: {"display_name": "Plexi Mini", "fuente": "prueba"}}))
        vocab = at.build_vocab(self.f.root, confirmed_file=names, license_plist=None)
        self.assertEqual(vocab["models"][AMP_ONE]["display_name"], "Plexi Mini")
        self.assertEqual(vocab["models"][AMP_ONE]["display_source"], "prueba")

    def test_license_status_is_only_what_edgar_confirmed(self):
        names = self.f.dir / "confirmados.json"
        names.write_text(json.dumps({DELAY: {"display_name": "Eco", "fuente": "x", "tiene_edgar": False}}))
        vocab = at.build_vocab(self.f.root, confirmed_file=names, license_plist=None)
        self.assertIs(vocab["models"][DELAY]["owned"], False)
        self.assertIsNone(vocab["models"][COMP]["owned"])          # unknown stays unknown
        self.assertEqual(at.lock(vocab["models"][DELAY]), " [candado]")
        self.assertEqual(at.lock(vocab["models"][COMP]), "")

    def test_bypass_is_an_enum_not_a_range(self):
        bypass = self.f.vocab["models"][COMP]["params"]["Bypass"]
        self.assertEqual(bypass, {"type": "enum", "values": ["0", "1"], "seen": 1})

    def test_a_knob_seen_at_one_integer_value_is_still_a_range(self):
        # Regression: the first classifier made this an enum that accepted only "35".
        comp = self.f.vocab["models"][COMP]["params"]["Comp"]
        self.assertEqual(comp["type"], "num")

    def test_reference_attributes_are_not_offered_as_block_params(self):
        self.assertNotIn("Model", self.f.vocab["blocks"]["AmpA"])
        self.assertNotIn("Stomp0", self.f.vocab["blocks"]["StompA1"])
        self.assertIn("Mic0Distance", self.f.vocab["blocks"]["CabA.Cab"])


class CloneTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.base = self.f.root / "Fabrica" / "Base.at5p"

    def tearDown(self):
        self.f.cleanup()

    def read(self, path):
        return ET.parse(path).getroot()

    def test_set_changes_only_the_requested_keys_and_the_guid(self):
        out, _, _, warnings = self.f.clone(
            "Base", "Nuevo", sets=["AmpA.Amp.Gain_AmpOne=4.5", "CabA.Cab.Mic0Distance=0.2"])
        self.assertEqual(warnings, [])
        diff = at.semantic_diff(self.read(self.base), self.read(out))
        self.assertEqual(sorted(p for p, _, _ in diff),
                         ["AmpA.Amp.Gain_AmpOne", "CabA.Cab.Mic0Distance", "GUID"])

    def test_output_lands_in_the_claude_folder(self):
        out, *_ = self.f.clone("Base", "Nuevo")
        self.assertEqual(out.parent, self.f.root / at.CLAUDE_DIR)
        self.assertEqual(out.name, "Nuevo.at5p")

    def test_the_new_preset_gets_a_new_guid(self):
        out, *_ = self.f.clone("Base", "Nuevo")
        self.assertNotEqual(self.read(out).get("GUID"), self.read(self.base).get("GUID"))

    def test_never_overwrites_and_leaves_the_existing_file_untouched(self):
        existing = self.f.root / at.CLAUDE_DIR / "Mio.at5p"
        before = existing.read_bytes()
        with self.assertRaises(at.AmpliTubeError):
            self.f.clone("Base", "Mio", sets=["AmpA.Amp.Gain_AmpOne=1"])
        self.assertEqual(existing.read_bytes(), before)

    def test_base_preset_is_never_modified(self):
        before = self.base.read_bytes()
        self.f.clone("Base", "Nuevo", sets=["AmpA.Amp.Gain_AmpOne=4.5"])
        self.assertEqual(self.base.read_bytes(), before)

    def test_unknown_path_is_an_error_and_writes_nothing(self):
        with self.assertRaises(at.AmpliTubeError):
            self.f.clone("Base", "Nuevo", sets=["AmpA.Amp.Volumen=3"])
        self.assertFalse((self.f.root / at.CLAUDE_DIR / "Nuevo.at5p").exists())

    def test_non_numeric_value_for_a_numeric_param_is_an_error(self):
        with self.assertRaises(at.AmpliTubeError):
            self.f.clone("Base", "Nuevo", sets=["RackA.Slot0.Time=largo"])

    def test_out_of_observed_range_is_a_warning_not_an_error(self):
        out, _, _, warnings = self.f.clone("Base", "Nuevo", sets=["RackA.Slot0.Time=800"])
        self.assertTrue(out.exists())
        self.assertEqual(len(warnings), 1)
        self.assertIn("fuera de lo visto", warnings[0])

    def test_enum_values_are_written_in_their_canonical_spelling(self):
        out, *_ = self.f.clone("Base", "Nuevo", sets=["AmpA.Bypass=1.0"])
        self.assertEqual(self.read(out).find("AmpA").get("Bypass"), "1")

    def test_set_refuses_model_references(self):
        with self.assertRaises(at.AmpliTubeError) as ctx:
            self.f.clone("Base", "Nuevo", sets=[f"AmpA.Model={AMP_TWO}"])
        self.assertIn("--model", str(ctx.exception))

    def test_dry_run_writes_nothing(self):
        out, _, changes, _ = self.f.clone("Base", "Nuevo", sets=["AmpA.Amp.Gain_AmpOne=2"], dry_run=True)
        self.assertFalse(out.exists())
        self.assertEqual(changes, [("AmpA.Amp.Gain_AmpOne", "6", "2")])

    def test_unchanged_clone_differs_only_in_guid(self):
        out, *_ = self.f.clone("Base", "Igual")
        diff = at.semantic_diff(self.read(self.base), self.read(out))
        self.assertEqual([p for p, _, _ in diff], ["GUID"])


class ModelSwapTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.base = self.f.root / "Fabrica" / "Base.at5p"

    def tearDown(self):
        self.f.cleanup()

    def test_amp_swap_copies_a_factory_param_block_and_keeps_the_container(self):
        out, *_ = self.f.clone("Base", "OtroAmpli", models=["AmpA=AmpTwo"])
        amp = ET.parse(out).getroot().find("AmpA")
        self.assertEqual(amp.get("Model"), AMP_TWO)
        self.assertEqual(amp.find("Amp").get("Gain_AmpTwo"), "3")
        self.assertIsNone(amp.find("Amp").get("Gain_AmpOne"))
        self.assertEqual(amp.get("Bypass"), "0")

    def test_set_after_swap_addresses_the_new_model(self):
        out, *_ = self.f.clone("Base", "X", models=["AmpA=AmpTwo"], sets=["AmpA.Amp.Gain_AmpTwo=4"])
        self.assertEqual(ET.parse(out).getroot().find("AmpA/Amp").get("Gain_AmpTwo"), "4")

    def test_effect_swap_into_a_slot(self):
        out, *_ = self.f.clone("Base", "X", models=[f"StompA1.2={COMP}"])
        stomp = ET.parse(out).getroot().find("StompA1")
        self.assertEqual(stomp.get("Stomp2"), COMP)
        self.assertEqual(stomp.find("Slot2").get("Comp"), "35")

    def test_effect_swap_keeps_slot_order(self):
        out, *_ = self.f.clone("Base", "X", models=[f"StompA1.2={COMP}"])
        tags = [c.tag for c in ET.parse(out).getroot().find("StompA1")]
        self.assertEqual(tags, [f"Slot{i}" for i in range(6)])

    def test_emptying_a_slot_also_drops_its_midi_assignment(self):
        out, _, _, notes = self.f.clone("Base", "X", models=["StompA1.0=vacio"])
        preset = ET.parse(out).getroot()
        self.assertEqual(preset.find("StompA1").get("Stomp0"), EMPTY)
        self.assertEqual(preset.find("StompA1/Slot0").attrib, {})
        self.assertEqual(len(preset.find("MidiAssignments")), 0)
        self.assertTrue(any("MIDI" in n for n in notes))

    def test_effect_is_refused_in_a_category_it_never_appeared_in(self):
        with self.assertRaises(at.AmpliTubeError) as ctx:
            self.f.clone("Base", "X", models=[f"StompA1.1={DELAY}"])     # delay only seen in Rack
        self.assertIn("adivinar", str(ctx.exception))

    def test_an_amp_cannot_go_into_an_effect_slot(self):
        with self.assertRaises(at.AmpliTubeError):
            self.f.clone("Base", "X", models=[f"StompA1.1={AMP_TWO}"])

    def test_ambiguous_or_unknown_names_are_refused(self):
        with self.assertRaises(at.AmpliTubeError):
            self.f.clone("Base", "X", models=["AmpA=NoExiste"])


class LicensePlistTests(unittest.TestCase):
    """AmpliTube's own license plist decides what Edgar owns (5/5 verified live)."""

    def setUp(self):
        self.f = Fixture()
        self.plist = self.f.dir / "licencias.plist"
        with open(self.plist, "wb") as fh:
            plistlib.dump({
                AMP_ONE: b"\x00" * 16, OVERDRIVE: b"\x01" * 16,
                "SerialNumber": "SECRETO-123", "AuthCode": "SECRETO-456", "UserSerial": "SECRETO-789",
            }, fh)

    def tearDown(self):
        self.f.cleanup()

    def vocab(self, **kw):
        return at.build_vocab(self.f.root, license_plist=self.plist, **({"confirmed_file": None} | kw))

    def test_present_means_owned_absent_means_locked(self):
        models = self.vocab()["models"]
        self.assertIs(models[AMP_ONE]["owned"], True)
        self.assertIs(models[OVERDRIVE]["owned"], True)
        self.assertIs(models[AMP_TWO]["owned"], False)
        self.assertIs(models[DELAY]["owned"], False)
        self.assertEqual(models[AMP_TWO]["owned_source"], "plist de licencias de AmpliTube")

    def test_secrets_in_the_plist_never_reach_the_vocabulary(self):
        dumped = json.dumps(self.vocab())
        for secret in ("SECRETO-123", "SECRETO-456", "SECRETO-789", "SerialNumber", "AuthCode"):
            self.assertNotIn(secret, dumped)

    def test_missing_plist_leaves_everything_unknown(self):
        vocab = at.build_vocab(self.f.root, confirmed_file=None, license_plist=self.f.dir / "no-existe.plist")
        self.assertTrue(all(m["owned"] is None for m in vocab["models"].values()))

    def test_edgars_confirmation_wins_over_the_plist(self):
        names = self.f.dir / "confirmados.json"
        names.write_text(json.dumps({AMP_ONE: {"display_name": "X", "fuente": "y", "tiene_edgar": False}}))
        model = self.vocab(confirmed_file=names)["models"][AMP_ONE]
        self.assertIs(model["owned"], False)
        self.assertEqual(model["owned_source"], "confirmado por Edgar")

    def test_index_carries_ownership_for_search_mio(self):
        index = at.build_index(self.f.root, self.vocab())
        base = next(p for p in index if p["name"] == "Base")
        self.assertIs(base["amp"]["owned"], True)
        self.assertEqual({e["label"]: e["owned"] for e in base["effects"]}[
            at.label(self.vocab()["models"][DELAY], DELAY)], False)


class MultiChannelAmpTests(unittest.TestCase):
    """Regression: the model name is the LAST underscore segment.

    Taking everything after the first underscore turned
    "Ch1_Volume_MarshallJVMSatriani" into the model "Volume_MarshallJVMSatriani"
    and left the index unable to find the amp's gain.
    """

    def test_multi_channel_amp_name_and_gain(self):
        f = Fixture()
        try:
            xml = preset_xml(AMP_THREE, "AmpThree", "7", OVERDRIVE,
                             '<Slot0 Bypass="0" Drive="5" Tone="4" />',
                             DELAY, '<Slot0 Bypass="0" Time="300" Mix="20" />')
            xml = xml.replace('<Amp Gain_AmpThree="7" Bass_AmpThree="5" Switch_AmpThree="LEFT" />',
                              '<Amp Ch1_Gain_AmpThree="7" Ch1_Volume_AmpThree="3" Presence_AmpThree="5" />')
            (f.root / "Fabrica" / "Multi.at5p").write_text(xml)
            vocab = at.build_vocab(f.root, confirmed_file=None, license_plist=None)
            self.assertEqual(vocab["models"][AMP_THREE]["internal_name"], "AmpThree")
            multi = next(p for p in at.build_index(f.root, vocab) if p["name"] == "Multi")
            self.assertEqual(multi["amp"]["gain"], "7")
        finally:
            f.cleanup()


class IndexTests(unittest.TestCase):
    def test_index_uses_amp_a_as_the_principal_amp(self):
        f = Fixture()
        try:
            index = at.build_index(f.root, f.vocab)
            self.assertEqual(len(index), 3)          # Claude/ excluded
            base = next(p for p in index if p["name"] == "Base")
            self.assertEqual(base["amp"]["label"], "AmpOne")
            self.assertEqual(base["amp"]["gain"], "6")
            self.assertEqual({e["label"] for e in base["effects"]}, {"Overdrive X", at.label(f.vocab["models"][DELAY], DELAY)})
        finally:
            f.cleanup()


if __name__ == "__main__":
    unittest.main()


class LogicExportTests(unittest.TestCase):
    """FASE D: a .at5p published as an AU preset in Logic's Setting menu."""

    PANELS = b'VC2!G\x00\x00\x00<?xml version="1.0" encoding="UTF-8"?> <Panels GearVisibilityMode="0"/>\x00'
    GUISCALE = b'VC2!\x0f\x00\x00\x00<GuiScale/>\x00'

    def setUp(self):
        self.f = Fixture()
        program = ('<?xml version="1.0" encoding="UTF-8" ?><Program Version="2" Format="at5p" GUID="x" '
                   'PresetBPM="120" ProgramChange="-1" PresetName="Viejo" PresetPath="/Users/alguien/secreto.at5p">'
                   '<Chain Preset="Chain11" /><Preferences Quality="High" /><Automation Slots="16" /></Program>')
        self.state = at.valuetree_encode(("State", [
            ("PresetData", 8, program.encode() + b"\0"),
            ("Panels", 8, self.PANELS),
            ("GuiScale", 8, self.GUISCALE),
        ], []))
        self.logic_saved = self.f.dir / "guardado-por-logic.aupreset"
        with open(self.logic_saved, "wb") as fh:
            plistlib.dump({"data": b"\x00\x01", "element-name": {"1": {"0": "Input 1"}},
                           "jucePluginState": self.state, "manufacturer": 1, "name": "Viejo",
                           "subtype": 2, "type": 3, "version": 0}, fh, fmt=plistlib.FMT_XML)
        self.template = at.make_au_template(self.logic_saved)
        self.out_root = self.f.dir / "AU"

    def tearDown(self):
        self.f.cleanup()

    def export(self, name="Tono"):
        return at.export_logic(self.f.root, self.template, "Fabrica/Base.at5p", name, out_root=self.out_root)

    def read_state(self, path):
        with open(path, "rb") as fh:
            plist = plistlib.load(fh)
        tree, end = at.valuetree_decode(plist["jucePluginState"])
        self.assertEqual(end, len(plist["jucePluginState"]))
        return plist, dict((n, p) for n, _, p in tree[1]), [n for n, _, _ in tree[1]]

    def test_valuetree_round_trip_is_byte_exact(self):
        tree, end = at.valuetree_decode(self.state)
        self.assertEqual(end, len(self.state))
        self.assertEqual(at.valuetree_encode(tree), self.state)

    def test_template_drops_the_personal_path_and_the_tone(self):
        dumped = json.dumps(self.template)
        self.assertNotIn("/Users/alguien", dumped)
        self.assertNotIn("Chain11", dumped)
        self.assertEqual(len(self.template["program_trailer_xml"]), 2)

    def test_template_refuses_a_state_that_does_not_re_encode(self):
        broken = self.f.dir / "roto.aupreset"
        with open(broken, "wb") as fh:
            plistlib.dump({"data": b"", "jucePluginState": self.state + b"\x00basura",
                           "manufacturer": 1, "subtype": 2, "type": 3}, fh)
        with self.assertRaises(at.AmpliTubeError):
            at.make_au_template(broken)

    def test_export_lands_in_claude_and_keeps_logics_ui_blobs_byte_exact(self):
        out = self.export()
        self.assertEqual(out, self.out_root / at.CLAUDE_DIR / "Tono.aupreset")
        plist, props, order = self.read_state(out)
        self.assertEqual(order, ["PresetData", "Panels", "GuiScale"])
        self.assertEqual(props["Panels"], self.PANELS)
        self.assertEqual(props["GuiScale"], self.GUISCALE)
        self.assertEqual(plist["name"], "Tono")
        self.assertEqual(plist["data"], b"\x00\x01")

    def test_program_carries_the_tone_as_version_2_without_metainfo(self):
        _, props, _ = self.read_state(self.export())
        raw = props["PresetData"]
        self.assertTrue(raw.endswith(b"\0"))
        self.assertNotIn(b"\n", raw)                          # one line, like AmpliTube writes it
        program = ET.fromstring(raw.rstrip(b"\0").decode())
        self.assertEqual((program.tag, program.get("Version")), ("Program", "2"))
        self.assertEqual(program.get("PresetName"), "Tono")
        self.assertIsNone(program.get("PresetPath"))
        self.assertIsNone(program.find("MetaInfo"))
        self.assertEqual(program.find("AmpA/Amp").get("Gain_AmpOne"), "6")   # the tone came from Base
        self.assertEqual([c.tag for c in program][-2:], ["Preferences", "Automation"])

    def test_export_never_overwrites(self):
        out = self.export()
        before = out.read_bytes()
        with self.assertRaises(at.AmpliTubeError):
            self.export()
        self.assertEqual(out.read_bytes(), before)
