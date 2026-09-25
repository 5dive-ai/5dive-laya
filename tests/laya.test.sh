#!/usr/bin/env bash
# The 5dive-laya harness (DIVE-4965). It runs the real bin/laya against a
# throwaway root with stub systemctl/ss/curl/5dive/pip on PATH. No root, torch,
# network or box is needed, so it runs in CI and on an agent seat alike.
#
# It grades what the row says a comment is not enough for: the unit binds
# 127.0.0.1 and preloads nothing, and a Laya reachable from off the box is
# never what reflex points at. It also grades the lifecycle: setup sets
# reflex-endpoint, uninstall sets it back, the unit goes.
#
# Prints one line per arm and a count at the end. The run is green only if
# ARMS > 0 and FAILED == 0 (tests/negative-controls.sh shows the arms can fail).
#
#   tests/laya.test.sh                    # the tree this file sits in
#   PLUGIN_DIR=<copy>/laya tests/laya.test.sh   # another copy (negative controls)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$REPO/laya}"
VERB="$PLUGIN_DIR/bin/laya"

ARMS=0; FAILED=0; FAILED_NAMES=()
arm() {  # arm <name> <command...>: pass when the command succeeds
  local name="$1"; shift
  ARMS=$((ARMS + 1))
  if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$name"
  else printf 'FAIL %s\n' "$name"; FAILED=$((FAILED + 1)); FAILED_NAMES+=("$name"); fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/laya-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
STUBS="$T/stubs"; mkdir -p "$STUBS"

# ---- stubs: a fake box whose state lives in $W ---------------------------------
stub() { printf '#!/usr/bin/env bash\nW="${LAYA_WORLD:?}"\n%s\n' "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }

stub systemctl '
echo "systemctl $*" >> "$W/calls"
args=("$@"); last="${args[${#args[@]}-1]}"
case "$1" in
  daemon-reload|enable|reset-failed) exit 0 ;;
  restart|start) echo active > "$W/active"; echo 4242 > "$W/pid"; exit 0 ;;
  disable) [[ "$2" == --now ]] && { echo inactive > "$W/active"; echo 0 > "$W/pid"; }; exit 0 ;;
  stop) echo inactive > "$W/active"; exit 0 ;;
  is-active) s=$(cat "$W/active" 2>/dev/null || echo inactive); [[ "$2" == --quiet ]] || echo "$s"; [[ "$s" == active ]] ;;
  show) cat "$W/pid" 2>/dev/null || echo 0 ;;
esac'

stub ss '
[[ -f "$W/foreign_listener" ]] && { echo "LISTEN 0 128 0.0.0.0:8767 0.0.0.0:*"; exit 0; }
[[ "$(cat "$W/active" 2>/dev/null)" == active ]] || exit 0
# Laya binds what its unit says (laya/serve.py:293 reads LAYA_HOST), so the fake
# socket follows the unit this run wrote. bind_addrs overrides it, which models a
# future Laya that ignores LAYA_HOST.
addrs=$(cat "$W/bind_addrs" 2>/dev/null) || addrs=$(sed -n "s/^Environment=LAYA_HOST=//p" "$LAYA_ROOT/etc/systemd/system/5dive-reflex-laya.service" 2>/dev/null)
for a in ${addrs:-0.0.0.0}; do echo "LISTEN 0 2048 $a:8767 0.0.0.0:*"; done'

stub curl '
echo "curl $*" >> "$W/calls"
[[ "$(cat "$W/active" 2>/dev/null)" == active ]] || exit 7
printf "{\"status\":\"ok\",\"loaded\":[],\"device\":\"auto\"}\n"'

stub 5dive '
echo "5dive $*" >> "$W/calls"
if [[ "$1" == config && "$2" == --json ]]; then
  jq -nc --arg e "$(cat "$W/ep")" --arg m "$(cat "$W/model")" --arg s "$(cat "$W/msrc")" \
    "{ok:true,data:{reflex_endpoint:\$e,reflex_model:\$m,reflex_model_source:\$s}}"; exit 0
fi
if [[ "$1" == config ]]; then
  [[ -f "$W/config_refuse" ]] && exit 5
  shift
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      reflex-endpoint) echo "$v" > "$W/ep" ;;
      reflex-model) if [[ "$v" == default ]]; then echo typesafe/jev-1.13 > "$W/model"; echo default > "$W/msrc"
                    else echo "$v" > "$W/model"; echo "box setting" > "$W/msrc"; fi ;;
    esac
  done; exit 0
fi
exit 0'

stub id '[[ "$1" == -u && -f "$W/user_$2" ]] && { echo 999; exit 0; }; exit 1'
stub useradd 'echo "useradd $*" >> "$W/calls"; touch "$W/user_${@: -1}"'
stub userdel 'echo "userdel $*" >> "$W/calls"; rm -f "$W/user_$1"'
stub runuser 'echo "runuser $*" >> "$W/calls"; [[ -f "$W/preload_fail" ]] && exit 1; exit 0'
stub journalctl 'echo "journalctl $*" >> "$W/calls"'
stub apt-get 'echo "apt-get $*" >> "$W/calls"'
stub chown 'exit 0'
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/x 99999999 1 $(cat "$W/disk_free_kb" 2>/dev/null || echo 20000000) 1% /"'
stub python3 '
echo "python3 $*" >> "$W/calls"
[[ "$1 $2" == "-m venv" ]] || exit 1
d="$3"; mkdir -p "$d/bin"
cat > "$d/bin/python" <<"PY"
#!/usr/bin/env bash
cat "$LAYA_WORLD/laya_version" 2>/dev/null || exit 1
PY
cat > "$d/bin/pip" <<"PIP"
#!/usr/bin/env bash
echo "pip $*" >> "$LAYA_WORLD/calls"
for a in "$@"; do [[ "$a" == "laya[serve]=="* ]] && echo "${a#*==}" > "$LAYA_WORLD/laya_version"; done
exit 0
PIP
printf "#!/usr/bin/env bash\nexit 0\n" > "$d/bin/laya-serve"
chmod +x "$d/bin/"*'

# ---- a fresh world per scenario --------------------------------------------------
new_world() {
  W="$T/w$((++WN))"; mkdir -p "$W/root"
  : > "$W/calls"
  echo default > "$W/ep"; echo typesafe/jev-1.13 > "$W/model"; echo default > "$W/msrc"
  echo inactive > "$W/active"; echo 0 > "$W/pid"
  printf 'MemTotal:        8039988 kB\n' > "$W/meminfo"      # a Starter Plus box
  mkdir -p "$W/root/proc/4242"; printf 'VmRSS:\t 1835008 kB\n' > "$W/root/proc/4242/status"
}
WN=0
run() {  # run <args...>: bin/laya as root in the current world; output in $W/out, rc in $W/rc
  env PATH="$STUBS:$PATH" LAYA_WORLD="$W" LAYA_ROOT="$W/root" LAYA_MEMINFO="$W/meminfo" \
      LAYA_TEST_EUID="${EUID_AS:-0}" LAYA_HEALTH_WAIT=2 FIVEDIVE_PLUGIN_KEY=laya@5dive-laya \
      "$VERB" "$@" > "$W/out" 2>&1
  echo $? > "$W/rc"
}
rc()      { [[ "$(cat "$W/rc")" == "$1" ]]; }
rc_fail() { [[ "$(cat "$W/rc")" != 0 ]]; }
called()  { grep -qF -- "$1" "$W/calls"; }
not_called() { ! grep -qF -- "$1" "$W/calls"; }
said()    { grep -qF -- "$1" "$W/out"; }
unit()    { printf '%s' "$W/root/etc/systemd/system/5dive-reflex-laya.service"; }
ep()      { cat "$W/ep"; }
LAYA_EP="http://127.0.0.1:8767/v1/systemone"

# =================================================================================
# 1. The unit: loopback and no preload, whatever the caller's environment says
# =================================================================================
render() {  # the unit as the lib renders it, with hostile Laya defaults exported
  ( export LAYA_HOST=0.0.0.0 LAYA_PRELOAD=1 LAYA_PORT=8000 LAYA_ROOT=""
    # shellcheck source=../laya/lib/laya-host.sh
    . "$PLUGIN_DIR/lib/laya-host.sh"; laya_render_unit )
}
U="$(render)"
env_line_count() { grep -c "^Environment=$1=" <<<"$U"; }
arm "unit: LAYA_HOST=127.0.0.1"                         grep -qx 'Environment=LAYA_HOST=127.0.0.1' <<<"$U"
arm "unit: exactly one LAYA_HOST line (systemd lets the last one win)" test "$(env_line_count LAYA_HOST)" = 1
arm "unit: LAYA_PRELOAD=0"                              grep -qx 'Environment=LAYA_PRELOAD=0' <<<"$U"
arm "unit: exactly one LAYA_PRELOAD line"               test "$(env_line_count LAYA_PRELOAD)" = 1
arm "unit: LAYA_PORT=8767, not Laya's 8000"             grep -qx 'Environment=LAYA_PORT=8767' <<<"$U"
arm "unit: no 0.0.0.0 anywhere"                         bash -c '! grep -q "0\.0\.0\.0" <<<"$1"' _ "$U"
arm "unit: no LAYA_MODELS (it would name checkpoints to preload)" bash -c '! grep -q "LAYA_MODELS" <<<"$1"' _ "$U"
arm "unit: cgroup firewall, deny any"                   grep -qx 'IPAddressDeny=any' <<<"$U"
arm "unit: cgroup firewall, allow localhost only"       grep -qx 'IPAddressAllow=localhost' <<<"$U"
arm "unit: service is offline (HF_HUB_OFFLINE=1)"       grep -qx 'Environment=HF_HUB_OFFLINE=1' <<<"$U"
arm "unit: runs as the 5dive-laya system user"          grep -qx 'User=5dive-laya' <<<"$U"
arm "unit: memory ceiling set"                          grep -qx 'MemoryMax=4G' <<<"$U"
arm "unit: ExecStart is the plugin venv's laya-serve"   grep -qx 'ExecStart=/opt/5dive-laya/venv/bin/laya-serve' <<<"$U"

# =================================================================================
# 2. The bind verdict, on ss output (loopback | exposed | down)
# =================================================================================
verdict() {
  ( . "$PLUGIN_DIR/lib/laya-host.sh"; laya_bind_verdict "$1" )
}
v_is() { [[ "$(verdict "$1")" == "$2" ]]; }
arm "bind: 127.0.0.1 is loopback"            v_is 'LISTEN 0 2048 127.0.0.1:8767 0.0.0.0:*' loopback
arm "bind: [::1] is loopback"                v_is 'LISTEN 0 2048 [::1]:8767 [::]:*' loopback
arm "bind: 0.0.0.0 is exposed"               v_is 'LISTEN 0 2048 0.0.0.0:8767 0.0.0.0:*' exposed
arm "bind: [::] is exposed"                  v_is 'LISTEN 0 2048 [::]:8767 [::]:*' exposed
arm "bind: * is exposed"                     v_is 'LISTEN 0 2048 *:8767 *:*' exposed
arm "bind: a public address is exposed"      v_is 'LISTEN 0 2048 203.0.113.7:8767 0.0.0.0:*' exposed
arm "bind: loopback plus a wildcard is exposed" v_is $'LISTEN 0 2048 127.0.0.1:8767 0.0.0.0:*\nLISTEN 0 2048 0.0.0.0:8767 0.0.0.0:*' exposed
arm "bind: another port does not count"      v_is 'LISTEN 0 2048 0.0.0.0:18767 0.0.0.0:*' down
arm "bind: nothing listening is down"        v_is '' down

# =================================================================================
# 3. setup on a Starter Plus box
# =================================================================================
new_world; run setup
arm "setup: exits 0"                                    rc 0
arm "setup: writes the unit"                            test -f "$(unit)"
arm "setup: the written unit is the rendered one"       bash -c 'diff -q <(printf "%s\n" "$1") "$2"' _ "$U" "$(unit)"
arm "setup: pins laya[serve]==0.3.20"                   called 'pip install -q laya[serve]==0.3.20'
arm "setup: torch from the CPU wheel index"             called 'pip install -q --index-url https://download.pytorch.org/whl/cpu torch==2.14.0'
arm "setup: fetches only the typed-decisions checkpoint, as the service user" called "runuser -u 5dive-laya -- env HF_HOME=$W/root/var/lib/5dive-laya/hf"
arm "setup: preload call names only typed-decisions"    called "preload(['typed-decisions'])"
arm "setup: enables and starts the unit"                bash -c 'grep -qx "systemctl enable 5dive-reflex-laya.service" "$1" && grep -qx "systemctl restart 5dive-reflex-laya.service" "$1"' _ "$W/calls"
arm "setup: points reflex at Laya"                      called "5dive config reflex-endpoint=$LAYA_EP reflex-model=typed-decisions"
arm "setup: reflex endpoint is now Laya"                test "$(ep)" = "$LAYA_EP"
arm "setup: records reflex's previous endpoint"         bash -c 'jq -e ".previous.endpoint == \"default\"" "$1"' _ "$W/root/var/lib/5dive-laya/state.json"
arm "setup: state file is 0600"                         test "$(stat -c %a "$W/root/var/lib/5dive-laya/state.json")" = 600
arm "setup: says it is loopback only"                   said 'listening on 127.0.0.1:8767 only'

# status after setup
run status --json
arm "status: healthy after setup"                       bash -c 'jq -e ".healthy == true and .bind == \"loopback\" and .reflex_points_here == true" "$1"' _ "$W/out"
arm "status: reports resident memory"                   bash -c 'jq -e ".resident_kb == 1835008" "$1"' _ "$W/out"
arm "status: exits 0 when healthy"                      rc 0
run health
arm "health: exits 0 and prints Laya's /health"         bash -c '[[ $(cat "$1/rc") == 0 ]] && grep -q "\"status\":\"ok\"" "$1/out"' _ "$W"

# a re-run is idempotent and must not record our own endpoint as "previous"
run setup
arm "setup re-run: exits 0"                             rc 0
arm "setup re-run: previous endpoint is still the original" bash -c 'jq -e ".previous.endpoint == \"default\"" "$1"' _ "$W/root/var/lib/5dive-laya/state.json"
arm "setup re-run: does not reinstall the pinned laya"  test "$(grep -c 'laya\[serve\]==' "$W/calls")" = 1

# =================================================================================
# 4. setup fails closed when the live socket is not loopback
# =================================================================================
new_world; echo "127.0.0.1 0.0.0.0" > "$W/bind_addrs"; run setup
arm "exposed: setup fails"                              rc_fail
arm "exposed: reflex NOT pointed at Laya"               not_called "reflex-endpoint=$LAYA_EP"
arm "exposed: reflex endpoint unchanged"                test "$(ep)" = default
arm "exposed: the unit is stopped and disabled"         bash -c 'grep -qx "systemctl disable --now 5dive-reflex-laya.service" "$1" && [[ $(cat "$2") == inactive ]]' _ "$W/calls" "$W/active"
arm "exposed: says why"                                 said 'listening on something other than 127.0.0.1'

# status flags an exposed listener as unhealthy (e.g. someone edited the unit)
new_world; echo active > "$W/active"; echo 0.0.0.0 > "$W/bind_addrs"; run status --json
arm "status: an exposed listener is not healthy"        bash -c 'jq -e ".healthy == false and .bind == \"exposed\"" "$1"' _ "$W/out"
arm "status: exits non-zero when exposed"               rc_fail

# =================================================================================
# 5. setup refuses what it should
# =================================================================================
new_world; printf 'MemTotal:        4015000 kB\n' > "$W/meminfo"; run setup
arm "4 GB host: setup refuses"                          rc_fail
arm "4 GB host: names Starter Plus and the remote provider" bash -c 'grep -q "Starter Plus (8 GB)" "$1" && grep -q "remote provider" "$1"' _ "$W/out"
arm "4 GB host: installs nothing"                       bash -c '! grep -qE "^(pip|systemctl|useradd|python3)" "$1" && [[ ! -e "$2" ]]' _ "$W/calls" "$(unit)"
arm "4 GB host: reflex untouched"                       test "$(ep)" = default
run setup --allow-small-host
arm "4 GB host: --allow-small-host proceeds"            rc 0

new_world; echo 1000000 > "$W/disk_free_kb"; run setup
arm "low disk: setup refuses before installing"         bash -c '[[ $(cat "$1/rc") != 0 ]] && ! grep -q "^pip" "$1/calls"' _ "$W"

new_world; touch "$W/foreign_listener"; run setup
arm "port taken by another service: setup refuses"      bash -c '[[ $(cat "$1/rc") != 0 ]] && grep -q "already in use" "$1/out" && ! grep -q "^pip" "$1/calls"' _ "$W"

new_world; touch "$W/preload_fail"; run setup
arm "checkpoint fetch fails: no unit, reflex untouched" bash -c '[[ $(cat "$1/rc") != 0 && ! -e "$2" && $(cat "$1/ep") == default ]]' _ "$W" "$(unit)"

new_world; EUID_AS=1000 run setup
arm "non-root: setup refuses with the sudo line"        bash -c '[[ $(cat "$1/rc") != 0 ]] && grep -q "sudo 5dive laya setup" "$1/out" && ! grep -q "^pip" "$1/calls"' _ "$W"
EUID_AS=1000 run uninstall
arm "non-root: uninstall refuses with the sudo line"    bash -c '[[ $(cat "$1/rc") != 0 ]] && grep -q "sudo 5dive laya uninstall" "$1/out"' _ "$W"

# =================================================================================
# 6. uninstall
# =================================================================================
new_world; run setup; : > "$W/calls"; run uninstall
arm "uninstall: exits 0"                                rc 0
arm "uninstall: reflex back to the default endpoint"    called '5dive config reflex-endpoint=default reflex-model=default'
arm "uninstall: reflex endpoint is default"             test "$(ep)" = default
arm "uninstall: unit stopped and disabled"              called 'systemctl disable --now 5dive-reflex-laya.service'
arm "uninstall: unit file gone"                         test ! -e "$(unit)"
arm "uninstall: venv and checkpoint gone"               bash -c '[[ ! -e "$1/opt/5dive-laya" && ! -e "$1/var/lib/5dive-laya" ]]' _ "$W/root"
arm "uninstall: service user removed"                   called 'userdel 5dive-laya'
arm "uninstall: removes the plugin last"                bash -c '[[ $(tail -n1 "$1") == "5dive plugin remove laya@5dive-laya" ]]' _ "$W/calls"
run status --json
arm "uninstall: status afterwards is not healthy"       bash -c 'jq -e ".healthy == false and .unit_installed == false" "$1"' _ "$W/out"

# an explicitly set model is restored; a default stays a default
new_world; echo openai/gpt-5-mini > "$W/model"; echo "box setting" > "$W/msrc"; run setup; run uninstall
arm "uninstall: restores a model the owner had set"     called '5dive config reflex-endpoint=default reflex-model=openai/gpt-5-mini'

# someone repointed reflex after setup: leave it alone
new_world; run setup; echo https://decide.example.com/v1/systemone > "$W/ep"; : > "$W/calls"; run uninstall
arm "uninstall: a repointed reflex is left alone"       bash -c '! grep -q "^5dive config reflex" "$1" && [[ $(cat "$2") == https://decide.example.com/v1/systemone ]]' _ "$W/calls" "$W/ep"
arm "uninstall: still removes the unit when repointed"  test ! -e "$(unit)"

# config refuses the reset: nothing else is torn down (reflex must not be left pointing at a dead port)
new_world; run setup; touch "$W/config_refuse"; : > "$W/calls"; run uninstall
arm "uninstall: a refused reset tears nothing down"     bash -c '[[ $(cat "$1/rc") != 0 && -e "$2" ]] && ! grep -q "disable --now" "$1/calls"' _ "$W" "$(unit)"

new_world; run setup; run uninstall --keep-plugin
arm "uninstall --keep-plugin: plugin stays"             not_called '5dive plugin remove'

# =================================================================================
# 7. The provider boundary, read off the manifests
# =================================================================================
MF="$PLUGIN_DIR/.claude-plugin/plugin.json"; MK="$REPO/.claude-plugin/marketplace.json"
arm "manifest: name equals its folder (contract §1)"    test "$(jq -r .name "$MF")" = "$(basename "$PLUGIN_DIR")"
arm "manifest: declares the verb capability only"       jq -e '.fivedive.capabilities == ["verb"]' "$MF"
arm "manifest: exactly one verb, laya (no second decision API)" jq -e '[.fivedive.verbs[].name] == ["laya"]' "$MF"
arm "manifest: no MCP server, hooks or skills"          jq -e 'has("mcpServers") or has("hooks") or has("skills") | not' "$MF"
arm "manifest: the verb's executable exists"            test -x "$PLUGIN_DIR/bin/laya"
arm "manifest: setup is printed as sudo 5dive laya setup" jq -e '.fivedive.setup.command == "sudo 5dive laya setup"' "$MF"
arm "manifest: setup hint carries the RAM line"         jq -e '.fivedive.setup.hint | test("Starter Plus \\(8 GB") and test("Starter \\(4 GB\\)")' "$MF"
arm "manifest: semver version"                          jq -e '.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$MF"
arm "marketplace: one plugin, sourced from ./laya (trap D)" jq -e '(.plugins | length) == 1 and .plugins[0].source == "./laya" and .plugins[0].name == "laya"' "$MK"
arm "verb: no subcommand that makes a decision"         bash -c '! grep -qE "^\s+(decide|predict|ask|route|choose)\)" "$1"' _ "$PLUGIN_DIR/bin/laya"
arm "verb: unknown subcommand exits 64"                 bash -c '"$1" frobnicate; [[ $? == 64 ]]' _ "$VERB"

printf '\n%d arms, %d passed, %d failed\n' "$ARMS" "$((ARMS - FAILED))" "$FAILED"
if (( FAILED )); then printf 'failed: %s\n' "${FAILED_NAMES[@]}"; exit 1; fi
(( ARMS > 0 )) || { echo "no arms ran"; exit 1; }
