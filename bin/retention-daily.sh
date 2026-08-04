#!/usr/bin/env bash
# Rolling 7d ticks retention. Exports + purges every tick day that has fallen
# out of the horizon, oldest first. Idempotent: days already in MANIFEST.tsv are
# skipped, so a missed cron run is caught up by the next one.
#
# Horizon lowered 30 -> 7 on 2026-07-29, after the 30d table reached 354 GB and
# forced a TRUNCATE. Measured regrowth is ~7.3 GB/day overnight and higher with
# the US session, so 30d trends back to ~250-330 GB while 7d holds ~50-80 GB.
# Ticks exist only to rebuild candles; every purged day is in the archive first, so a
# longer window can be restored from the archive if it is ever needed.
set -euo pipefail
set +x

ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
BIN="$ROOT/bin"
HORIZON_DAYS=${HORIZON_DAYS:-7}
MAX_DAYS_PER_RUN=${MAX_DAYS_PER_RUN:-3}
MIN_FREE_GB=${MIN_FREE_GB:-50}
LOG="$ROOT/logs/retention-$(date -u +%Y-%m).log"
mkdir -p "$ROOT/logs"

exec 9>"$ROOT/.retention.lock"
flock -n 9 || { echo "$(date -u +%FT%TZ) SKIP: another retention run holds the lock" >>"$LOG"; exit 0; }
exec >>"$LOG" 2>&1

# Failure alerting. Sourced AFTER the flock check so a legitimate skip never
# pages anyone, and after the redirect so there is a log to summarise. A missing
# helper is fatal on purpose: this job's failures would otherwise go nowhere,
# and cron's MAILTO still catches an abort at this point.
. "$(dirname -- "${BASH_SOURCE[0]}")/_alert.sh"
snapper_alert_on_failure "retention-daily" "$LOG"

echo "=== retention-daily $(date -u +%FT%TZ) horizon=${HORIZON_DAYS}d ==="

FREE_GB=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
if (( FREE_GB < MIN_FREE_GB )); then
  echo "ABORT: archive disk has ${FREE_GB}G free, below ${MIN_FREE_GB}G floor"
  exit 1
fi
echo "archive disk free=${FREE_GB}G  root free=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')G"

ENV_FILE=${SNAPPER_ENV_FILE:?set SNAPPER_ENV_FILE to the .env file containing DB_URL}
RAW=$(grep -E '^DB_URL=' "$ENV_FILE" | cut -d= -f2-)
u=${RAW#*//}; creds=${u%%@*}; export PGPASSWORD=${creds#*:}
DB_HOST_TO=${SNAPPER_DB_HOST_TO:?set SNAPPER_DB_HOST_TO to the database host reachable from this host}
PSQL="psql -h $DB_HOST_TO -U ${creds%%:*} -d snapper -X -qtA -v ON_ERROR_STOP=1"

# Oldest surviving day, read off the PK (instant) rather than min(timestamp),
# which has no supporting index and seq-scans the whole table.
# The timeout matters: with a large backlog of dead tuples at the low end of
# ticks_pkey (i.e. a purge that has not been vacuumed yet) this probe walks every
# dead entry before reaching a live row. Fail loudly in a minute instead of
# hanging a cron job for hours.
OLDEST=$($PSQL -c "SET statement_timeout='60s'" -c 'SELECT "timestamp"::date FROM ticks ORDER BY id LIMIT 1') || {
  echo "ABORT: cannot read oldest tick (is a VACUUM of ticks pending?)"; exit 1; }
CUTOFF=$(date -u -d "today - ${HORIZON_DAYS} days" +%F)
echo "oldest tick day=$OLDEST  cutoff=$CUTOFF (days <= cutoff are eligible)"

DONE=0
DAY="$OLDEST"
while (( DONE < MAX_DAYS_PER_RUN )); do
  [[ "$DAY" > "$CUTOFF" ]] && { echo "reached horizon at $DAY — nothing more eligible"; break; }
  if cut -f2 "$ROOT/MANIFEST.tsv" | grep -qx "$DAY"; then
    echo "-- $DAY already in manifest; purging leftovers then advancing"
    "$BIN/purge-ticks-day.sh" "$DAY" || { echo "PURGE FAILED $DAY"; exit 1; }
  else
    echo "-- exporting $DAY"
    "$BIN/export-ticks-day.sh" "$DAY" || { echo "EXPORT FAILED $DAY"; exit 1; }
    echo "-- purging $DAY"
    "$BIN/purge-ticks-day.sh" "$DAY" || { echo "PURGE FAILED $DAY"; exit 1; }
  fi
  DONE=$(( DONE + 1 ))
  DAY=$(date -u -d "$DAY + 1 day" +%F)
done

echo "=== retention-daily done: $DONE day(s) processed $(date -u +%FT%TZ) ==="
