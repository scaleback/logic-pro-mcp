#!/bin/zsh
# Despliegue local de Batuta sin sudo (decisión 2026-09-19, ver ../HANDOFF.md).
#
# Los binarios viven en una carpeta del usuario, así que copiarlos no pide
# contraseña. La firma es SIEMPRE la canónica: mismo certificado y mismo
# identificador en cada build, de modo que el requisito de firma (identifier +
# certificate root) no cambia y el permiso de Accesibilidad del ayudante y su
# registro de fondo (BTM) sobreviven al despliegue.
#
#   Scripts/deploy-local.sh              compila, firma, verifica, copia
#   Scripts/deploy-local.sh --no-build   solo firma, verifica y copia lo ya compilado
#   Scripts/deploy-local.sh --sin-sandbox  TEMPORAL: el servidor sin Batuta.entitlements
#       (decisión de Edgar 2026-09-19: con sandbox, las guardias del servidor que
#       leen Accesibilidad directo — nombres de pista — fallan cerradas y bloquean
#       load_preset; ver ../HANDOFF.md). Volver al sandbox en cuanto esas lecturas
#       pasen por el ayudante: basta con desplegar SIN esta opción.
#
# Si el servidor cambió, al final pide reiniciar Claude; si solo cambió el
# ayudante, lo reinicia aquí mismo.

set -euo pipefail
cd "$(dirname "$0")/.."

DEST="$HOME/Library/Application Support/Batuta/bin"
IDENTITY="Batuta Local Dev"
AGENT="com.scaleback.batuta.logicpromcp.axhelper"
SERVER=LogicProMCP
HELPER=LogicProMCPAXHelper

cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

build=1 sandbox=1
for arg in "$@"; do
    case "$arg" in
        --no-build) build=0 ;;
        --sin-sandbox) sandbox=0 ;;
        *) echo "opción desconocida: $arg"; exit 2 ;;
    esac
done

if (( build )); then
    swift build -c release 2>&1 | tail -1
fi

if (( sandbox )); then
    codesign --force --options runtime --sign "$IDENTITY" \
        --identifier com.scaleback.batuta.logicpromcp \
        --entitlements Batuta.entitlements ".build/release/$SERVER"
else
    echo "⚠️  SERVIDOR SIN SANDBOX (temporal): sin la garantía de 'sin red'. Para volver: desplegar sin --sin-sandbox."
    codesign --force --options runtime --sign "$IDENTITY" \
        --identifier com.scaleback.batuta.logicpromcp ".build/release/$SERVER"
fi
codesign --force --options runtime --sign "$IDENTITY" \
    --identifier com.scaleback.batuta.logicpromcp.axhelper \
    ".build/release/$HELPER"

# The server must be sandboxed; the helper must not be (it needs Accessibility).
codesign --verify --strict ".build/release/$SERVER" ".build/release/$HELPER"
if (( sandbox )); then
    codesign -d --entitlements - ".build/release/$SERVER" 2>&1 | grep -q app-sandbox \
        || { echo "ABORTO: el servidor quedó sin sandbox"; exit 1; }
elif codesign -d --entitlements - ".build/release/$SERVER" 2>&1 | grep -q app-sandbox; then
    echo "ABORTO: se pidió --sin-sandbox y el servidor quedó con sandbox"; exit 1
fi
if codesign -d --entitlements - ".build/release/$HELPER" 2>&1 | grep -q app-sandbox; then
    echo "ABORTO: el ayudante quedó con sandbox"; exit 1
fi

mkdir -p "$DEST"
server_changed=1
[[ -f "$DEST/$SERVER" && "$(cdhash "$DEST/$SERVER")" == "$(cdhash ".build/release/$SERVER")" ]] && server_changed=0
helper_changed=1
[[ -f "$DEST/$HELPER" && "$(cdhash "$DEST/$HELPER")" == "$(cdhash ".build/release/$HELPER")" ]] && helper_changed=0

# Copy via a temp name + rename so a running process never sees a half-written file.
for b in $SERVER $HELPER; do
    cp ".build/release/$b" "$DEST/.$b.new"
    chmod 755 "$DEST/.$b.new"
    mv -f "$DEST/.$b.new" "$DEST/$b"
done

echo "servidor: $(cdhash "$DEST/$SERVER")  ayudante: $(cdhash "$DEST/$HELPER")  (commit $(git rev-parse --short HEAD))"

if (( helper_changed )); then
    launchctl kickstart -k "gui/$(id -u)/$AGENT"
    sleep 15
    if launchctl print "gui/$(id -u)/$AGENT" | grep -q "state = running"; then
        echo "ayudante: reiniciado ✓  $(tail -1 "$HOME/Library/Logs/LogicProMCP/axhelper.err.log" | cut -c1-100)"
    else
        echo "ayudante: NO arrancó — revisar 'launchctl print gui/$(id -u)/$AGENT' y /usr/bin/log show"
        exit 1
    fi
else
    echo "ayudante: sin cambios"
fi
if (( server_changed )); then
    echo "servidor: CAMBIÓ — reiniciar Claude para cargarlo"
else
    echo "servidor: sin cambios"
fi
