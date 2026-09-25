#!/usr/bin/env bash
# Negative controls for tests/laya.test.sh (DIVE-4965). A green suite only means
# something if the arms can go red. For each mutation, this copies the plugin
# tree, breaks one load-bearing line, runs the suite against the copy, and
# requires that EXACTLY the named arms fail. Too few means an arm is not
# guarding its line. Too many means the mutation or the suite is not the
# instrument we think it is.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB_REL="lib/laya-host.sh"

CONTROLS=0; BROKEN=0
control() {  # control <label> <sed expression on lib/laya-host.sh> <expected failing arm>...
  local label="$1" expr="$2"; shift 2
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/laya-neg.XXXXXX")"
  cp -r "$REPO/laya" "$d/laya"; mkdir -p "$d/.claude-plugin"; cp "$REPO/.claude-plugin/marketplace.json" "$d/.claude-plugin/"
  sed -i "$expr" "$d/laya/$LIB_REL"
  CONTROLS=$((CONTROLS + 1))
  if cmp -s "$REPO/laya/$LIB_REL" "$d/laya/$LIB_REL"; then
    printf 'BROKEN %s: the mutation changed nothing\n' "$label"; BROKEN=$((BROKEN + 1)); rm -rf "$d"; return
  fi
  local out rc; out="$(PLUGIN_DIR="$d/laya" bash "$HERE/laya.test.sh" 2>&1)"; rc=$?
  local got want
  got="$(sed -n 's/^FAIL //p' <<<"$out" | sort)"
  want="$(printf '%s\n' "$@" | sort)"
  if [[ $rc -ne 0 && "$got" == "$want" ]]; then
    printf 'ok     %s: red on exactly %d arm(s)\n' "$label" "$#"
  else
    printf 'BROKEN %s (suite rc=%d)\n  expected red:\n%s\n  got red:\n%s\n' "$label" "$rc" "$(sed 's/^/    /' <<<"$want")" "$(sed 's/^/    /' <<<"${got:-<none>}")"
    BROKEN=$((BROKEN + 1))
  fi
  rm -rf "$d"
}

control "unit binds 0.0.0.0" \
  's/^LAYA_BIND_HOST="127.0.0.1"/LAYA_BIND_HOST="0.0.0.0"/' \
  "unit: LAYA_HOST=127.0.0.1" "unit: no 0.0.0.0 anywhere" \
  "setup: exits 0" "setup: points reflex at Laya" "setup: reflex endpoint is now Laya" \
  "setup: says it is loopback only" "setup: records reflex's previous endpoint" "setup: state file is 0600" \
  "status: healthy after setup" "status: exits 0 when healthy" "status: reports resident memory" \
  "health: exits 0 and prints Laya's /health" "setup re-run: exits 0" \
  "setup re-run: previous endpoint is still the original" "4 GB host: --allow-small-host proceeds" \
  "exposed: says why" "uninstall: reflex back to the default endpoint" \
  "uninstall: restores a model the owner had set" "uninstall: a refused reset tears nothing down"
# ^ Laya binds what its unit says, so every setup now fails closed: nothing
#   downstream of a setup can pass, and "says why" names the mutated host.

control "unit preloads every checkpoint" \
  's/^LAYA_PRELOAD_VALUE="0"/LAYA_PRELOAD_VALUE="1"/' \
  "unit: LAYA_PRELOAD=0"

control "unit takes LAYA_HOST from the caller's environment" \
  's/^Environment=LAYA_HOST=\$LAYA_BIND_HOST/Environment=LAYA_HOST=${LAYA_HOST:-$LAYA_BIND_HOST}/' \
  "unit: LAYA_HOST=127.0.0.1" "unit: no 0.0.0.0 anywhere" "setup: the written unit is the rendered one"

control "cgroup firewall dropped" \
  '/^IPAddressDeny=any$/d' \
  "unit: cgroup firewall, deny any"

control "bind verdict accepts a wildcard" \
  's/^      \*) bad=1 ;;/      *) ;;/' \
  "bind: 0.0.0.0 is exposed" "bind: [::] is exposed" "bind: * is exposed" "bind: a public address is exposed" \
  "bind: loopback plus a wildcard is exposed" "exposed: setup fails" "exposed: reflex NOT pointed at Laya" \
  "exposed: reflex endpoint unchanged" "exposed: the unit is stopped and disabled" "exposed: says why" \
  "status: an exposed listener is not healthy" "status: exits non-zero when exposed"

control "setup does not fail closed on an exposed socket" \
  's/^  if \[\[ "\$bind" != loopback \]\]; then/  if false; then/' \
  "exposed: setup fails" "exposed: reflex NOT pointed at Laya" "exposed: reflex endpoint unchanged" \
  "exposed: the unit is stopped and disabled" "exposed: says why"

control "uninstall leaves reflex pointing at Laya" \
  's/^    5dive config reflex-endpoint=default "reflex-model=\$model" >\/dev\/null \\/    true \\/' \
  "uninstall: reflex back to the default endpoint" "uninstall: reflex endpoint is default" \
  "uninstall: restores a model the owner had set" "uninstall: a refused reset tears nothing down"

control "setup re-records its own endpoint as previous" \
  's/^  if \[\[ ! -s "\$LAYA_STATE_FILE" \]\] \&\& ! laya_reflex_points_here; then/  if true; then/' \
  "setup re-run: previous endpoint is still the original"

control "the RAM floor is gone" \
  's/^LAYA_MIN_MEM_KB=.*/LAYA_MIN_MEM_KB=0/' \
  "4 GB host: setup refuses" "4 GB host: names Starter Plus and the remote provider" \
  "4 GB host: installs nothing" "4 GB host: reflex untouched"

printf '\n%d controls, %d broken\n' "$CONTROLS" "$BROKEN"
(( CONTROLS > 0 && BROKEN == 0 ))
