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
# Fatal floor for CONTIGUOUS forward coverage counted from today. Distinct from
# the target below: the target is what a healthy run maintains, this is the point
# at which silence has gone on long enough to wake someone.
FORWARD_MIN_DAYS=${FORWARD_MIN_DAYS:-7}
# Forward target. An empty leaf costs 16-48 kB (measured: ticks 16, candles 32,
# trades 48) against 6.5 GB for one populated tick day, so a month of headroom is
# free and removes the renewal deadline as a class of problem.
FORWARD_DAYS=${FORWARD_DAYS:-30}
# Backward buffer, per table. NOT interchangeable, and the asymmetry is the whole
# point.
#
#   candles / trades = 30. Their keys are EVENT time, so genuinely late data
#     belongs on an old day, and nothing scheduled destroys their leaves — the
#     weekly candle sweep works on rows (SCD2 supersession), not partitions, and
#     purge-trades-day.sh is not on cron. A wide window here is pure upside: it
#     absorbs a historical backfill instead of parking it in DEFAULT, which
#     blocks renewal for every table at once.
#
#   ticks = 6, and deliberately NOT 30. Ticks are the one table whose leaves cron
#     DROPS. Recreating a leaf for a day retention has already exported and
#     purged turns a loud failure into a jam: a late tick would land in that leaf
#     instead of DEFAULT, retention skips the day because MANIFEST.tsv lists it,
#     and the next purge attempt dies on `purge mismatch` (leaf rows vs manifest
#     rows) — permanently, since retention exits on the first failure while ticks
#     keep growing ~7.3 GB/day. Routing that tick to DEFAULT instead costs one
#     alert and leaves retention working. The bound is therefore the retention
#     horizon minus a day, enforced below rather than trusted.
BACKFILL_DAYS_TICKS=${BACKFILL_DAYS_TICKS:-6}
BACKFILL_DAYS_CANDLES=${BACKFILL_DAYS_CANDLES:-30}
BACKFILL_DAYS_TRADES=${BACKFILL_DAYS_TRADES:-30}
# Only ticks are cron-purged, so only ticks are clamped against this.
RETENTION_HORIZON_DAYS=${RETENTION_HORIZON_DAYS:-7}
# The tool's window is anchor..anchor+13 — a TOTAL span, not an open-ended
# forward reach — so covering a wider range takes several anchors stepped by
# this much.
ANCHOR_STEP_DAYS=14
# Retry shape, tuned against observed contention rather than guessed. The tool
# takes the parent's ACCESS EXCLUSIVE lock with a 2s timeout and never retries
# internally, while the candle publisher writes 44 pairs every minute — so the
# lock is free only in short, REGULAR windows between writes. Many short
# attempts therefore beat few long waits: 3x60s exhausted itself on candles
# while 2x60s was enough for the quieter trades parent.
ENSURE_RETRIES=${ENSURE_RETRIES:-8}
ENSURE_RETRY_SLEEP=${ENSURE_RETRY_SLEEP:-20}
# Warn when no run has succeeded for this long. This is what catches a stuck
# lock: a skipped run exits 0 by design, so consecutive skips are otherwise
# indistinguishable from healthy quiet.
STALE_SUCCESS_DAYS=${STALE_SUCCESS_DAYS:-2}

LOG="$ROOT/logs/partitions-$(date -u +%Y-%m).log"
STAMP="$ROOT/.partitions.last-success"
mkdir -p "$ROOT/logs"

# Alert channel. The address comes from the crontab environment, never from this
# file; an empty value leaves the job log-only so it stays usable on a host with
# no mail. Sourced before the flock check because the skip branch below can
# itself need to raise an alarm.
. "$(dirname -- "${BASH_SOURCE[0]}")/_alert.sh"

notify() {
  # Deliberately NOT wired to `trap ... ERR`: a lock skip is a legitimate exit 0
  # and must not page anyone, and ERR cannot tell the two apart.
  snapper_alert "$1" "$LOG" '^=== partitions-daily [0-9]'
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

missing_days() {
  # Every day in [today-$2, today+$3] with no daily leaf, oldest first, one per
  # line. This exists so the steady state costs ONE cheap catalog query instead
  # of a CLI invocation per anchor: `ensure` is idempotent, but each call pays
  # ~25s of application bootstrap whether or not it has work to do, and a
  # ±30-day window needs five anchors per table.
  sql_scalar "
    WITH leaves AS (
      SELECT to_date(right(c.relname, 8), 'YYYYMMDD') AS day
      FROM pg_class c
      JOIN pg_inherits i ON i.inhrelid = c.oid
      JOIN pg_class p ON p.oid = i.inhparent
      WHERE p.relname = '${1}'
        AND c.relname ~ '^${1}_d[0-9]{8}\$'
    )
    SELECT to_char(g.d, 'YYYY-MM-DD')
    FROM generate_series(current_date - ${2}, current_date + ${3}, interval '1 day') g(d)
    WHERE NOT EXISTS (SELECT 1 FROM leaves l WHERE l.day = g.d::date)
    ORDER BY g.d"
}

anchors_for() {
  # Minimal anchor set covering the supplied missing days. Walks them in order
  # and starts a new anchor only once the previous anchor's window has run out,
  # so a scattered handful of gaps costs one call each while a contiguous month
  # costs three.
  local covered_until="" day
  while read -r day; do
    [ -n "$day" ] || continue
    if [ -z "$covered_until" ] || [[ "$day" > "$covered_until" ]]; then
      echo "$day"
      covered_until=$(date -u -d "$day + $((ANCHOR_STEP_DAYS - 1)) days" +%F)
    fi
  done
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

count_lines() {
  # Count non-empty lines on stdin, ALWAYS succeeding.
  #
  # `grep -c .` prints 0 and exits 1 on empty input. That exit code is harmless
  # inside `echo "$(...)"` but fatal inside an assignment: under `set -e` a
  # failing command substitution in `X=$(...)` or `X=$(( $(...) ))` aborts the
  # script on the spot, with no message, in the ordinary case where there is
  # simply nothing to do. This exact class has now bitten three times in this
  # file — reading DEFAULT counts, building the alert subject, and counting
  # gaps — so it gets a named helper rather than another inline `|| true`.
  grep -c . || true
}

manifest_for() {
  # Archive ledger for this table, if it has one. Candles have no day-level
  # manifest: the weekly sweep archives closed SCD2 versions, not whole days.
  case "$1" in
    ticks) echo "$ROOT/MANIFEST.tsv" ;;
    trades) echo "$ROOT/TRADES-MANIFEST.tsv" ;;
    *) echo "" ;;
  esac
}

drop_archived_days() {
  # Remove days already recorded in the archive ledger from a list of missing
  # days, so this job never RESURRECTS a leaf for a day that has been exported
  # and drained.
  #
  # This is the sharpest edge in the whole design. A recreated leaf for an
  # archived day is worse than no leaf at all: late rows land in it instead of
  # in DEFAULT, retention skips the day because the ledger lists it, so the rows
  # are never archived — and the next purge attempt dies on `purge mismatch`
  # (leaf rows vs ledger rows), which for ticks wedges retention permanently
  # while the table grows ~7.3 GB/day. Routing those rows to DEFAULT instead
  # costs one alert and keeps everything else running.
  #
  # A retention horizon alone does NOT cover this. Days get exported early, by
  # hand or by a catch-up run, so an archived day can sit well inside the
  # horizon — 2026-07-29..31 were exported on 08-01 with a 7-day horizon. And
  # for trades the oldest surviving row (07-15) is OLDER than the archived range
  # (07-22..31), so "do not predate the oldest row" would not have caught it
  # either. The ledger is the only precise statement of what is already done.
  local ledger="$1"
  if [ -z "$ledger" ] || [ ! -r "$ledger" ]; then
    cat
    return 0
  fi
  grep -Fvx -f <(cut -f2 "$ledger" | sort -u) - || true
}

TODAY=$(date -u +%F)
FAILED=()
BLOCKED=()
SUMMARY=()

for TABLE in ticks trades candles; do
  echo "== $TABLE $(date -u +%T)"
  BACK=$(backfill_days_for "$TABLE")

  # Only ticks are purged by cron, so only ticks are clamped: recreating a leaf
  # for a day already exported and dropped would let a late tick land there
  # instead of in DEFAULT, after which retention skips the day as manifested and
  # the next purge dies on a row-count mismatch. Candles and trades have no
  # scheduled leaf destroyer, so their wide window carries no such interaction.
  if [ "$TABLE" = "ticks" ] && (( BACK >= RETENTION_HORIZON_DAYS )); then
    echo "-- $TABLE backward ${BACK}d reaches the ${RETENTION_HORIZON_DAYS}d retention horizon, clamping"
    BACK=$(( RETENTION_HORIZON_DAYS - 1 ))
  fi

  # Each table is attempted independently. Under `set -e` a shared loop would
  # abort at the first blocked table and silently skip every later one — which
  # is exactly how a single non-empty DEFAULT could stop all renewal.
  TABLE_RC=0
  GAPS=$(missing_days "$TABLE" "$BACK" "$FORWARD_DAYS" 2>&1) || GAPS="query-failed"
  if [ "$GAPS" != "query-failed" ]; then
    KEPT=$(printf '%s\n' "$GAPS" | drop_archived_days "$(manifest_for "$TABLE")")
    DROPPED=$(( $(printf '%s\n' "$GAPS" | count_lines) - $(printf '%s\n' "$KEPT" | count_lines) ))
    if (( DROPPED > 0 )); then
      echo "-- $TABLE skipping ${DROPPED} day(s) already in the archive ledger (never resurrect an exported day)"
    fi
    GAPS="$KEPT"
  fi
  case "$GAPS" in
    query-failed*|*[!0-9$'\n'-]*)
      echo "-- $TABLE FAILED to read the leaf window: ${GAPS}"
      TABLE_RC=1
      ;;
    "")
      echo "-- $TABLE window -${BACK}d..+${FORWARD_DAYS}d already complete, no DDL needed"
      ;;
    *)
      ANCHORS=$(printf '%s\n' "$GAPS" | anchors_for)
      echo "-- $TABLE missing $(printf '%s\n' "$GAPS" | count_lines) day(s), $(printf '%s\n' "$ANCHORS" | count_lines) anchor(s)"
      while read -r A; do
        [ -n "$A" ] || continue
        run_ensure "$TABLE" "$A" "anchor ${A}" || TABLE_RC=$?
      done <<<"$ANCHORS"
      ;;
  esac

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
