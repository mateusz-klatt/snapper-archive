#!/usr/bin/env bash
# Daily partition maintenance for the three range-partitioned market-data
# tables. Renews the forward window of daily leaves, reports DEFAULT occupancy,
# and fails loudly when either goes wrong.
#
# WHY THIS EXISTS: nothing renewed partitions for the first two weeks after the
# daily-partition migration. The only leaves that existed were the ones the
# migration itself created, and they were due to run out. That went unnoticed
# because cron mail is off and every script in here redirects its own output to
# a monthly log, so a nonzero exit reached nobody. Hence SNAPPER_ALERT_EMAIL
# below: an exit code alone changes nothing on an unattended host.
#
# TWO ensure CALLS PER TABLE, AND THAT IS NOT REDUNDANT. The tool's window is
# `anchor .. anchor+13` — a TOTAL span, not "N back plus 14 forward". Anchoring
# in the past therefore BUYS BACKWARD COVERAGE WITH FORWARD HEADROOM instead of
# adding to it. Measured on a live database: `--anchor today` planned two new
# leaves at the forward edge, while `--anchor today-4` planned exactly one
# backward leaf and nothing forward. So the forward window needs its own
# today-anchored call, and the backward buffer needs a second one.
#
# NEVER TRUST THE TOOL'S "future daily leaves" COUNT. It counts leaves at or
# after the ANCHOR, so a past anchor over-reports headroom by the width of the
# backward window: the same database that really had 11 days of forward cover
# reported 16. Headroom is therefore computed here in SQL, as contiguous daily
# leaves starting at today.
set -euo pipefail
set +x

ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
# Alarm threshold. The tool's own alarm trips at 7 and a healthy run leaves 13,
# so 7 grants roughly six consecutive failures before anyone is woken up.
FORWARD_MIN_DAYS=${FORWARD_MIN_DAYS:-7}
# Per-table backward buffer, in days. These are NOT interchangeable.
#   ticks   = 0. Its partition key is RECEIVE time, so late data still lands on
#             the current day and a backward leaf buys nothing. It is also the
#             only table whose leaves are dropped by cron, so a backward leaf
#             for an already-exported day could take late rows that the export
#             manifest says are done — wedging retention permanently. Zero
#             removes that whole failure mode rather than guarding it.
#   candles/trades = 4. Their keys are event time, nothing scheduled drops
#             their leaves, and the observed arrival lag reaches four days.
BACKFILL_DAYS_TICKS=${BACKFILL_DAYS_TICKS:-0}
BACKFILL_DAYS_CANDLES=${BACKFILL_DAYS_CANDLES:-4}
BACKFILL_DAYS_TRADES=${BACKFILL_DAYS_TRADES:-4}
# A backward leaf must never reach a day that retention may already have
# exported and dropped, or the two jobs fight over the same day.
RETENTION_HORIZON_DAYS=${RETENTION_HORIZON_DAYS:-7}
ENSURE_RETRIES=${ENSURE_RETRIES:-3}
ENSURE_RETRY_SLEEP=${ENSURE_RETRY_SLEEP:-60}
# Warn when no run has succeeded for this long. This is what catches a stuck
# lock: a skipped run exits 0 by design, so consecutive skips are otherwise
# indistinguishable from healthy quiet.
STALE_SUCCESS_DAYS=${STALE_SUCCESS_DAYS:-2}

LOG="$ROOT/logs/partitions-$(date -u +%Y-%m).log"
STAMP="$ROOT/.partitions.last-success"
mkdir -p "$ROOT/logs"

# Alert channel. Empty means "log only" so the script stays usable on a host
# with no mail; the installation supplies the address from the crontab
# environment, never from this file.
ALERT_EMAIL=${SNAPPER_ALERT_EMAIL:-}

notify() {
  # Mail one failure summary with the tail of this run's log as the body.
  # Deliberately NOT wired to `trap ... ERR`: a lock skip is a legitimate exit 0
  # and must not page anyone, and a trap cannot tell the two apart.
  local subject="$1"
  [ -n "$ALERT_EMAIL" ] || return 0
  command -v mail >/dev/null 2>&1 || return 0
  # Only this run's own lines. A raw tail is mostly the application's startup
  # chatter — the first alert sent read as forty lines of SDK banners with the
  # actual refusal buried inside, which is unreadable on a phone at 03:00.
  awk '/^=== partitions-daily [0-9]/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$LOG" \
    | grep -E '^(===|==|--|OK|WARN|ABORT|Snapper|refused:)' \
    | tail -n 40 \
    | mail -s "$subject" "$ALERT_EMAIL" || true
}

stale_success_days() {
  # Whole days since the last successful run, or a large number if never.
  [ -r "$STAMP" ] || { echo 9999; return; }
  local last
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) echo 9999; return ;; esac
  echo $(( ( $(date -u +%s) - last ) / 86400 ))
}

exec 9>"$ROOT/.partitions.lock"
if ! flock -n 9; then
  echo "$(date -u +%FT%TZ) SKIP: another partition run holds the lock" >>"$LOG"
  STALE=$(stale_success_days)
  if (( STALE > STALE_SUCCESS_DAYS )); then
    echo "$(date -u +%FT%TZ) ABORT: lock held and no success for ${STALE}d" >>"$LOG"
    notify "Snapper partitions BLOCKED: lock held, no success for ${STALE}d"
    exit 1
  fi
  exit 0
fi
exec >>"$LOG" 2>&1

echo "=== partitions-daily $(date -u +%FT%TZ) forward_min=${FORWARD_MIN_DAYS}d ==="

STALE=$(stale_success_days)
if (( STALE >= 9999 )); then
  echo "WARN: no successful run has ever been recorded (first run, or the stamp was removed)"
elif (( STALE > STALE_SUCCESS_DAYS )); then
  echo "WARN: no successful run recorded for ${STALE} day(s)"
fi

REPO=${SNAPPER_APP_ROOT:?set SNAPPER_APP_ROOT to the Snapper application checkout}
cd "$REPO"
# Connecting over the bridge address makes the server see a different source
# address, which pg_hba.conf rejects. Rewrite the URL host to the allowed one.
ENV_FILE=${SNAPPER_ENV_FILE:?set SNAPPER_ENV_FILE to the .env file containing DB_URL}
DB_HOST_FROM=${SNAPPER_DB_HOST_FROM:?set SNAPPER_DB_HOST_FROM to the host written in DB_URL}
DB_HOST_TO=${SNAPPER_DB_HOST_TO:?set SNAPPER_DB_HOST_TO to the database host reachable from this host}
RAW=$(grep -E '^DB_URL=' "$ENV_FILE" | cut -d= -f2-)
export DB_URL="${RAW//$DB_HOST_FROM/$DB_HOST_TO}"
# psql needs its own URL. DB_URL carries a SQLAlchemy driver suffix
# (`postgresql+asyncpg://`) that the application understands and psql does not:
# given that scheme psql does not fail, it treats the whole string as a DATABASE
# NAME and quietly falls back to the local socket as the system user. Strip the
# driver so reads go to the same server the DDL does.
PSQL_URL=$(printf '%s' "$DB_URL" | sed -E 's|^([a-z]+)\+[a-z0-9]+://|\1://|')
# The application's default log path belongs to the container's user, so every
# CLI call from cron would otherwise dump a PermissionError traceback into this
# log. Point it somewhere this user owns.
export SNAPPER_LOG_FILE="$ROOT/logs/partitions-cli-$(date -u +%Y-%m).log"

# psql is used only to READ. Every DDL statement goes through the application
# CLI, which owns the leaf-local primary key and the active-public_id unique
# index that a bare `CREATE TABLE ... PARTITION OF` silently omits. Hand-written
# partition DDL has already cost this database two leaves with no primary key.
sql_scalar() {
  # Run one read-only query and return its single value. The UTC time zone is
  # set on every session: a Warsaw-local session reads a 07-31T23:00Z row as
  # 08-01 and silently reports the wrong day.
  psql "$PSQL_URL" -X -q -t -A -v ON_ERROR_STOP=1 \
    -c "SET TIME ZONE 'UTC'" -c "$1"
}

default_rows() {
  sql_scalar "SELECT count(*) FROM ${1}_default"
}

forward_headroom() {
  # Contiguous daily leaves starting at today, in UTC. Counting leaves is not
  # enough: a gap in the middle would otherwise be reported as depth.
  sql_scalar "
    WITH leaves AS (
      SELECT to_date(right(c.relname, 8), 'YYYYMMDD') AS day
      FROM pg_class c
      JOIN pg_inherits i ON i.inhrelid = c.oid
      JOIN pg_class p ON p.oid = i.inhparent
      WHERE p.relname = '${1}'
        AND c.relname ~ '^${1}_d[0-9]{8}\$'
    ),
    first_gap AS (
      SELECT min(g.d)::date AS day
      FROM generate_series(current_date, current_date + 400, interval '1 day') g(d)
      WHERE NOT EXISTS (SELECT 1 FROM leaves l WHERE l.day = g.d::date)
    )
    SELECT count(*) FROM leaves, first_gap
    WHERE leaves.day >= current_date AND leaves.day < first_gap.day"
}

run_ensure() {
  # One ensure call, retried: the tool takes the parent's ACCESS EXCLUSIVE lock
  # with a 2s timeout and does NOT retry internally, so it loses a coin flip
  # against any concurrent long read. Retrying here is cheaper than widening
  # that timeout, which would queue ahead of live readers.
  local table="$1" anchor="$2" label="$3" attempt=1 rc=0 output=""
  while :; do
    rc=0
    output=$(.venv/bin/snapper daily-partitions ensure "$table" \
               --anchor "${anchor}T00:00:00+00:00" --apply 2>&1) || rc=$?
    printf '%s\n' "$output"
    if (( rc == 0 )); then
      return 0
    fi
    # A drained DEFAULT is a precondition, not a transient fault. Retrying it
    # just repeats the same refusal three times.
    if printf '%s' "$output" | grep -q 'must be drained first'; then
      echo "-- $table $label BLOCKED: ${table}_default must be drained first"
      return 2
    fi
    if (( attempt >= ENSURE_RETRIES )); then
      echo "-- $table $label FAILED after ${attempt} attempt(s) rc=$rc"
      return 1
    fi
    echo "-- $table $label attempt ${attempt} rc=$rc, retrying in ${ENSURE_RETRY_SLEEP}s"
    attempt=$(( attempt + 1 ))
    sleep "$ENSURE_RETRY_SLEEP"
  done
}

backfill_days_for() {
  case "$1" in
    ticks) echo "$BACKFILL_DAYS_TICKS" ;;
    candles) echo "$BACKFILL_DAYS_CANDLES" ;;
    trades) echo "$BACKFILL_DAYS_TRADES" ;;
    *) echo 0 ;;
  esac
}

TODAY=$(date -u +%F)
FAILED=()
BLOCKED=()
SUMMARY=()

for TABLE in ticks trades candles; do
  echo "== $TABLE $(date -u +%T)"
  BACK=$(backfill_days_for "$TABLE")

  # A backward leaf inside retention's reach would let this job recreate a day
  # that retention has already exported, archived and dropped. Clamp rather
  # than refuse: the forward window is the part that must not be skipped.
  if (( BACK > 0 && BACK >= RETENTION_HORIZON_DAYS )); then
    echo "-- $TABLE backward buffer ${BACK}d reaches retention horizon ${RETENTION_HORIZON_DAYS}d, clamping"
    BACK=$(( RETENTION_HORIZON_DAYS - 1 ))
  fi

  # Each table is attempted independently. Under `set -e` a shared loop would
  # abort at the first blocked table and silently skip every later one — which
  # is exactly how a single non-empty DEFAULT could stop all renewal.
  TABLE_RC=0
  run_ensure "$TABLE" "$TODAY" "forward" || TABLE_RC=$?
  if (( BACK > 0 )); then
    BACK_ANCHOR=$(date -u -d "today - ${BACK} days" +%F)
    run_ensure "$TABLE" "$BACK_ANCHOR" "backward(${BACK}d)" || TABLE_RC=$?
  fi

  # `|| true` is load-bearing, not defensive clutter. Under `set -e` a failing
  # command substitution inside an assignment aborts the script outright — so a
  # momentary database hiccup would kill the run BEFORE it could mail anything,
  # reproducing the silent failure this job exists to end. Read, then judge.
  DEFAULT_ROWS=$(default_rows "$TABLE" 2>&1) || DEFAULT_ROWS="query-failed"
  HEADROOM=$(forward_headroom "$TABLE" 2>&1) || HEADROOM="query-failed"
  case "$DEFAULT_ROWS$HEADROOM" in
    *[!0-9]*)
      echo "-- $TABLE FAILED to read partition state: default='${DEFAULT_ROWS}' headroom='${HEADROOM}'"
      FAILED+=("$TABLE")
      SUMMARY+=("$TABLE UNREADABLE")
      continue
      ;;
  esac
  SUMMARY+=("$TABLE headroom=${HEADROOM}d default=${DEFAULT_ROWS}")
  echo "-- $TABLE headroom=${HEADROOM}d default=${DEFAULT_ROWS} rows"

  case "$TABLE_RC" in
    2) BLOCKED+=("$TABLE") ;;
    0) : ;;
    *) FAILED+=("$TABLE") ;;
  esac
  # A non-empty DEFAULT is never benign: it blocks renewal outright and grows.
  if [ "$DEFAULT_ROWS" != "0" ] && [[ ! " ${BLOCKED[*]-} " == *" $TABLE "* ]]; then
    BLOCKED+=("$TABLE")
  fi
  if (( HEADROOM < FORWARD_MIN_DAYS )); then
    echo "-- $TABLE headroom ${HEADROOM}d is below the ${FORWARD_MIN_DAYS}d floor"
    FAILED+=("$TABLE")
  fi
done

echo "=== partitions-daily done $(date -u +%FT%TZ) ==="
printf '%s\n' "${SUMMARY[@]}"

if (( ${#FAILED[@]} == 0 && ${#BLOCKED[@]} == 0 )); then
  date -u +%s >"$STAMP"
  echo "OK all tables"
  exit 0
fi

# Built with `if`, never `(( ... )) && ...`: a false arithmetic test returns 1,
# and under `set -e` that would abort the script here — suppressing the very
# alert this block exists to send.
STATUS="Snapper partitions"
if (( ${#BLOCKED[@]} > 0 )); then
  STATUS="$STATUS BLOCKED[${BLOCKED[*]}]"
fi
if (( ${#FAILED[@]} > 0 )); then
  STATUS="$STATUS FAILED[${FAILED[*]}]"
fi
echo "$STATUS"
notify "$STATUS"
exit 1
