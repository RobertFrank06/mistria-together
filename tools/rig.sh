#!/usr/bin/env bash
# Developer test rig: an isolated copy of the game with the mod installed, run
# headless under gamescope with its own save directory. Never touches the real
# install or real saves.
#
#   tools/rig.sh setup            copy the game into the rig (once)
#   tools/rig.sh install          install MMAPI + this mod into the rig copy
#   tools/rig.sh run <p> [env..]  run instance <p> (p1, p2, ...) headless
#   tools/rig.sh cmd <p> '<json>' queue a dev command for instance <p>
#   tools/rig.sh state <p>        print instance <p>'s dev state
#   tools/rig.sh stop             kill all rig instances
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RIG="${MT_RIG:-${XDG_RUNTIME_DIR:-/tmp}/mistria-together-rig}"
GAME_SRC="${MT_GAME:-$HOME/.local/share/Steam/steamapps/common/Fields of Mistria}"
MOMI="${MT_MOMI:-$HOME/Gamestuff/ModsOfMistriaInstaller-cli-linux}"
FAKE_HOME="$RIG/home"
GAME="$FAKE_HOME/.local/share/Steam/steamapps/common/Fields of Mistria"

ipc() { echo "$RIG/$1/FieldsOfMistria/mod_data/mistria_together/ipc"; }

case "${1:-}" in
setup)
    mkdir -p "$GAME"
    cp "$GAME_SRC"/FieldsOfMistria "$GAME_SRC"/*.so* "$GAME_SRC"/Maybe.toml "$GAME"/
    cp "$GAME_SRC"/open-source-licenses.html "$GAME"/ 2>/dev/null || true
    # Always start from the pristine archive when the installer left a backup.
    if [ -f "$GAME_SRC/assets.bak.zip" ]; then
        cp "$GAME_SRC/assets.bak.zip" "$GAME/assets.zip"
    else
        cp "$GAME_SRC/assets.zip" "$GAME/assets.zip"
    fi
    echo "rig game copy at $GAME"
    ;;
install)
    rm -rf "$GAME/mods"
    mkdir -p "$GAME/mods"
    cp -r "$REPO/mod/mt" "$GAME/mods/mt"
    ( cd "$GAME" && HOME="$FAKE_HOME" EXIT_ON_COMPLETE=true "$MOMI" "${@:2}" )
    ;;
run)
    p="$2"; shift 2
    mkdir -p "$RIG/$p/FieldsOfMistria"
    if [ ! -f "$RIG/$p/FieldsOfMistria/settings.json" ] && [ -f "$HOME/.local/share/FieldsOfMistria/settings.json" ]; then
        sed -e 's/"borderless_fullscreen": true/"borderless_fullscreen": false/' \
            -e 's/"global_volume": [0-9.]*/"global_volume": 0/' \
            -e 's/"window_x": [0-9]*/"window_x": 960/' -e 's/"window_y": [0-9]*/"window_y": 540/' \
            "$HOME/.local/share/FieldsOfMistria/settings.json" > "$RIG/$p/FieldsOfMistria/settings.json"
    fi
    cd "$GAME"
    exec env XDG_DATA_HOME="$RIG/$p" MISTRIA_TOGETHER_DEV="${MISTRIA_TOGETHER_DEV:-new}" "$@" \
        gamescope --backend headless -W 960 -H 540 -- ./FieldsOfMistria
    ;;
cmd)
    d="$(ipc "$2")"; mkdir -p "$d"
    n=0; [ -f "$d/.dev_cmd_next" ] && n="$(cat "$d/.dev_cmd_next")"
    printf '%s' "$3" > "$d/dev_cmd.tmp" && mv "$d/dev_cmd.tmp" "$d/dev_cmd_$n.json"
    echo $((n + 1)) > "$d/.dev_cmd_next"
    ;;
state)
    cat "$(ipc "$2")/dev_state.json"; echo
    ;;
stop)
    pkill -f "$GAME/FieldsOfMistria" 2>/dev/null || true
    pkill -f "gamescope --backend headless" 2>/dev/null || true
    ;;
*)
    sed -n '2,12p' "$0"; exit 2
    ;;
esac
