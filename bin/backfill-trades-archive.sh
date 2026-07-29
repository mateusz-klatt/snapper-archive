#!/usr/bin/env bash
# Drive export-trades-day.sh across the whole event-time range, oldest first.
#
# Idempotent: a day already recorded in TRADES-MANIFEST.tsv is skipped, so an
# interrupted run is resumed by re-invoking with the same arguments. Read-only
# with respect to the trades table — it never deletes, and it takes no locks
# beyond what a COPY needs, so it is safe to abort at any point.
#
# The production trading host also carries latency-sensitive network traffic,
# so every day is exported under nice/ionice and the loop parks itself whenever
# load per CPU rises above the ceiling rather than competing with production.
set -euo pipefail
set +x

ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
BIN="$ROOT/bin"
MANIFEST="$ROOT/TRADES-MANIFEST.tsv"
LOG="$ROOT/logs/trades-backfill-$(date -u +%Y-%m).log"
FROM=${FROM:?set FROM=YYYY-MM-DD}
TO=${TO:?set TO=YYYY-MM-DD}
LOAD_CEILING=${LOAD_CEILING:-3.0}
PARK_SECONDS=${PARK_SECONDS:-120}
MIN_FREE_GB=${MIN_FREE_GB:-100}

mkdir -p "$ROOT/logs"
exec 9>"$ROOT/.trades-backfill.lock"
flock -n 9 || { echo "$(date -u +%FT%TZ) SKIP: another backfill holds the lock" >>"$LOG"; exit 0; }
exec >>"$LOG" 2>&1

CPUS=$(nproc)
echo "=== trades backfill $(date -u +%FT%TZ) range=${FROM}..${TO} ceiling=${LOAD_CEILING}/cpu ==="

ok=0; skip=0; fail=0
day="$FROM"
while [[ "$day" < "$TO" || "$day" == "$TO" ]]; do
  if [[ -f "$MANIFEST" ]] && cut -f2 "$MANIFEST" | grep -qx "$day"; then
    skip=$((skip + 1))
    day=$(date -u -d "$day +1 day" +%F)
    continue
  fi

  free_gb=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
  if (( free_gb < MIN_FREE_GB )); then
    echo "$(date -u +%FT%TZ) ABORT: archive free ${free_gb}G below ${MIN_FREE_GB}G floor"
    exit 1
  fi

  while :; do
    load=$(awk '{print $1}' /proc/loadavg)
    per_cpu=$(awk -v l="$load" -v c="$CPUS" 'BEGIN{printf "%.2f", l/c}')
    if awk -v p="$per_cpu" -v c="$LOAD_CEILING" 'BEGIN{exit !(p <= c)}'; then break; fi
    echo "$(date -u +%FT%TZ) PARK: load ${per_cpu}/cpu above ${LOAD_CEILING}, waiting ${PARK_SECONDS}s"
    sleep "$PARK_SECONDS"
  done

  started=$(date -u +%s)
  if nice -n19 ionice -c3 "$BIN/export-trades-day.sh" "$day"; then
    elapsed=$(( $(date -u +%s) - started ))
    line=$(grep -P "^trades-${day}\.csv\.zst\t" "$MANIFEST" | tail -1)
    rows=$(echo "$line" | cut -f5); bytes=$(echo "$line" | cut -f6)
    mb=$(( (bytes + 1048575) / 1048576 ))
    free_after=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
    echo "$(date -u +%FT%TZ) OK   ${day}  rows=${rows}  ${mb}MB  ${elapsed}s  free=${free_after}G"
    ok=$((ok + 1))
  else
    echo "$(date -u +%FT%TZ) FAIL ${day} — stopping so the failure is not buried"
    fail=$((fail + 1))
    break
  fi

  day=$(date -u -d "$day +1 day" +%F)
done

echo "=== trades backfill done $(date -u +%FT%TZ): ok=${ok} skip=${skip} fail=${fail} ==="
