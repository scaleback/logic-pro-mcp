#!/usr/bin/env python3
"""Herramientas para presets de AmpliTube 5 (.at5p). Sin dependencias.

Uso típico, desde una sesión de Claude o una terminal:

    python3 amplitube.py search --ampli rectifier --caracter Hi-Gain
    python3 amplitube.py models --tipo efecto --buscar delay
    python3 amplitube.py show "80's"
    python3 amplitube.py clone "80's" --name "Mi tono" \\
        --set AmpA.Amp.Gain_AmpFriedman=7.5 \\
        --model StompA1.1=OCD

Rutas de parámetro para --set (las lista `show`):
    AmpA.Bypass                      atributo del bloque
    AmpA.Amp.Gain_AmpFriedman        parámetro del ampli en AmpA
    StompA1.Slot0.Drive              parámetro del pedal en el slot 0 de StompA1
    CabA.Cab.Mic0Distance            colocación del micrófono

Reglas que el código hace cumplir (PLAN_PLUGINS_Y_PRESETS.md, FASE A):
  - Solo LEE los presets de fábrica y los de Edgar.
  - Solo ESCRIBE archivos nuevos en <Presets>/Claude/, y nunca sobrescribe.
  - El vocabulario se construye EXCLUYENDO Claude/, para que lo que Claude
    escribe no contamine los rangos "observados".

Mantenimiento:
    python3 amplitube.py vocab     # reconstruye vocabulario.json
    python3 amplitube.py index     # reconstruye presets-indice.json
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
import uuid
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = Path.home() / "Documents" / "IK Multimedia" / "AmpliTube 5" / "Presets"
VOCAB_FILE = HERE / "vocabulario.json"
INDEX_FILE = HERE / "presets-indice.json"
CONFIRMED_FILE = HERE / "nombres-confirmados.json"
# AmpliTube keeps one entry per licensed piece of gear here, keyed by the gear's
# GUID. Verified 2026-09-18 against Edgar's own screens, 5 of 5: the three
# delays he owns are keys, the two he saw with a lock (DDelay, MiniPlex 20) are
# not. The file ALSO holds SerialNumber, UserSerial and AuthCode: only
# GUID-shaped keys are ever read, and no value is read at all.
LICENSE_PLIST = Path.home() / "Library" / "Preferences" / "com.ikmultimedia.AmpliTube 5.plist"
GUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

CLAUDE_DIR = "Claude"
# Verified 2026-09-18 over the 776 factory presets: this GUID fills every empty
# slot and never carries a single parameter.
EMPTY_SLOT = "773b8ea7-b54a-4a3c-99df-ffbbf6d29271"
EMPTY_WORDS = {"vacio", "vacío", "ninguno", "none", "empty"}

AMP_CONTAINERS = ("AmpA", "AmpB", "AmpC")
SLOT_CONTAINERS = (
    "StompA1", "StompA2", "StompB1", "StompB2", "StompB3", "StompStereo",
    "LoopFxA", "LoopFxB", "LoopFxC",
    "RackA", "RackB", "RackC", "RackDI", "RackMaster",
)
SLOTS_PER_CONTAINER = 6
NOT_TONE = ("MidiAssignments", "MetaInfo")
# Attributes that reference a gear model by GUID. Changing one without the
# matching parameter block leaves the preset pointing at gear whose parameters
# it does not carry, so `set` refuses them; amps and effects change through
# `--model`, which copies a known-good block from a factory preset.
REF_ATTR = re.compile(r"^(Model|Stomp\d|CabModel|SpeakerModel\d|TunerType|Mic\dModel)$")
# On/off switches. `DI_PhaseDelay` ends in "Delay", so it stays a number.
BOOLEAN_ATTR = re.compile(r"(Bypass|Mute|Solo|Phase)$")


def licensed_guids(path: Path | None) -> set[str] | None:
    """GUIDs of the gear AmpliTube has a license for, or None if unknowable.

    Absent file → None, so every gear stays "unknown" rather than "locked".
    """
    if path is None or not path.exists():
        return None
    import plistlib
    with open(path, "rb") as fh:
        keys = plistlib.load(fh).keys()
    return {k for k in keys if GUID_RE.fullmatch(k)}


class AmpliTubeError(Exception):
    """A refusal whose message is meant for the person running the tool."""


# --------------------------------------------------------------------------
# Reading
# --------------------------------------------------------------------------

def category(tag: str) -> str:
    """StompA1 → Stomp, RackB → Rack, LoopFxC → LoopFx; the odd ones stay whole."""
    if tag in ("StompStereo", "RackDI", "RackMaster"):
        return tag
    return re.sub(r"[ABC]?\d*$", "", tag)


def iter_presets(root: Path):
    """Every factory/user preset under `root`, skipping Claude's own output."""
    for path in sorted(root.rglob("*.at5p")):
        if CLAUDE_DIR in path.relative_to(root).parts:
            continue
        try:
            yield path, ET.parse(path).getroot()
        except ET.ParseError:
            continue


def classify(name: str, values: list[str]) -> dict:
    """Summarise every value observed for one parameter.

    Booleans are recognised by NAME, not by how few values were seen. An
    earlier version called anything with a handful of integer values an enum,
    which turned a Gain knob observed only at "6" into a parameter that accepts
    nothing but 6 — rarely used gear has tiny samples, so the rule misfired
    exactly where the vocabulary is thinnest. A bypass is a boolean by
    definition; a knob seen at few values is still a knob.
    """
    distinct = set(values)
    try:
        numbers = [float(v) for v in values]
    except ValueError:
        return {"type": "enum", "values": sorted(distinct), "seen": len(values)}
    if BOOLEAN_ATTR.search(name) and distinct <= {"0", "1"}:
        return {"type": "enum", "values": ["0", "1"], "seen": len(values)}
    return {"type": "num", "min": min(numbers), "max": max(numbers), "seen": len(values)}


def lock(model: dict) -> str:
    """How Edgar's license status reads next to a gear name."""
    return {False: " [candado]", True: " [lo tiene]"}.get(model.get("owned"), "")


def label(model: dict, guid: str) -> str:
    if model.get("display_name"):
        return model["display_name"]
    if model.get("internal_name"):
        return model["internal_name"]
    keys = ", ".join(sorted(k for k in model["params"] if k != "Bypass")[:4])
    return f"{model['kind']} {guid[:8]} ({keys})"


def build_vocab(root: Path, confirmed_file: Path | None = CONFIRMED_FILE,
                license_plist: Path | None = LICENSE_PLIST) -> dict:
    values: dict = defaultdict(lambda: defaultdict(list))
    blocks: dict = defaultdict(lambda: defaultdict(list))
    meta: dict[str, dict] = {}
    midi_names: dict = defaultdict(Counter)
    read = 0

    def note(guid: str, kind: str, tag: str, rel: str, slot: int | None = None) -> dict:
        m = meta.setdefault(guid, {"kind": kind, "names": Counter(), "tags": set(),
                                   "uses": 0, "example": None})
        m["uses"] += 1
        m["tags"].add(tag)
        if m["example"] is None:
            m["example"] = {"preset": rel, "container": tag}
            if slot is not None:
                m["example"]["slot"] = slot
        return m

    for path, preset in iter_presets(root):
        read += 1
        rel = path.relative_to(root).as_posix()
        for node in preset:
            tag = node.tag
            if tag == "MidiAssignments":
                # IK writes "<gear display name> - <parameter>" here: the only
                # display names that ship in plain text.
                for a in node:
                    name, guid = a.get("ControlName"), a.get("GUID")
                    if name and guid and " - " in name:
                        midi_names[guid][name.rsplit(" - ", 1)[0].strip()] += 1
                continue
            if tag in NOT_TONE:
                continue
            for k, v in node.attrib.items():
                blocks[tag][k].append(v)
            if tag in AMP_CONTAINERS:
                guid, amp = node.get("Model"), node.find("Amp")
                if guid and amp is not None:
                    m = note(guid, "ampli", tag, rel)
                    for k, v in amp.attrib.items():
                        values[guid][k].append(v)
                        if "_" in k:
                            # The model is the LAST segment: multi-channel amps
                            # name knobs "Ch1_Volume_MarshallJVMSatriani".
                            m["names"][k.rsplit("_", 1)[1]] += 1
            elif tag in SLOT_CONTAINERS:
                for i in range(SLOTS_PER_CONTAINER):
                    guid, slot = node.get(f"Stomp{i}"), node.find(f"Slot{i}")
                    if not guid or guid == EMPTY_SLOT or slot is None:
                        continue
                    note(guid, "efecto", tag, rel, i)
                    for k, v in slot.attrib.items():
                        values[guid][k].append(v)
            else:
                for child in node:
                    for k, v in child.attrib.items():
                        blocks[f"{tag}.{child.tag}"][k].append(v)

    confirmed = {}
    if confirmed_file is not None and confirmed_file.exists():
        confirmed = json.loads(confirmed_file.read_text(encoding="utf-8"))

    licensed = licensed_guids(license_plist)
    models = {}
    for guid, m in meta.items():
        entry = {
            "kind": m["kind"],
            "internal_name": m["names"].most_common(1)[0][0] if m["names"] else None,
            "display_name": None,
            "display_source": None,
            # True/False only when Edgar confirmed it: most factory presets use
            # gear with a lock, and a tone built on locked gear is a demo.
            "owned": None,
            "owned_source": None,
            "categories": sorted({category(t) for t in m["tags"]}),
            "uses": m["uses"],
            "example": m["example"],
            "params": {k: classify(k, v) for k, v in sorted(values[guid].items())},
        }
        if guid in confirmed:
            entry["display_name"] = confirmed[guid]["display_name"]
            entry["display_source"] = confirmed[guid]["fuente"]
            entry["owned"] = confirmed[guid].get("tiene_edgar")
            if entry["owned"] is not None:
                entry["owned_source"] = "confirmado por Edgar"
        elif guid in midi_names:
            entry["display_name"] = midi_names[guid].most_common(1)[0][0]
            entry["display_source"] = "MidiAssignments de presets de fábrica (escrito por IK)"
        # Absent from the plist counts as locked. Of 21 Custom Shop (free)
        # presets, 19 use only gear that IS in the plist, so free gear is
        # registered there too; 2 models remain unexplained. Guessing "locked"
        # wrongly costs Edgar one option; guessing "owned" wrongly hands him a
        # demo instead of a tone.
        if entry["owned"] is None and licensed is not None:
            entry["owned"] = guid in licensed
            entry["owned_source"] = "plist de licencias de AmpliTube"
        models[guid] = entry

    return {
        "schema": 1,
        "presets_read": read,
        "root": str(root),
        "empty_slot_guid": EMPTY_SLOT,
        "models": dict(sorted(models.items(),
                              key=lambda kv: (kv[1]["kind"], label(kv[1], kv[0]).lower()))),
        "blocks": {
            name: {k: classify(k, v) for k, v in sorted(attrs.items()) if not REF_ATTR.match(k)}
            for name, attrs in sorted(blocks.items())
        },
    }


def build_index(root: Path, vocab: dict) -> list[dict]:
    models = vocab["models"]

    def name_of(guid: str) -> str:
        return label(models[guid], guid) if guid in models else guid

    out = []
    for path, preset in iter_presets(root):
        info = preset.find("MetaInfo")
        chain = preset.find("Chain")
        amps = []
        for tag in AMP_CONTAINERS:
            node = preset.find(tag)
            amp = node.find("Amp") if node is not None else None
            if node is None or amp is None or not node.get("Model"):
                continue
            knobs = {k.rsplit("_", 1)[0].lower(): v for k, v in amp.attrib.items() if "_" in k}

            def knob(name: str, knobs=knobs):
                # "gain" on a one-channel amp, "ch1_gain" on a multi-channel one.
                return knobs.get(name) or next((v for kn, v in knobs.items() if kn.endswith("_" + name)), None)

            amps.append({
                "container": tag, "guid": node.get("Model"), "label": name_of(node.get("Model")),
                "owned": models.get(node.get("Model"), {}).get("owned"),
                "gain": knob("gain"), "bass": knob("bass"), "mid": knob("mid"),
                "treble": knob("treble"), "master": knob("master"),
            })
        effects = []
        for tag in SLOT_CONTAINERS:
            node = preset.find(tag)
            if node is None:
                continue
            for i in range(SLOTS_PER_CONTAINER):
                guid = node.get(f"Stomp{i}")
                if not guid or guid == EMPTY_SLOT:
                    continue
                slot = node.find(f"Slot{i}")
                effects.append({
                    "slot": f"{tag}.{i}", "guid": guid, "label": name_of(guid),
                    "owned": models.get(guid, {}).get("owned"),
                    "bypass": slot is not None and slot.get("Bypass") == "1",
                })
        cab = preset.find("CabA")
        out.append({
            "file": path.relative_to(root).as_posix(),
            "name": path.stem,
            "style": info.get("Style") if info is not None else None,
            "character": info.get("SoundCharacter") if info is not None else None,
            "chain": chain.get("Preset") if chain is not None else None,
            # AmpA is the one amp that is always in the signal path. B and C
            # are often leftovers that do not sound: in "Chain11" (585 of 776
            # factory presets) 566 carry different models there. Searching them
            # would return presets whose matching amp is silent.
            "amp": amps[0] if amps and amps[0]["container"] == "AmpA" else None,
            "other_amps_maybe_inactive": [a for a in amps if a["container"] != "AmpA"],
            "effects": effects,
            "cab_guid": cab.get("CabModel") if cab is not None else None,
        })
    return out


# --------------------------------------------------------------------------
# Resolving names and paths
# --------------------------------------------------------------------------

def load_json(path: Path, what: str):
    if not path.exists():
        raise AmpliTubeError(f"No existe {path.name}. Corre primero: amplitube.py {what}")
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_preset(root: Path, ref: str) -> Path:
    """A path (absolute or relative to root) or an exact preset name."""
    candidate = Path(ref).expanduser()
    for p in (candidate, root / ref):
        if p.is_file():
            return p
    hits = [p for p, _ in iter_presets(root) if p.stem.lower() == ref.lower()]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise AmpliTubeError(f"No encontré un preset llamado «{ref}». Usa `search` para buscarlo.")
    listing = "\n  ".join(p.relative_to(root).as_posix() for p in hits)
    raise AmpliTubeError(f"Hay {len(hits)} presets llamados «{ref}»; da la ruta:\n  {listing}")


def resolve_model(vocab: dict, ref: str, kind: str) -> str:
    """A GUID, an internal name (AmpFriedman) or a display name (OCD)."""
    models = vocab["models"]
    if ref in models:
        if models[ref]["kind"] != kind:
            raise AmpliTubeError(f"{ref} es un {models[ref]['kind']}, no un {kind}.")
        return ref
    needle = ref.lower()
    hits = [g for g, m in models.items() if m["kind"] == kind
            and needle in {(m.get("display_name") or "").lower(), (m.get("internal_name") or "").lower()}]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise AmpliTubeError(f"No conozco un {kind} llamado «{ref}». Usa `models` para ver los disponibles.")
    listing = "\n  ".join(f"{g}  {label(models[g], g)}" for g in hits)
    raise AmpliTubeError(f"«{ref}» es ambiguo; usa el GUID:\n  {listing}")


def split_path(path: str) -> tuple[str, str | None, str]:
    parts = path.split(".")
    if len(parts) == 2:
        return parts[0], None, parts[1]
    if len(parts) == 3:
        return parts[0], parts[1], parts[2]
    raise AmpliTubeError(f"Ruta «{path}» inválida: usa Bloque.Atributo o Bloque.Hijo.Atributo.")


def spec_for(vocab: dict, preset: ET.Element, container: str, child: str | None, attr: str):
    """What the vocabulary knows about one addressable parameter, or None."""
    node = preset.find(container)
    if node is None:
        return None
    if child is None:
        return vocab["blocks"].get(container, {}).get(attr)
    if container in AMP_CONTAINERS and child == "Amp":
        guid = node.get("Model")
    elif container in SLOT_CONTAINERS and re.fullmatch(r"Slot\d", child):
        guid = node.get(f"Stomp{child[4:]}")
    else:
        return vocab["blocks"].get(f"{container}.{child}", {}).get(attr)
    return vocab["models"].get(guid, {}).get("params", {}).get(attr)


def check_value(spec: dict | None, path: str, raw: str) -> tuple[str, str | None]:
    """Return the value to write and an optional warning; raise on a real error."""
    if spec is None:
        return raw, f"{path}: el vocabulario no conoce este parámetro; se escribe «{raw}» sin validar."
    if spec["type"] == "enum":
        numeric = all(re.fullmatch(r"-?\d+(\.\d+)?", v) for v in spec["values"])
        if numeric:
            try:
                wanted = float(raw)
            except ValueError:
                raise AmpliTubeError(f"{path} es numérico; «{raw}» no lo es.") from None
            for v in spec["values"]:
                if float(v) == wanted:
                    return v, None      # write the canonical spelling ("1", not "1.0")
        elif raw in spec["values"]:
            return raw, None
        return raw, f"{path}: «{raw}» nunca se vio en fábrica (vistos: {', '.join(spec['values'])})."
    try:
        number = float(raw)
    except ValueError:
        raise AmpliTubeError(f"{path} es numérico; «{raw}» no lo es.") from None
    if not spec["min"] <= number <= spec["max"]:
        return raw, (f"{path}: {raw} está fuera de lo visto en fábrica "
                     f"({spec['min']:g} a {spec['max']:g}). No es necesariamente inválido.")
    return raw, None


# --------------------------------------------------------------------------
# Editing
# --------------------------------------------------------------------------

def swap_model(root: Path, vocab: dict, preset: ET.Element, target: str, ref: str) -> list[str]:
    """Replace the gear in one amp container or effect slot.

    The new gear's parameter block is copied from a factory preset that already
    uses it, so every parameter starts from a value IK actually shipped rather
    than from a guess.
    """
    notes: list[str] = []
    if target in AMP_CONTAINERS:
        guid = resolve_model(vocab, ref, "ampli")
        node = preset.find(target)
        if node is None:
            raise AmpliTubeError(f"El preset no tiene bloque {target}.")
        example = vocab["models"][guid]["example"]
        source = ET.parse(root / example["preset"]).getroot().find(example["container"]).find("Amp")
        old = node.find("Amp")
        if old is not None:
            node.remove(old)
        node.append(copy.deepcopy(source))
        node.set("Model", guid)
        return notes

    match = re.fullmatch(r"(\w+)\.(\d)", target)
    if not match or match.group(1) not in SLOT_CONTAINERS or int(match.group(2)) >= SLOTS_PER_CONTAINER:
        raise AmpliTubeError(f"«{target}» no es un destino válido: usa AmpA/AmpB/AmpC o Bloque.N (ej. StompA1.0).")
    container, index = match.group(1), int(match.group(2))
    node = preset.find(container)
    if node is None:
        raise AmpliTubeError(f"El preset no tiene bloque {container}.")
    old_slot = node.find(f"Slot{index}")
    position = list(node).index(old_slot) if old_slot is not None else len(node)
    if old_slot is not None:
        node.remove(old_slot)

    if ref.lower() in EMPTY_WORDS:
        node.set(f"Stomp{index}", EMPTY_SLOT)
        node.insert(position, ET.Element(f"Slot{index}"))
    else:
        guid = resolve_model(vocab, ref, "efecto")
        model = vocab["models"][guid]
        if category(container) not in model["categories"]:
            raise AmpliTubeError(
                f"{label(model, guid)} solo aparece en fábrica en {', '.join(model['categories'])}; "
                f"ponerlo en {container} ({category(container)}) sería adivinar."
            )
        example = model["example"]
        source = ET.parse(root / example["preset"]).getroot() \
            .find(example["container"]).find(f"Slot{example['slot']}")
        new_slot = copy.deepcopy(source)
        new_slot.tag = f"Slot{index}"
        node.set(f"Stomp{index}", guid)
        node.insert(position, new_slot)

    # A MIDI assignment aimed at the gear that just left the slot would now
    # drive whatever replaced it. Drop it rather than leave it dangling.
    midi = preset.find("MidiAssignments")
    if midi is not None:
        for a in list(midi):
            if a.get("ChainSlot") == container and a.get("ChainSubSlot") == str(index):
                midi.remove(a)
                notes.append(f"Se quitó la asignación MIDI «{a.get('ControlName')}» de {target}.")
    return notes


def semantic_diff(a: ET.Element, b: ET.Element, here: str | None = None) -> list[tuple[str, str | None, str | None]]:
    """Attribute-level differences between two presets, as (path, before, after).

    `here` is the dotted path of `a` itself, None at the root — so root
    attributes read "GUID" and nested ones "AmpA.Amp.Gain_AmpFriedman", the same
    spelling `--set` accepts.
    """
    changes = []
    for key in sorted(set(a.attrib) | set(b.attrib)):
        if a.get(key) != b.get(key):
            changes.append((f"{here}.{key}" if here else key, a.get(key), b.get(key)))
    a_kids = {c.tag: c for c in a}
    b_kids = {c.tag: c for c in b}
    for tag in sorted(set(a_kids) | set(b_kids)):
        path = f"{here}.{tag}" if here else tag
        if tag in a_kids and tag in b_kids:
            changes += semantic_diff(a_kids[tag], b_kids[tag], path)
        else:
            changes.append((path, "presente" if tag in a_kids else None,
                            "presente" if tag in b_kids else None))
    return changes


def write_new(preset: ET.Element, path: Path) -> None:
    """Write a preset that did not exist before. Never overwrites."""
    ET.indent(preset, space="    ")
    body = ET.tostring(preset, encoding="unicode", short_empty_elements=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(path, "x", encoding="utf-8") as fh:      # "x": fails if it exists
            fh.write('<?xml version="1.0" ?>\n' + body + "\n")
    except FileExistsError:
        raise AmpliTubeError(f"Ya existe {path}. No se sobrescribe: elige otro nombre.") from None


def clone_preset(root: Path, vocab: dict, base: str, name: str,
                 sets: list[str] = (), models: list[str] = (), dry_run: bool = False):
    if not name or "/" in name or name.startswith("."):
        raise AmpliTubeError(f"Nombre «{name}» inválido.")
    base_path = resolve_preset(root, base)
    original = ET.parse(base_path).getroot()
    preset = copy.deepcopy(original)
    warnings: list[str] = []

    for item in models:
        target, _, ref = item.partition("=")
        if not ref:
            raise AmpliTubeError(f"--model «{item}»: usa DESTINO=MODELO.")
        warnings += swap_model(root, vocab, preset, target.strip(), ref.strip())

    for item in sets:
        path, _, raw = item.partition("=")
        if not raw:
            raise AmpliTubeError(f"--set «{item}»: usa RUTA=VALOR.")
        container, child, attr = split_path(path.strip())
        if REF_ATTR.match(attr):
            raise AmpliTubeError(f"{path} señala un modelo por GUID; cámbialo con --model, no con --set.")
        node = preset.find(container)
        if node is not None and child is not None:
            node = node.find(child)
        if node is None or attr not in node.attrib:
            raise AmpliTubeError(f"{path} no existe en este preset. Usa `show` para ver las rutas válidas.")
        value, warning = check_value(spec_for(vocab, preset, container, child, attr), path.strip(), raw.strip())
        if warning:
            warnings.append(warning)
        node.set(attr, value)

    preset.set("GUID", str(uuid.uuid4()))
    out = root / CLAUDE_DIR / f"{name}.at5p"
    changes = [c for c in semantic_diff(original, preset) if c[0] != "GUID"]
    if not dry_run:
        write_new(preset, out)
        ET.parse(out)       # re-parse what landed on disk before reporting success
    return out, base_path, changes, warnings


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def cmd_vocab(args):
    vocab = build_vocab(args.root)
    VOCAB_FILE.write_text(json.dumps(vocab, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    kinds = Counter(m["kind"] for m in vocab["models"].values())
    named = sum(1 for m in vocab["models"].values() if m["display_name"])
    owned = Counter(m["kind"] for m in vocab["models"].values() if m["owned"] is True)
    print(f"{vocab['presets_read']} presets leídos → {dict(kinds)}; {named} con nombre de pantalla.")
    print(f"Equipo que Edgar tiene: {dict(owned) or 'desconocido (no se encontró el plist de licencias)'}")
    print(f"Escrito {VOCAB_FILE}")


def cmd_index(args):
    index = build_index(args.root, load_json(VOCAB_FILE, "vocab"))
    INDEX_FILE.write_text(json.dumps(index, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{len(index)} presets indexados. Escrito {INDEX_FILE}")


def cmd_search(args):
    hits = []
    for p in load_json(INDEX_FILE, "index"):
        if args.ampli and not (p["amp"] and args.ampli.lower() in p["amp"]["label"].lower()):
            continue
        if args.caracter and (p["character"] or "").lower() != args.caracter.lower():
            continue
        if args.estilo and (p["style"] or "").lower() != args.estilo.lower():
            continue
        if args.efecto and not any(args.efecto.lower() in e["label"].lower() for e in p["effects"]):
            continue
        if args.texto and args.texto.lower() not in p["name"].lower():
            continue
        if args.mio and not (p["amp"] and p["amp"]["owned"] is True
                             and all(e["owned"] is True for e in p["effects"])):
            continue
        hits.append(p)
    for p in hits[: args.limit]:
        amp = (p["amp"]["label"] + lock(p["amp"])) if p["amp"] else "—"
        gain = p["amp"]["gain"] if p["amp"] else None
        fx = ", ".join(e["label"] + lock(e) + (" (bypass)" if e["bypass"] else "")
                       for e in p["effects"]) or "sin efectos"
        print(f"{p['file']}\n    {p['character']} · {p['style']} · {amp} gain={gain} · {fx}")
    print(f"\n{len(hits)} coincidencias{' (mostrando ' + str(args.limit) + ')' if len(hits) > args.limit else ''}.")


def cmd_models(args):
    for guid, m in load_json(VOCAB_FILE, "vocab")["models"].items():
        if args.tipo and m["kind"] != args.tipo:
            continue
        if args.mio and m["owned"] is not True:
            continue
        name = label(m, guid)
        keys = [k for k in m["params"] if k != "Bypass"]
        if args.buscar and args.buscar.lower() not in (name + " " + " ".join(keys)).lower():
            continue
        source = f"  [nombre: {m['display_source']}]" if m["display_name"] else ""
        print(f"{name}{lock(m)}  ({m['kind']}, {'/'.join(m['categories'])}, en {m['uses']} presets){source}")
        print(f"    {guid}  params: {', '.join(keys[:12])}{' …' if len(keys) > 12 else ''}")


def cmd_show(args):
    vocab = load_json(VOCAB_FILE, "vocab")
    path = resolve_preset(args.root, args.preset)
    preset = ET.parse(path).getroot()
    print(f"{path}\n")
    for node in preset:
        if node.tag in NOT_TONE:
            continue
        if node.tag in AMP_CONTAINERS:
            guid = node.get("Model")
            known = vocab["models"].get(guid)
            print(f"[{node.tag}] ampli: {label(known, guid) + lock(known) if known else guid}")
        elif node.tag in SLOT_CONTAINERS:
            filled = [(i, node.get(f"Stomp{i}")) for i in range(SLOTS_PER_CONTAINER)
                      if node.get(f"Stomp{i}") not in (None, EMPTY_SLOT)]
            if not filled and not args.todo:
                continue
            names = ", ".join(
                f"{i}={label(vocab['models'][g], g) + lock(vocab['models'][g]) if g in vocab['models'] else g}"
                for i, g in filled)
            print(f"[{node.tag}] {names or 'vacío'}")
        else:
            print(f"[{node.tag}]")
        rows = [(f"{node.tag}.{k}", v, None) for k, v in node.attrib.items() if not REF_ATTR.match(k)]
        for child in node:
            if child.tag.startswith("Slot") and node.get(f"Stomp{child.tag[4:]}") in (None, EMPTY_SLOT):
                continue
            rows += [(f"{node.tag}.{child.tag}.{k}", v, child.tag) for k, v in child.attrib.items()
                     if not REF_ATTR.match(k)]
        for p, v, child in rows:
            c, ch, a = split_path(p)
            spec = spec_for(vocab, preset, c, ch, a)
            hint = ""
            if spec and spec["type"] == "num":
                hint = f"   ({spec['min']:g} a {spec['max']:g})"
            elif spec:
                hint = f"   ({' | '.join(spec['values'])})"
            print(f"    {p} = {v}{hint}")


def cmd_clone(args):
    vocab = load_json(VOCAB_FILE, "vocab")
    out, base, changes, warnings = clone_preset(
        args.root, vocab, args.preset, args.name, args.set or [], args.model or [], args.dry_run)
    for w in warnings:
        print(f"AVISO: {w}", file=sys.stderr)
    print(f"Base: {base.relative_to(args.root) if base.is_relative_to(args.root) else base}")
    for p, before, after in changes:
        print(f"    {p}: {before} → {after}")
    if not changes:
        print("    (sin cambios respecto a la base, salvo el GUID)")
    print(("NO se escribió (--dry-run): " if args.dry_run else "Escrito: ") + str(out))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT,
                        help="carpeta de presets de AmpliTube 5 (por defecto la de Edgar)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("vocab", help="reconstruir vocabulario.json").set_defaults(fn=cmd_vocab)
    sub.add_parser("index", help="reconstruir presets-indice.json").set_defaults(fn=cmd_index)
    s = sub.add_parser("search", help="buscar presets de fábrica para usar de base")
    s.add_argument("--ampli"); s.add_argument("--caracter"); s.add_argument("--estilo")
    s.add_argument("--efecto"); s.add_argument("--texto"); s.add_argument("--limit", type=int, default=15)
    s.add_argument("--mio", action="store_true", help="solo presets con ampli y efectos que Edgar tiene")
    s.set_defaults(fn=cmd_search)
    m = sub.add_parser("models", help="listar amplis y efectos conocidos")
    m.add_argument("--tipo", choices=["ampli", "efecto"]); m.add_argument("--buscar")
    m.add_argument("--mio", action="store_true", help="solo equipo que Edgar tiene")
    m.set_defaults(fn=cmd_models)
    sh = sub.add_parser("show", help="ver todas las rutas editables de un preset")
    sh.add_argument("preset"); sh.add_argument("--todo", action="store_true", help="incluir bloques vacíos")
    sh.set_defaults(fn=cmd_show)
    c = sub.add_parser("clone", help="crear un preset nuevo en Claude/ a partir de otro")
    c.add_argument("preset"); c.add_argument("--name", required=True)
    c.add_argument("--set", action="append", metavar="RUTA=VALOR")
    c.add_argument("--model", action="append", metavar="DESTINO=MODELO")
    c.add_argument("--dry-run", action="store_true")
    c.set_defaults(fn=cmd_clone)
    args = parser.parse_args(argv)
    try:
        args.fn(args)
    except AmpliTubeError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
