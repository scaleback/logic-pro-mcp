#!/usr/bin/env python3
"""Presets de los plugins de Logic (.pst): leer y escribir parámetros. Sin dependencias.

Uso típico, desde una sesión de Claude o una terminal:

    python3 logic_presets.py plugins
    python3 logic_presets.py show ChromaVerb CensoChromaVerb-base
    python3 logic_presets.py clone ChromaVerb CensoChromaVerb-base --name "Sala larga" \\
        --set decay=3.5 --set wet=35 --set sala="Concert Hall"

El preset nuevo aparece en Logic en el menú Setting del plugin → Claude → <nombre>
(verificado con Edgar 2026-09-18), y logic_plugins.load_preset lo carga con
preset_path ["Claude", "<nombre>"].

Formato, verificado contra archivos que guardó Logic 12.3.1:
    uint32 tamaño del archivo · uint32 versión (1) · uint32 n parámetros ·
    8 bytes "GAMETSPP" · uint32 id del plugin (Compressor 154, Channel EQ 236,
    ChromaVerb 287) · n × float32 en unidades reales · cola opcional (Channel EQ
    trae 8 bytes que no son parámetros; se copian tal cual).

Reglas que el código hace cumplir (PLAN_PLUGINS_Y_PRESETS.md, FASE E):
  - Solo se escribe un parámetro con EVIDENCIA: movido en un censo, o cuyo
    default es un valor único que coincide con la pantalla. Lo deducido del
    patrón se muestra pero se rechaza al escribir.
  - Solo se crean archivos nuevos en <Plugin>/Claude/; nunca se sobrescribe.
  - El id del plugin en la cabecera tiene que ser el del mapa: un preset de
    ChromaVerb no se "edita" con el mapa del Compressor.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAPS_DIR = HERE / "mapas"
DEFAULT_ROOT = Path.home() / "Music" / "Audio Music Apps" / "Plug-In Settings"
# Logic's own presets (read-only source: a clone of one still lands in Claude/).
FACTORY_ROOT = Path("/Applications/Logic Pro.app/Contents/Resources/Plug-In Settings")
CLAUDE_DIR = "Claude"
MAGIC = b"GAMETSPP"
HEADER = 24
WRITABLE = {"censo", "default_unico"}


class PresetError(Exception):
    """A refusal whose message is meant for the person running the tool."""


# --------------------------------------------------------------------------
# Format
# --------------------------------------------------------------------------

def parse(blob: bytes) -> dict:
    if len(blob) < HEADER or blob[12:20] != MAGIC:
        raise PresetError("No es un preset de plugin de Logic (falta la marca GAMETSPP).")
    size, version, count = struct.unpack("<III", blob[:12])
    plugin_id = struct.unpack("<I", blob[20:24])[0]
    end = HEADER + 4 * count
    if size != len(blob) or end > len(blob):
        raise PresetError(f"Cabecera incoherente: dice {size} bytes y {count} parámetros, el archivo tiene {len(blob)}.")
    return {
        "version": version,
        "plugin_id": plugin_id,
        "values": list(struct.unpack("<" + "f" * count, blob[HEADER:end])),
        "head": blob[:HEADER],
        "tail": blob[end:],
    }


def encode(preset: dict) -> bytes:
    values = preset["values"]
    return preset["head"] + struct.pack("<" + "f" * len(values), *values) + preset["tail"]


# --------------------------------------------------------------------------
# Maps and files
# --------------------------------------------------------------------------

def load_map(plugin: str) -> dict:
    for path in sorted(MAPS_DIR.glob("*.json")):
        m = json.loads(path.read_text(encoding="utf-8"))
        if m["plugin"].lower() == plugin.lower():
            return m
    known = ", ".join(sorted(json.loads(p.read_text())["plugin"] for p in MAPS_DIR.glob("*.json")))
    raise PresetError(f"No hay mapa para «{plugin}». Mapeados: {known}.")


def resolve_preset(root: Path, plugin_map: dict, ref: str, factory_root: Path | None = FACTORY_ROOT) -> Path:
    """A preset by path, or by name in the user's folder and then Logic's factory set.

    A name may also carry its menu folder ("Chambers/Guitar Chamber"), which is
    how scan_plugin_presets and load_preset spell it.
    """
    candidate = Path(ref).expanduser()
    if candidate.is_file():
        return candidate
    folders = [root / plugin_map["plugin"]]
    if factory_root is not None:
        folders.append(factory_root / plugin_map["plugin"])
    wanted = ref.lower().removesuffix(".pst")
    hits = []
    for folder in folders:
        if not folder.is_dir():
            continue
        for p in folder.rglob("*.pst"):
            rel = str(p.relative_to(folder).with_suffix("")).lower()
            if p.stem.lower() == wanted or rel == wanted:
                hits.append(p)
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise PresetError(f"No encontré «{ref}» en: " + ", ".join(str(f) for f in folders) + ".")
    listing = "\n  ".join(str(p) for p in hits)
    raise PresetError(f"Hay {len(hits)} presets «{ref}»; da la ruta:\n  {listing}")


def read_checked(path: Path, plugin_map: dict) -> dict:
    preset = parse(path.read_bytes())
    if preset["plugin_id"] != plugin_map["plugin_id"]:
        raise PresetError(
            f"{path.name} es del plugin id {preset['plugin_id']}, no de {plugin_map['plugin']} "
            f"(id {plugin_map['plugin_id']})."
        )
    if len(preset["values"]) != plugin_map["param_count"]:
        raise PresetError(
            f"{path.name} trae {len(preset['values'])} parámetros; el mapa de {plugin_map['plugin']} "
            f"espera {plugin_map['param_count']}. Otra versión del plugin: el mapa no aplica."
        )
    return preset


def resolve_value(name: str, spec: dict, raw: str) -> tuple[float, str | None]:
    """The float to store, and a warning when the value's meaning is weaker than the param's."""
    if spec["unit"] == "enum":
        by_label = {k.lower(): v for k, v in spec["values"].items()}
        if raw.lower() in by_label:
            number, evidence = by_label[raw.lower()]
        else:
            try:
                number = float(raw)
            except ValueError:
                raise PresetError(f"{name}: «{raw}» no es una opción conocida ({', '.join(spec['values'])}).") from None
            matches = [(v, e) for v, e in spec["values"].values() if v == number]
            evidence = matches[0][1] if matches else None
        if evidence == "censo":
            return float(number), None
        if evidence == "orden_pantalla":
            return float(number), (f"{name}={raw}: el número sale del ORDEN en pantalla, no de un censo. "
                                   "Confírmalo en la ventana del plugin.")
        return float(number), f"{name}={raw}: valor nunca visto en un censo."
    try:
        number = float(raw)
    except ValueError:
        raise PresetError(f"{name} es numérico ({spec['unit']}); «{raw}» no lo es.") from None
    if not math.isfinite(number):
        raise PresetError(f"{name}: «{raw}» no es un número finito.")
    return number, None


def clone(root: Path, plugin: str, base_ref: str, name: str,
          sets: list[str] = (), dry_run: bool = False,
          factory_root: Path | None = FACTORY_ROOT) -> tuple[Path, list, list[str]]:
    if not name or "/" in name or name.startswith("."):
        raise PresetError(f"Nombre «{name}» inválido.")
    plugin_map = load_map(plugin)
    base_path = resolve_preset(root, plugin_map, base_ref, factory_root)
    base = read_checked(base_path, plugin_map)
    preset = dict(base, values=list(base["values"]))
    changes, warnings = [], []

    for item in sets:
        key, _, raw = item.partition("=")
        key, raw = key.strip().lower(), raw.strip()
        if not raw:
            raise PresetError(f"--set «{item}»: usa nombre=valor.")
        spec = plugin_map["params"].get(key)
        if spec is None:
            raise PresetError(f"{plugin_map['plugin']} no tiene «{key}» mapeado. Mapeados: "
                              f"{', '.join(plugin_map['params'])}.")
        if spec["evidence"] not in WRITABLE:
            raise PresetError(f"{key}: índice {spec['index']} solo está deducido ({spec['nota']}); "
                              "no se escribe hasta verlo moverse en un censo.")
        number, warning = resolve_value(key, spec, raw)
        if warning:
            warnings.append(warning)
        index = spec["index"]
        changes.append((key, index, preset["values"][index], number))
        preset["values"][index] = number

    out = root / plugin_map["plugin"] / CLAUDE_DIR / f"{name}.pst"
    if dry_run:
        return out, changes, warnings
    blob = encode(preset)
    out.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(out, "xb") as fh:              # "x": never overwrites
            fh.write(blob)
    except FileExistsError:
        raise PresetError(f"Ya existe {out}. No se sobrescribe: elige otro nombre.") from None

    # Re-read what landed: every requested value (at float32 precision) and
    # nothing else moved.
    written = read_checked(out, plugin_map)
    touched = {i for _, i, _, _ in changes}
    for key, index, _, number in changes:
        if written["values"][index] != struct.unpack("<f", struct.pack("<f", number))[0]:
            raise PresetError(f"{out}: {key} no se relee igual.")
    for i, (a, b) in enumerate(zip(base["values"], written["values"])):
        if i not in touched and a != b:
            raise PresetError(f"{out}: el índice {i} cambió sin que se pidiera.")
    if written["tail"] != base["tail"] or written["head"][4:] != base["head"][4:]:
        raise PresetError(f"{out}: la cabecera o la cola no se preservaron.")
    return out, changes, warnings


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def cmd_plugins(args):
    for path in sorted(MAPS_DIR.glob("*.json")):
        m = json.loads(path.read_text(encoding="utf-8"))
        writable = [k for k, p in m["params"].items() if p["evidence"] in WRITABLE]
        print(f"{m['plugin']} (id {m['plugin_id']}, {m['param_count']} parámetros): "
              f"{len(writable)} escribibles → {', '.join(writable)}")


def cmd_show(args):
    plugin_map = load_map(args.plugin)
    path = resolve_preset(args.root, plugin_map, args.preset)
    preset = read_checked(path, plugin_map)
    print(f"{path}\n")
    for key, spec in plugin_map["params"].items():
        value = preset["values"][spec["index"]]
        label = ""
        if spec["unit"] == "enum":
            names = [k for k, (v, _) in spec["values"].items() if v == value]
            label = f"  ({names[0]})" if names else "  (opción no mapeada)"
        flag = "" if spec["evidence"] in WRITABLE else "   [deducido: no se escribe]"
        print(f"  {key:18} {value:10g} {spec['unit']:8}{label}{flag}")
    print(f"\n{len(plugin_map['params'])} de {plugin_map['param_count']} parámetros mapeados.")


def cmd_clone(args):
    out, changes, warnings = clone(args.root, args.plugin, args.preset, args.name, args.set or [], args.dry_run)
    for w in warnings:
        print(f"AVISO: {w}", file=sys.stderr)
    for key, index, before, after in changes:
        print(f"    {key} (idx {index}): {before:g} → {after:g}")
    if not changes:
        print("    (sin cambios respecto a la base)")
    print(("NO se escribió (--dry-run): " if args.dry_run else "Escrito: ") + str(out))
    if not args.dry_run:
        print(f'En Logic: menú Setting de {load_map(args.plugin)["plugin"]} → Claude → {args.name}   '
              f'(load_preset: preset_path ["Claude", "{args.name}"])')


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="carpeta Plug-In Settings de Logic")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plugins", help="plugins mapeados y sus parámetros escribibles").set_defaults(fn=cmd_plugins)
    s = sub.add_parser("show", help="ver un preset con nombres de parámetro")
    s.add_argument("plugin"); s.add_argument("preset"); s.set_defaults(fn=cmd_show)
    c = sub.add_parser("clone", help="crear un preset nuevo en <Plugin>/Claude/")
    c.add_argument("plugin"); c.add_argument("preset"); c.add_argument("--name", required=True)
    c.add_argument("--set", action="append", metavar="NOMBRE=VALOR")
    c.add_argument("--dry-run", action="store_true")
    c.set_defaults(fn=cmd_clone)
    args = parser.parse_args(argv)
    try:
        args.fn(args)
    except PresetError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
