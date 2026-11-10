#!/usr/bin/env bash
# Two-instance end-to-end helper on top of rig.sh (developers only).
# usage: e2e.sh up [seconds] | down | st | log | cmd <p1|p2> <json>   then: python3 tools/e2e_compare.py
S="${MT_RIG:-${XDG_RUNTIME_DIR:-/tmp}/mistria-together-rig}"; export MT_RIG=$S; mkdir -p $S
R="$(cd "$(dirname "$0")/.." && pwd)"; B=$R/target/release/mistria-together
case "$1" in
up)
  T=${2:-240}
  $R/tools/rig.sh stop; pkill -f "[m]istria-together (host|join)" 2>/dev/null; sleep 1
  rm -rf $S/p1/FieldsOfMistria/mod_data $S/p2/FieldsOfMistria/mod_data
  [ -n "$KEEP_SAVES" ] || rm -rf $S/p1/FieldsOfMistria/saves $S/p2/FieldsOfMistria/saves
  (cd $R && timeout 600 tools/rig.sh install > $S/install.out 2>&1); grep -a "skipped\|Skipped\|error\|  !" $S/install.out | cut -c1-300
  (timeout $T $B host --port 47777 --data-dir $S/p1/FieldsOfMistria > $S/c1.out 2>&1 &)
  (timeout $T $B join 127.0.0.1:47777 --data-dir $S/p2/FieldsOfMistria > $S/c2.out 2>&1 &)
  (MISTRIA_TOGETHER_DEV_NAME=Robert timeout $T $R/tools/rig.sh run p1 > $S/p1.out 2>&1 &)
  sleep ${STAGGER:-0}
  (MISTRIA_TOGETHER_DEV_NAME=Mia MISTRIA_TOGETHER_DEV_LOOK=3 timeout $T $R/tools/rig.sh run p2 > $S/p2.out 2>&1 &)
  for i in $(seq 1 60); do sleep 2; if grep -qs '"online":true' $S/p1/FieldsOfMistria/mod_data/mistria_together/ipc/dev_state.json && grep -qs '"online":true' $S/p2/FieldsOfMistria/mod_data/mistria_together/ipc/dev_state.json; then echo "both online after $((i*2))s"; break; fi; done
  ;;
down) $R/tools/rig.sh stop; pkill -f "[m]istria-together (host|join)" 2>/dev/null ;;
st) for p in p1 p2; do echo "== $p"; cat $S/$p/FieldsOfMistria/mod_data/mistria_together/ipc/dev_state.json; echo; done ;;
log) for p in p1 p2; do echo "== $p"; grep -ah "mistria_together\]\|ERROR\|panicked" $S/$p.out | sed 's/\x1b\[[0-9;]*m//g' | grep -v "ready, ipc\|initialize Steam" | cut -c1-${2:-300} | tail -${3:-12}; done ;;
cmd) $R/tools/rig.sh cmd "$2" "$3" ;;
esac
