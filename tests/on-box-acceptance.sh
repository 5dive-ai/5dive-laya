#!/usr/bin/env bash
# On-box acceptance for 5dive-laya (DIVE-4965). Run as root on a THROWAWAY
# 8 GB test box that has the 5dive CLI (>= 0.53, which carries reflex-endpoint).
# It installs the plugin, measures it, and uninstalls it:
#
#   sudo bash tests/on-box-acceptance.sh [<plugin source, default 5dive-ai/5dive-laya>]
#
# It prints one line per check and ends with a JSON summary: the disk and
# resident-RAM numbers the wiki page needs, and a pass/fail per acceptance
# criterion. Setup downloads about 3 GB, so expect a few minutes.
#
# The replay (Laya's numbers against Jev's) is not run here. The corpus lives
# on the control plane, so it is run THERE, through an SSH tunnel to this box
# while Laya is up. Pass --keep-up to stop before uninstalling, run the replay,
# then re-run with --uninstall-only.
set -uo pipefail
SRC="5dive-ai/5dive-laya"; KEEP_UP=0; UNINSTALL_ONLY=0
for a in "$@"; do
  case "$a" in
    --keep-up) KEEP_UP=1 ;;
    --uninstall-only) UNINSTALL_ONLY=1 ;;
    -*) echo "unknown flag $a" >&2; exit 64 ;;
    *) SRC="$a" ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }

PASS=0; FAIL=0; declare -A CRIT
check() {  # check <criterion-key> <label> <command...>
  local k="$1" l="$2"; shift 2
  if "$@" >/dev/null 2>&1; then echo "ok   $l"; PASS=$((PASS+1)); [[ "${CRIT[$k]:-}" == false ]] || CRIT[$k]=true
  else echo "FAIL $l"; FAIL=$((FAIL+1)); CRIT[$k]=false; fi
}
EP="http://127.0.0.1:8767/v1/systemone"
mem_avail() { awk '/^MemAvailable:/ {print $2}' /proc/meminfo; }
disk_used() { df -Pk / | awk 'NR==2 {print $3}'; }

if (( ! UNINSTALL_ONLY )); then
  echo "== box: $(hostname) · $(nproc) cpu · $(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo) MiB RAM · 5dive $(5dive --version 2>/dev/null)"
  DISK0=$(disk_used); MEM0=$(mem_avail)

  echo "== install"
  5dive plugin add "$SRC" --yes || { echo "plugin add failed"; exit 1; }
  T0=$(date +%s)
  5dive laya setup || { echo "laya setup failed"; exit 1; }
  SETUP_S=$(( $(date +%s) - T0 ))
  DISK1=$(disk_used)

  echo "== checks"
  check bind "unit binds 127.0.0.1 only (ss)" bash -c '[[ -n "$(ss -ltnH "sport = :8767")" ]] && ! ss -ltnH "sport = :8767" | awk "{print \$4}" | grep -vqE "^(127\.0\.0\.1|\[::1\]):8767$"'
  check bind "unit file: LAYA_HOST=127.0.0.1" grep -qx 'Environment=LAYA_HOST=127.0.0.1' /etc/systemd/system/5dive-reflex-laya.service
  check preload "unit file: LAYA_PRELOAD=0" grep -qx 'Environment=LAYA_PRELOAD=0' /etc/systemd/system/5dive-reflex-laya.service
  check preload "nothing loaded before the first decision" bash -c 'curl -fsS -m3 http://127.0.0.1:8767/health | jq -e ".loaded == []"'
  PUB=$(hostname -I | awk '{print $1}')
  check bind "not reachable on the box's own address ($PUB)" bash -c "! curl -sS -m3 http://$PUB:8767/health"
  RS=$(5dive reflex status --probe --json 2>/dev/null)
  echo "$RS" | jq -c '{endpoint, provider, api, model, configured, health}'
  check reflex "reflex status: configured" jq -e '.configured == true' <<<"$RS"
  check reflex "reflex status: probe healthy" jq -e '.health.ok == true' <<<"$RS"
  check reflex "reflex status: endpoint is Laya" jq -e --arg e "$EP" '.endpoint == $e' <<<"$RS"

  echo "== one decision (loads typed-decisions lazily)"
  BODY='{"model":"typed-decisions","state":{"task":"Fix the login page CSS on the dashboard"},"questions":{"decision":{"type":"choice","instructions":"Which seat should build this?","criteria":{"dev":"builds CLI, API, frontend and plugins","ops":"runs host scripts, cron, deploys and CI"}}}}'
  T0=$(date +%s%N)
  ANS=$(curl -fsS -m 120 -H 'content-type: application/json' -d "$BODY" "$EP")
  COLD_MS=$(( ($(date +%s%N) - T0) / 1000000 ))
  T0=$(date +%s%N); curl -fsS -m 60 -H 'content-type: application/json' -d "$BODY" "$EP" >/dev/null; WARM_MS=$(( ($(date +%s%N) - T0) / 1000000 ))
  echo "$ANS" | jq -c '.answers // .'
  check reflex "decision answered with a choice" jq -e '.answers.decision.choice | type == "string"' <<<"$ANS"
  LS=$(5dive laya status --json)
  check health "5dive laya status: healthy" jq -e '.healthy == true' <<<"$LS"
  RSS_KB=$(jq -r '.resident_kb // 0' <<<"$LS"); LAYA_DISK_KB=$(jq -r '.disk_kb // 0' <<<"$LS")
  MEM1=$(mem_avail)
  echo "resident: $((RSS_KB/1024)) MiB · plugin disk: $((LAYA_DISK_KB/1024)) MiB · root fs grew $(( (DISK1-DISK0)/1024 )) MiB · MemAvailable fell $(( (MEM0-MEM1)/1024 )) MiB · setup ${SETUP_S}s · cold ${COLD_MS}ms · warm ${WARM_MS}ms"

  if (( KEEP_UP )); then
    echo "== left UP for the replay tunnel. Afterwards: sudo bash $0 --uninstall-only"
    jq -nc --argjson rss "$RSS_KB" --argjson disk "$LAYA_DISK_KB" --argjson s "$SETUP_S" --argjson c "$COLD_MS" --argjson w "$WARM_MS" \
      --argjson p "$PASS" --argjson f "$FAIL" '{resident_kb:$rss, disk_kb:$disk, setup_s:$s, cold_ms:$c, warm_ms:$w, pass:$p, fail:$f}'
    exit $(( FAIL > 0 ))
  fi
fi

echo "== uninstall"
5dive laya uninstall || echo "laya uninstall exited $?"
check uninstall "unit gone" bash -c '! systemctl cat 5dive-reflex-laya.service'
check uninstall "nothing on :8767" bash -c '[[ -z "$(ss -ltnH "sport = :8767")" ]]'
check uninstall "reflex endpoint back to default" bash -c '5dive config --json | jq -e ".data.reflex_endpoint == \"default\""'
check uninstall "plugin removed" bash -c '! 5dive plugin list 2>/dev/null | grep -q "^  laya@"'
check uninstall "files gone" bash -c '[[ ! -e /opt/5dive-laya && ! -e /var/lib/5dive-laya ]]'

crit_json() { local k o="{}"; for k in "${!CRIT[@]}"; do o=$(jq -c --arg k "$k" --argjson v "${CRIT[$k]}" '. + {($k): $v}' <<<"$o"); done; printf '%s' "$o"; }
jq -nc --argjson rss "${RSS_KB:-null}" --argjson disk "${LAYA_DISK_KB:-null}" --argjson s "${SETUP_S:-null}" \
  --argjson c "${COLD_MS:-null}" --argjson w "${WARM_MS:-null}" --argjson crit "$(crit_json)" \
  --argjson p "$PASS" --argjson f "$FAIL" \
  '{resident_kb:$rss, disk_kb:$disk, setup_s:$s, cold_ms:$c, warm_ms:$w, criteria:$crit, pass:$p, fail:$f}'
exit $(( FAIL > 0 ))
