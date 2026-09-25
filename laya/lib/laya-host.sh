# shellcheck shell=bash
# laya-host.sh: the host half of the 5dive-laya plugin (DIVE-4965).
#
# This plugin makes Laya (a local typed-decision model) available as a provider
# for core `5dive reflex`, and does nothing else. It stays below the provider
# boundary. It installs Laya, runs ONE shared service per host, points reflex's
# existing `reflex-endpoint` setting at it, checks its health, and takes all of
# that back out. It has no decision API, no agent-facing command, no routing
# and no policy. `5dive reflex` stays the feature and Laya is only an engine
# behind it (lodar's proposal, 2026-09-24, on DIVE-4932).
#
# Sourced by bin/laya. Every path is under $LAYA_ROOT, which is empty on a
# real box. The test suite points it at a throwaway tree and puts stub
# systemctl/ss/curl/5dive programs on PATH, so this whole lifecycle runs in CI
# without root, torch or a network.

# ---- pinned versions ---------------------------------------------------------
# Laya is young (repo created 2026-09-18, releases every few days), so the
# version is pinned. A release can change the wire format or the checkpoint
# layout, and a plugin upgrade is the deliberate act that moves it. torch
# comes from the CPU wheel index because no 5dive box has a GPU. The default
# PyPI torch drags in ~3 GB of CUDA libraries that would never be loaded.
LAYA_VERSION="0.3.20"
LAYA_TORCH_VERSION="2.14.0"
LAYA_TORCH_INDEX="https://download.pytorch.org/whl/cpu"
# The one checkpoint reflex asks for (`reflex-model=typed-decisions`). Setup
# fetches only this one, and nothing else is ever preloaded.
LAYA_CHECKPOINT="typed-decisions"

# ---- the address. NOT overridable, on purpose --------------------------------
# Laya's own defaults are LAYA_HOST=0.0.0.0 and LAYA_PRELOAD=1 (every
# checkpoint). A reflex port reachable from the internet is the failure this
# plugin exists to prevent, so the host is a constant, not an env read. The
# suite exports LAYA_HOST=0.0.0.0 and LAYA_PRELOAD=1 while rendering to prove
# neither leaks into the unit.
LAYA_BIND_HOST="127.0.0.1"
LAYA_BIND_PORT="8767"          # 8765 is voice's whisper service; 8000 is everyone's dev server
LAYA_PRELOAD_VALUE="0"

LAYA_UNIT_NAME="5dive-reflex-laya.service"
LAYA_USER="5dive-laya"

# ---- host sizing (the proposal's RAM policy) ---------------------------------
# Starter (4 GB) stays on a remote reflex provider. Starter Plus (8 GB) is the
# minimum for a local Laya. A nominal 8 GB box reports ~7.7 GiB in MemTotal, so
# the floor is 7 GiB, not 8.
LAYA_MIN_MEM_KB=$((7 * 1024 * 1024))
# The CPU torch wheel, laya[serve] and one checkpoint, with headroom. The real
# number is measured on the test box and posted on the wiki page.
LAYA_MIN_DISK_KB=$((4 * 1024 * 1024))

LAYA_ROOT="${LAYA_ROOT:-}"
laya_paths() {
  LAYA_OPT="$LAYA_ROOT/opt/5dive-laya"
  LAYA_VENV="$LAYA_OPT/venv"
  LAYA_STATE="$LAYA_ROOT/var/lib/5dive-laya"
  LAYA_HF_HOME="$LAYA_STATE/hf"
  LAYA_STATE_FILE="$LAYA_STATE/state.json"
  LAYA_UNIT_FILE="$LAYA_ROOT/etc/systemd/system/$LAYA_UNIT_NAME"
  LAYA_MEMINFO="${LAYA_MEMINFO:-/proc/meminfo}"
}
laya_paths

laya_endpoint_url() { printf 'http://%s:%s/v1/systemone' "$LAYA_BIND_HOST" "$LAYA_BIND_PORT"; }
laya_health_url()   { printf 'http://%s:%s/health' "$LAYA_BIND_HOST" "$LAYA_BIND_PORT"; }

laya_die()  { printf '5dive laya: %s\n' "$1" >&2; exit "${2:-1}"; }
laya_say()  { printf '%s\n' "$*"; }
laya_step() { printf '\n== %s ==\n' "$*"; }

# The EUID seen by the root checks. Only a test tree (LAYA_ROOT set) may
# override it, because agent seats cannot run as root to test the root path.
laya_euid() {
  if [[ -n "$LAYA_ROOT" && -n "${LAYA_TEST_EUID:-}" ]]; then printf '%s' "$LAYA_TEST_EUID"; else printf '%s' "$EUID"; fi
}
laya_require_root() {  # laya_require_root <the subcommand, for the sudo line>
  [[ "$(laya_euid)" -eq 0 ]] || laya_die "this changes the host (a system service and the reflex endpoint), so it needs root. Run: sudo 5dive laya $1"
}

# ---- the unit ----------------------------------------------------------------
# laya_render_unit: prints the systemd unit to stdout. It is a pure function of
# the constants above, so the suite can grade it byte by byte.
#
# There are two separate layers against exposure:
#   1. LAYA_HOST=127.0.0.1 makes uvicorn bind loopback only (laya/serve.py:293).
#   2. IPAddressDeny=any plus IPAddressAllow=localhost is a cgroup firewall
#      applied by systemd. If a later Laya release ignores LAYA_HOST, the port
#      still answers only 127.0.0.1/::1, and nothing on the service can reach out.
# HF_HUB_OFFLINE=1 is why (2) costs nothing. Setup fetches the checkpoint ahead
# of time, so the running service never needs the network.
laya_render_unit() {
  cat <<UNIT
# Written by the 5dive-laya plugin (sudo 5dive laya setup). Removed by: sudo 5dive laya uninstall
# One shared Laya per host, loopback only, lazy-loaded: the local provider for 5dive reflex.
[Unit]
Description=Laya local provider for 5dive reflex (5dive-laya plugin)
After=network.target

[Service]
Type=simple
User=$LAYA_USER
Group=$LAYA_USER
Environment=LAYA_HOST=$LAYA_BIND_HOST
Environment=LAYA_PORT=$LAYA_BIND_PORT
Environment=LAYA_PRELOAD=$LAYA_PRELOAD_VALUE
Environment=LAYA_LOG_LEVEL=warning
Environment=HF_HOME=${LAYA_HF_HOME#"$LAYA_ROOT"}
Environment=HF_HUB_OFFLINE=1
Environment=HF_HUB_DISABLE_TELEMETRY=1
ExecStart=${LAYA_VENV#"$LAYA_ROOT"}/bin/laya-serve
Restart=on-failure
RestartSec=5
Nice=10
MemoryMax=4G
IPAddressDeny=any
IPAddressAllow=localhost
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${LAYA_STATE#"$LAYA_ROOT"}

[Install]
WantedBy=multi-user.target
UNIT
}

# ---- the bind check ----------------------------------------------------------
# laya_bind_verdict <ss -ltnH output>: prints loopback | exposed | down.
# Every listener on our port must be 127.0.0.1 or ::1. One wildcard or public
# address anywhere makes the verdict "exposed", even alongside a loopback one.
laya_bind_verdict() {
  local out="$1" line addr any=0 bad=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # ss -ltnH columns: State Recv-Q Send-Q Local:Port Peer:Port [Process]
    addr=$(awk '{print $4}' <<<"$line")
    [[ "$addr" == *":$LAYA_BIND_PORT" ]] || continue
    any=1
    addr="${addr%:"$LAYA_BIND_PORT"}"
    addr="${addr%%%*}"              # drop an interface scope such as 127.0.0.1%lo
    case "$addr" in
      127.0.0.1|'[::1]'|::1) ;;
      *) bad=1 ;;
    esac
  done <<<"$out"
  if (( bad )); then printf 'exposed'; elif (( any )); then printf 'loopback'; else printf 'down'; fi
}
laya_bind_now() { laya_bind_verdict "$(ss -ltnH "sport = :$LAYA_BIND_PORT" 2>/dev/null)"; }

# ---- reflex config -----------------------------------------------------------
laya_config_json() { 5dive config --json 2>/dev/null | jq -c '.data // .' 2>/dev/null; }
laya_reflex_points_here() {
  [[ "$(laya_config_json | jq -r '.reflex_endpoint // empty' 2>/dev/null)" == "$(laya_endpoint_url)" ]]
}

laya_health_json() { curl -fsS -m "${1:-3}" "$(laya_health_url)" 2>/dev/null; }

laya_mem_total_kb() { awk '/^MemTotal:/ {print $2; exit}' "$LAYA_MEMINFO" 2>/dev/null; }
laya_disk_free_kb() {
  local d="$LAYA_ROOT/"; [[ -d "$LAYA_ROOT/opt" ]] && d="$LAYA_ROOT/opt"
  df -Pk "$d" 2>/dev/null | awk 'NR==2 {print $4}'
}
laya_main_pid() { systemctl show -p MainPID --value "$LAYA_UNIT_NAME" 2>/dev/null; }
laya_rss_kb() {
  local pid; pid=$(laya_main_pid)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  awk '/^VmRSS:/ {print $2; exit}' "$LAYA_ROOT/proc/$pid/status" 2>/dev/null
}
laya_disk_used_kb() {
  local paths=() p
  for p in "$LAYA_OPT" "$LAYA_STATE"; do [[ -e "$p" ]] && paths+=("$p"); done
  (( ${#paths[@]} )) || { printf 0; return; }
  du -sk "${paths[@]}" 2>/dev/null | awk '{s += $1} END {print s + 0}'
}

laya_write_atomic() {  # laya_write_atomic <dst> <mode>, content on stdin
  local dst="$1" mode="$2" tmp
  mkdir -p "$(dirname "$dst")"
  tmp=$(mktemp "$(dirname "$dst")/.$(basename "$dst").XXXXXX") || laya_die "could not write in $(dirname "$dst")"
  cat > "$tmp" || { rm -f "$tmp"; laya_die "could not write $dst"; }
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; laya_die "could not install $dst"; }
}

laya_installed_version() {
  [[ -x "$LAYA_VENV/bin/python" ]] || return 1
  "$LAYA_VENV/bin/python" -c 'import importlib.metadata as m; print(m.version("laya"))' 2>/dev/null
}

# ---- setup -------------------------------------------------------------------
laya_setup() {
  local allow_small=0 a
  for a in "$@"; do
    case "$a" in
      --allow-small-host) allow_small=1 ;;
      *) laya_die "unknown flag '$a' (usage: sudo 5dive laya setup [--allow-small-host])" 64 ;;
    esac
  done
  laya_require_root setup
  command -v jq >/dev/null 2>&1 || laya_die "jq is required"
  command -v 5dive >/dev/null 2>&1 || laya_die "the 5dive CLI is not on PATH, so there is no reflex to point at Laya"

  laya_step "preflight"
  local mem; mem=$(laya_mem_total_kb)
  [[ "$mem" =~ ^[0-9]+$ ]] || laya_die "could not read MemTotal from $LAYA_MEMINFO"
  if (( mem < LAYA_MIN_MEM_KB )) && (( ! allow_small )); then
    laya_die "this host has $((mem / 1024)) MiB of RAM. A local Laya needs Starter Plus (8 GB) or larger; on Starter (4 GB), keep reflex on its remote provider. Nothing was installed. (--allow-small-host overrides this at your own risk.)"
  fi
  laya_say "RAM: $((mem / 1024)) MiB"
  if ! laya_installed_version >/dev/null; then
    local free; free=$(laya_disk_free_kb)
    [[ "$free" =~ ^[0-9]+$ ]] || laya_die "could not read free disk space"
    (( free >= LAYA_MIN_DISK_KB )) \
      || laya_die "only $((free / 1024)) MiB free on disk. Laya, CPU torch and one checkpoint need about $((LAYA_MIN_DISK_KB / 1024)) MiB. Nothing was installed."
    laya_say "disk free: $((free / 1024)) MiB"
  fi
  # A listener on our port that is not our unit is someone else's service.
  # Refuse, rather than point reflex at it.
  if [[ "$(laya_bind_now)" != down ]] && ! systemctl is-active --quiet "$LAYA_UNIT_NAME" 2>/dev/null; then
    laya_die "port $LAYA_BIND_PORT is already in use by something that is not $LAYA_UNIT_NAME. Free it first; nothing was installed."
  fi

  laya_step "service account and directories"
  if ! id -u "$LAYA_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "${LAYA_STATE#"$LAYA_ROOT"}" --no-create-home --shell /usr/sbin/nologin "$LAYA_USER" \
      || laya_die "could not create the $LAYA_USER system user"
  fi
  mkdir -p "$LAYA_OPT" "$LAYA_HF_HOME"
  chown -R "$LAYA_USER:$LAYA_USER" "$LAYA_STATE" 2>/dev/null || true
  chmod 750 "$LAYA_STATE"
  laya_say "user $LAYA_USER; state in ${LAYA_STATE#"$LAYA_ROOT"}"

  laya_step "Laya $LAYA_VERSION (CPU torch $LAYA_TORCH_VERSION)"
  if [[ "$(laya_installed_version)" == "$LAYA_VERSION" ]]; then
    laya_say "already installed"
  else
    if [[ ! -x "$LAYA_VENV/bin/python" ]]; then
      python3 -m venv "$LAYA_VENV" 2>/dev/null || {
        # Ubuntu ships python3 without ensurepip, and the venv package adds it.
        apt-get install -y -qq python3-venv >/dev/null 2>&1 && python3 -m venv "$LAYA_VENV"
      } || laya_die "could not create a Python venv at $LAYA_VENV (python3 >= 3.10 with venv support is required)"
    fi
    "$LAYA_VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
    "$LAYA_VENV/bin/pip" install -q --index-url "$LAYA_TORCH_INDEX" "torch==$LAYA_TORCH_VERSION" \
      || laya_die "installing CPU torch $LAYA_TORCH_VERSION failed"
    "$LAYA_VENV/bin/pip" install -q "laya[serve]==$LAYA_VERSION" \
      || laya_die "installing laya[serve]==$LAYA_VERSION failed"
    [[ "$(laya_installed_version)" == "$LAYA_VERSION" ]] \
      || laya_die "laya installed but reports '$(laya_installed_version)', not $LAYA_VERSION"
  fi

  laya_step "checkpoint: $LAYA_CHECKPOINT"
  # Fetched now, as the service user, by Laya's own loader. The running service
  # is offline (HF_HUB_OFFLINE=1) and would otherwise fail its first decision.
  # Loading it once here also shows that the install works before reflex is
  # pointed at it.
  runuser -u "$LAYA_USER" -- env HF_HOME="$LAYA_HF_HOME" HF_HUB_DISABLE_TELEMETRY=1 \
    "$LAYA_VENV/bin/python" -c "from laya.router import Router; Router().preload(['$LAYA_CHECKPOINT'])" \
    || laya_die "fetching the $LAYA_CHECKPOINT checkpoint failed (it downloads from Hugging Face)"

  laya_step "service: $LAYA_UNIT_NAME"
  laya_render_unit | laya_write_atomic "$LAYA_UNIT_FILE" 644
  systemctl daemon-reload
  systemctl enable "$LAYA_UNIT_NAME" >/dev/null 2>&1 || laya_die "systemctl enable $LAYA_UNIT_NAME failed"
  systemctl restart "$LAYA_UNIT_NAME" || laya_die "systemctl restart $LAYA_UNIT_NAME failed. See: 5dive laya logs"

  local i ok=0
  for ((i = 0; i < ${LAYA_HEALTH_WAIT:-60}; i++)); do
    if laya_health_json 2 | jq -e '.status == "ok"' >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  (( ok )) || laya_die "$LAYA_UNIT_NAME did not answer $(laya_health_url) within ${LAYA_HEALTH_WAIT:-60}s, so reflex was NOT pointed at it. See: 5dive laya logs"

  # The bind is checked on the live socket and fails closed. Reflex is never
  # pointed at a Laya reachable from off the box. The service is stopped and
  # stays stopped.
  local bind; bind=$(laya_bind_now)
  if [[ "$bind" != loopback ]]; then
    systemctl disable --now "$LAYA_UNIT_NAME" >/dev/null 2>&1 || true
    laya_die "$LAYA_UNIT_NAME is listening on something other than $LAYA_BIND_HOST (verdict: $bind), so it was stopped and reflex was NOT pointed at it."
  fi
  laya_say "listening on $LAYA_BIND_HOST:$LAYA_BIND_PORT only; preload off"

  laya_step "reflex"
  local cfg; cfg=$(laya_config_json)
  # The config reflex had before is recorded ONCE, on the first setup. A
  # re-run would otherwise record our own endpoint as "previous".
  if [[ ! -s "$LAYA_STATE_FILE" ]] && ! laya_reflex_points_here; then
    jq -n --argjson c "${cfg:-null}" --arg at "$(date -u +%FT%TZ)" \
      '{recorded_at:$at,
        previous:{endpoint:($c.reflex_endpoint // null), model:($c.reflex_model // null),
                  model_source:($c.reflex_model_source // null)}}' \
      | laya_write_atomic "$LAYA_STATE_FILE" 600
  fi
  5dive config "reflex-endpoint=$(laya_endpoint_url)" "reflex-model=$LAYA_CHECKPOINT" >/dev/null \
    || laya_die "5dive config refused the Laya endpoint. The service is up, but reflex still uses its previous provider"
  laya_say "reflex-endpoint = $(laya_endpoint_url)"
  laya_say "reflex-model    = $LAYA_CHECKPOINT"

  printf '\nDone. Laya is this box'"'"'s reflex provider. It runs in shadow like any reflex provider, so no policy acts on it.\n'
  printf 'Check it:  5dive laya          5dive reflex status --probe\n'
  printf 'Undo it:   sudo 5dive laya uninstall\n'
}

# ---- uninstall ---------------------------------------------------------------
laya_uninstall() {
  local keep_plugin=0 a
  for a in "$@"; do
    case "$a" in
      --keep-plugin) keep_plugin=1 ;;
      *) laya_die "unknown flag '$a' (usage: sudo 5dive laya uninstall [--keep-plugin])" 64 ;;
    esac
  done
  laya_require_root uninstall

  laya_step "reflex"
  # Reflex goes back to its default endpoint only if it still points at us.
  # If someone repointed it after setup, that was their choice. Leave it.
  if laya_reflex_points_here; then
    local model="default" prev_src prev_model
    if [[ -r "$LAYA_STATE_FILE" ]]; then
      prev_src=$(jq -r '.previous.model_source // ""' "$LAYA_STATE_FILE" 2>/dev/null)
      prev_model=$(jq -r '.previous.model // ""' "$LAYA_STATE_FILE" 2>/dev/null)
      # Only a model the owner had SET explicitly is restored. A default stays
      # a default, so it moves if the CLI's default moves.
      [[ "$prev_src" == "box setting" && -n "$prev_model" ]] && model="$prev_model"
    fi
    5dive config reflex-endpoint=default "reflex-model=$model" >/dev/null \
      || laya_die "5dive config refused to reset the reflex endpoint. Nothing else was removed. Run: sudo 5dive config reflex-endpoint=default reflex-model=default"
    laya_say "reflex-endpoint = default; reflex-model = $model"
  else
    laya_say "reflex does not point at Laya. Its endpoint is left as it is."
  fi

  laya_step "service"
  systemctl disable --now "$LAYA_UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$LAYA_UNIT_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$LAYA_UNIT_NAME" >/dev/null 2>&1 || true
  laya_say "$LAYA_UNIT_NAME stopped and removed"

  laya_step "files"
  rm -rf "$LAYA_OPT" "$LAYA_STATE"
  if id -u "$LAYA_USER" >/dev/null 2>&1; then userdel "$LAYA_USER" >/dev/null 2>&1 || true; fi
  laya_say "removed ${LAYA_OPT#"$LAYA_ROOT"} and ${LAYA_STATE#"$LAYA_ROOT"} (venv and checkpoint), and the $LAYA_USER user"

  # Last, because it deletes this script's own directory. bash already holds
  # the file open, and exec hands the process to the CLI.
  if (( ! keep_plugin )) && [[ -n "${FIVEDIVE_PLUGIN_KEY:-}" ]]; then
    laya_step "plugin"
    exec 5dive plugin remove "$FIVEDIVE_PLUGIN_KEY"
  fi
  (( keep_plugin )) || laya_say "To remove the plugin itself: sudo 5dive plugin remove laya"
}

# ---- status ------------------------------------------------------------------
laya_status() {
  local json="${FIVEDIVE_JSON_MODE:-0}" a
  for a in "$@"; do
    case "$a" in --json) json=1 ;; *) laya_die "unknown flag '$a' (usage: 5dive laya status [--json])" 64 ;; esac
  done
  local unit_present=false active health bind here=false ver rss disk healthy=false
  [[ -f "$LAYA_UNIT_FILE" ]] && unit_present=true
  active=$(systemctl is-active "$LAYA_UNIT_NAME" 2>/dev/null); active="${active:-unknown}"
  health=$(laya_health_json 3); jq -e 'type == "object"' >/dev/null 2>&1 <<<"$health" || health=null
  bind=$(laya_bind_now)
  laya_reflex_points_here && here=true
  ver=$(laya_installed_version || true)
  rss=$(laya_rss_kb || true); [[ "$rss" =~ ^[0-9]+$ ]] || rss=null
  disk=$(laya_disk_used_kb || true); [[ "$disk" =~ ^[0-9]+$ ]] || disk=null
  if [[ "$active" == active && "$bind" == loopback && "$health" != null ]] \
       && jq -e '.status == "ok"' >/dev/null 2>&1 <<<"$health"; then healthy=true; fi

  local body
  body=$(jq -nc --arg unit "$LAYA_UNIT_NAME" --argjson present "$unit_present" --arg active "$active" \
    --arg bind "$bind" --arg addr "$LAYA_BIND_HOST:$LAYA_BIND_PORT" --argjson health "$health" \
    --argjson here "$here" --arg ep "$(laya_endpoint_url)" --arg ver "${ver:-}" --arg pin "$LAYA_VERSION" \
    --argjson rss "$rss" --argjson disk "$disk" --argjson healthy "$healthy" \
    '{healthy:$healthy, unit:$unit, unit_installed:$present, active:$active, bind:$bind, address:$addr,
      health:$health, reflex_points_here:$here, endpoint:$ep,
      laya_version:(if $ver == "" then null else $ver end), laya_pinned:$pin,
      resident_kb:$rss, disk_kb:$disk}')
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$body"
  else
    jq -r '"laya — local reflex provider (\(.address))",
      "  service     \(.unit): \(.active)\(if .unit_installed then "" else " (not installed)" end)",
      "  bind        \(if .bind == "loopback" then "loopback only" elif .bind == "exposed" then "EXPOSED: listening beyond 127.0.0.1. Stop it: sudo systemctl stop \(.unit)" else "not listening" end)",
      "  health      \(if .health then "ok · loaded \(.health.loaded // [] | if length == 0 then "nothing yet (lazy)" else join(",") end)" else "no answer" end)",
      "  reflex      \(if .reflex_points_here then "points here" else "points elsewhere" end)",
      "  laya        \(.laya_version // "not installed") (pinned \(.laya_pinned))",
      "  resident    \(if .resident_kb then "\(.resident_kb / 1024 | floor) MiB" else "-" end)",
      "  disk        \(if .disk_kb then "\(.disk_kb / 1024 | floor) MiB" else "-" end)"' <<<"$body"
    [[ "$healthy" == true ]] || printf '\nNot healthy. Install or repair: sudo 5dive laya setup    logs: 5dive laya logs\n'
  fi
  [[ "$healthy" == true ]]
}

laya_health() {
  local h; h=$(laya_health_json 3) || { printf 'down: nothing answered %s\n' "$(laya_health_url)" >&2; return 1; }
  printf '%s\n' "$h"
  jq -e '.status == "ok"' >/dev/null 2>&1 <<<"$h"
}

laya_logs() { exec journalctl -u "$LAYA_UNIT_NAME" --no-pager -n "${LAYA_LOG_LINES:-100}" "$@"; }
