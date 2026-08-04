#!/usr/bin/env bash
# Daily Polygon ingest, in two clearly separated phases:
#
#   PHASE 1  fetch  — pull recent flat files into the CSV cache. RATE LIMITED to
#                     roughly one symbol every 12 seconds, so with ~593 symbols
#                     this alone takes 2-3 hours. It is pure API + local disk;
#                     it does NOT touch the database and therefore cannot
#                     contend with anything else running on the box.
#   PHASE 2  load   — load the whole freshly-filled cache into the database in
#                     one pass, only after every download has finished.
#
# SCHEDULING, and why 05:00 local:
#   - Polygon's daily flat files only become available after midnight UTC, so an
#     early-night run would fetch nothing useful.
#   - The fetch needs 2-3 hours, so a 05:00 local start puts phase 2 around
#     07:00-08:00 — comfortably clear of the 03:17 retention job. That matters
#     because phase 2 WRITES candles while retention PURGES closed candle
#     versions, and the two contend on the same table. Phase 1 overlapping
#     retention would be harmless, but phase 2 must not.
#
# The flock is load-bearing here, not decorative: a 3-hour run that overruns
# must never have a second copy start on top of it.
set -uo pipefail
set +x

ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
REPO=${SNAPPER_APP_ROOT:?set SNAPPER_APP_ROOT to the Snapper application checkout}
GITLINK_REMOTES=${SNAPPER_GITLINK_REMOTES:?set SNAPPER_GITLINK_REMOTES to the space-separated gitlink remote names}

# Aggregates are ONE API call per symbol with the window as a parameter, so the
# 12s-per-symbol throttle dominates and a wider window is free. Confirmed
# empirically: 3 days and 32 days cost the same wall clock. 32 therefore matches
# `make run-polygon-aggregates` and self-heals gaps left by failed runs.
FETCH_DAYS=${FETCH_DAYS:-32}

# Grouped daily is the OPPOSITE shape: one call per DAY per market, so here the
# window IS the cost (3 markets x N days). Past days never change, so this only
# needs to span the T+1 correction window, not the aggregate window.
GROUPED_MARKETS=${GROUPED_MARKETS:-"crypto stocks fx"}

# Load far enough back to cover every day since the last committed snapshot, so
# a run skipped for a week still lands its whole gap. Floor of 4 days keeps the
# normal daily case covering T+1 corrections. Resolved below, once we know the
# submodule is readable.
MIN_LOOKBACK_DAYS=${MIN_LOOKBACK_DAYS:-4}

# Higher timeframes are NOT derived by the CSV loader — it writes only the base
# 1m rows. Without this they silently stop advancing while 1m keeps growing.
SYNTH_TIMEFRAMES=${SYNTH_TIMEFRAMES:-5m,15m,30m,1h,4h,1d}

MIN_FREE_GB=${MIN_FREE_GB:-25}
LOG="$ROOT/logs/polygon-$(date -u +%Y-%m).log"
mkdir -p "$ROOT/logs"

exec 9>"$ROOT/.polygon.lock"
flock -n 9 || { echo "$(date -u +%FT%TZ) SKIP: another polygon run holds the lock" >>"$LOG"; exit 0; }
exec >>"$LOG" 2>&1

STARTED=$(date -u +%s)

# Days since the last committed snapshot, floored at MIN_LOOKBACK_DAYS. The
# monthly snapshot is amended on every successful run, so in steady state this
# resolves to the floor; after a multi-day outage it widens to cover the gap.
# A failure here (unreadable submodule — exactly what a deleted .git file
# caused on 2026-07-27) falls back to the floor rather than to zero, because
# loading nothing is a silent gap while loading a few extra days is idempotent.
LAST_SNAPSHOT_EPOCH=$(git -C "$REPO/data/polygon" log -1 --format=%ct 2>/dev/null || true)
if [[ "$LAST_SNAPSHOT_EPOCH" =~ ^[0-9]+$ ]]; then
  GAP_DAYS=$(( (STARTED - LAST_SNAPSHOT_EPOCH) / 86400 + 1 ))
else
  echo "WARN: cannot read data/polygon HEAD date; using the ${MIN_LOOKBACK_DAYS}d floor"
  GAP_DAYS=0
fi
LOAD_LOOKBACK_DAYS=${LOAD_LOOKBACK_DAYS:-$(( GAP_DAYS > MIN_LOOKBACK_DAYS ? GAP_DAYS : MIN_LOOKBACK_DAYS ))}
GROUPED_DAYS=${GROUPED_DAYS:-$LOAD_LOOKBACK_DAYS}

echo "=== polygon-daily $(date -u +%FT%TZ) fetch=${FETCH_DAYS}d load_since=${LOAD_LOOKBACK_DAYS}d grouped=${GROUPED_DAYS}d ==="

FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if (( FREE_GB < MIN_FREE_GB )); then
  echo "ABORT: root has ${FREE_GB}G free, below the ${MIN_FREE_GB}G floor"
  exit 1
fi
echo "root free=${FREE_GB}G  cache=$(du -sh "$REPO/data/polygon/cache" 2>/dev/null | cut -f1)"

cd "$REPO" || { echo "ABORT: cannot cd $REPO"; exit 1; }

# Connecting over the bridge address makes the server see a different source
# address, which pg_hba.conf rejects. Rewrite the URL host to the allowed
# address; the same issue also applies to the weekly candle sweep.
ENV_FILE=${SNAPPER_ENV_FILE:?set SNAPPER_ENV_FILE to the .env file containing DB_URL}
DB_HOST_FROM=${SNAPPER_DB_HOST_FROM:?set SNAPPER_DB_HOST_FROM to the host written in DB_URL}
DB_HOST_TO=${SNAPPER_DB_HOST_TO:?set SNAPPER_DB_HOST_TO to the database host reachable from this host}
RAW=$(grep -E '^DB_URL=' "$ENV_FILE" | cut -d= -f2-)
export DB_URL="${RAW//$DB_HOST_FROM/$DB_HOST_TO}"

# The default logfile (data/snapper.log) is owned by the container user, so a
# host-side CLI run cannot append to it and every log call raises
# PermissionError. Python's logging swallows those, so the work still completes
# — but the output degrades into noise. Point the CLI at a path this user owns.
# This is the concrete cost of the flat data/*.log layout; see the planned move
# to data/log/<service>/.
export SNAPPER_LOG_FILE="$ROOT/logs/polygon-cli-$(date -u +%Y-%m).log"

# SKIP_FETCH / SKIP_LOAD exist so the cheap phases can be exercised end-to-end
# without the 2-3 hour fetch. Aggregates cost one API call PER SYMBOL with the
# window as a parameter, so shrinking FETCH_DAYS does not shorten PHASE 1 at all
# — only skipping it does. Never set these in the cron entry; they are for
# hand-testing changes to phases 1b/2b/3/4 on a day the data is already current.
if [ -n "${SKIP_FETCH:-}" ]; then
  echo "-- PHASE 1 fetch SKIPPED (SKIP_FETCH set) $(date -u +%T)"
  FETCH_RC=0
else
  echo "-- PHASE 1 fetch (rate limited ~12s/symbol, expect 2-3h) $(date -u +%T)"
  .venv/bin/snapper polygon-backfill-aggregates -d "$FETCH_DAYS"
  FETCH_RC=$?
fi
FETCH_DONE=$(date -u +%s)
echo "fetch rc=$FETCH_RC elapsed=$(( (FETCH_DONE - STARTED) / 60 ))min"

if (( FETCH_RC != 0 )); then
  echo "WARN: fetch exited non-zero; loading whatever landed in the cache anyway"
fi

# --- PHASE 1b grouped daily ---
# One call per day per market, so this is deliberately scoped to the correction
# window rather than to FETCH_DAYS. Nothing else refreshes cache/grouped/: it
# has no other cron, so if these files are ever lost they are only recoverable
# from git, unlike cache/minute which the next run would re-fetch anyway.
# Downloads only — loading grouped into 1d candles needs a per-venue EXCHANGE
# and CUT_DATE, which is a separate deliberate operation.
echo "-- PHASE 1b grouped daily ${GROUPED_DAYS}d $(date -u +%T)"
for M in $GROUPED_MARKETS; do
  LOCALE_ARG=""
  [ "$M" = "stocks" ] && LOCALE_ARG="-l us"
  if .venv/bin/snapper polygon-backfill-grouped -m "$M" -d "$GROUPED_DAYS" $LOCALE_ARG; then
    echo "grouped: ok $M"
  else
    echo "grouped: FAILED $M (rc=$?)"
  fi
done

SINCE=$(date -u -d "today - ${LOAD_LOOKBACK_DAYS} days" +%F)
if [ -n "${SKIP_LOAD:-}" ]; then
  echo "-- PHASE 2 load SKIPPED (SKIP_LOAD set), SINCE=${SINCE} $(date -u +%T)"
else
  # Guarantee a home for every day this load is about to touch. A candle whose
  # day has no partition falls into candles_default, and a non-empty DEFAULT
  # makes `ensure` refuse outright — so the anomaly buffer that catches the
  # stray rows is also what blocks the renewal that would have prevented them.
  # That is how 921,878 rows accumulated: LOAD_LOOKBACK_DAYS reached back past
  # the oldest daily leaf on three consecutive mornings and nothing noticed.
  #
  # The check belongs HERE rather than in the partition cron because the reach
  # is not a constant. MIN_LOOKBACK_DAYS is only a floor; the real span is
  # GAP_DAYS since the last committed snapshot, which is unbounded above. This
  # script is the one that computes it, so it is the one that can size the
  # window correctly. A fixed backward buffer elsewhere is a guess that a
  # lagging submodule silently outgrows.
  #
  # Non-fatal on purpose: a refusal here means DEFAULT already holds rows, which
  # needs an operator, not a skipped ingest.
  # Stepped by 14 days because one ensure call covers anchor..anchor+13 — a
  # TOTAL span, not an open-ended forward window. A single call at SINCE would
  # leave the middle of a long catch-up uncovered: with a gap of twenty days,
  # SINCE+13 still falls a week short of today.
  echo "-- PHASE 2 partitions ${SINCE}..$(date -u +%F) $(date -u +%T)"
  PART_ANCHOR="$SINCE"
  PART_TODAY=$(date -u +%F)
  while [[ "$PART_ANCHOR" < "$PART_TODAY" || "$PART_ANCHOR" == "$PART_TODAY" ]]; do
    .venv/bin/snapper daily-partitions ensure candles \
      --anchor "${PART_ANCHOR}T00:00:00+00:00" --apply \
      || echo "WARN: candles partitions not ensured at ${PART_ANCHOR} (drain candles_default?)"
    PART_ANCHOR=$(date -u -d "$PART_ANCHOR + 14 days" +%F)
  done
  echo "-- PHASE 2 load since ${SINCE} $(date -u +%T)"
  .venv/bin/snapper polygon-load-csv --all -t minute --since "$SINCE"
  echo "load rc=$? elapsed_total=$(( ($(date -u +%s) - STARTED) / 60 ))min"
fi

# --- PHASE 2b synthesize higher timeframes ---
# PolygonCsvLoaderService writes ONLY the base 1m rows (it calls ensure_instrument
# with ExchangeEnum.POLYGON and inserts at _timeframe_label(1, timespan)); nothing
# in that path derives 5m..1d. Verified in
# application/updaters/historical/csv_loader.py on 2026-07-27 — before this phase
# existed, every higher timeframe on the polygon venue stopped at whatever the
# last manual backfill left behind while 1m kept advancing daily.
# --cut-date is REQUIRED whenever 1d is in the list — the service raises
# "cut_date is required when 1d is requested" and exits non-zero without it.
# Found the hard way on 2026-07-27: the first manual run failed on exactly this,
# which is the only reason it was not a nightly failure discovered a week later.
# It is the first UTC day synthesized 1d rows may OWN; the writer skips
# `open_at < cut_date` (synthesized_candle_backfill.py:429). The daily candle
# unique key carries no provenance, so this is what stops a synthesized bar from
# silently overwriting a natively loaded one. Pinning it to SINCE means each run
# owns only the window whose 1m rows it just loaded, and never reaches backwards.
echo "-- PHASE 2b synthesize ${SYNTH_TIMEFRAMES} since ${SINCE} $(date -u +%T)"
if .venv/bin/snapper backfill-synthesized-candles \
     --exchange polygon --all \
     --start "$SINCE" --end "$(date -u +%F)" \
     --cut-date "$SINCE" \
     --timeframes "$SYNTH_TIMEFRAMES"; then
  echo "synth: ok"
else
  echo "synth: FAILED (rc=$?)"
fi

# --- PHASE 3 commit the CSV cache into the data/polygon repo ---
# The previously-missing last task: fetch+load ran but nothing was committed,
# so the cache drifted dirty for days. data/polygon is a dedicated data repo
# (no interactive sessions touch it), so add -A + amend/force-with-lease is safe.
# Monthly-snapshot convention ("2026-07"): the commit month is the month of the
# NEWEST changed CSV date, NOT today's calendar month. That is what makes the
# month boundary correct: on the 1st, T+1 flat files still carry only last
# month's dates, so we amend last month; once a current-month date appears we
# roll to a new commit. Late corrections to an older month fold into the current
# cumulative snapshot rather than rewriting a frozen prior commit.
# Pushed to EVERY configured remote, not just one, so no configured mirror
# silently misses these commits.
echo "-- PHASE 3 commit data/polygon $(date -u +%T)"
if cd "$REPO/data/polygon"; then
  git add -A
  if git diff --cached --quiet; then
    echo "commit: nothing new to commit"
  else
    TARGET=$(git diff --cached --name-only | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}\.csv' | sort | tail -1 | cut -c1-7)
    [ -z "$TARGET" ] && TARGET=$(date -u +%Y-%m)
    LAST=$(git log -1 --pretty=%s 2>/dev/null)
    if [ "$TARGET" \> "$LAST" ]; then
      git commit -q -m "$TARGET"
      PUSH_ARGS=""
      echo "commit: new $TARGET snapshot"
    else
      git commit --amend --no-edit -q
      PUSH_ARGS="--force-with-lease"
      echo "commit: amended $LAST ($TARGET data)"
    fi
    for R in $(git remote); do
      if git push -q $PUSH_ARGS "$R" master 2>/dev/null; then
        echo "commit: pushed $R"
      else
        echo "commit: FAILED push $R"
      fi
    done
  fi
else
  echo "WARN: cannot cd $REPO/data/polygon; CSV cache left uncommitted"
fi

# --- PHASE 4 bump the superproject gitlink (daily) ---
# Built with PLUMBING against a freshly fetched origin/master: a temporary index
# is read from that commit, only the data/polygon gitlink is replaced, and the
# result is committed with commit-tree and pushed directly. HEAD, the index and
# the shared working tree are never touched.
#
# The checkout-based version this replaces failed 3 days out of 4 with
# "origin non-ff". Its retry loop assumed the failure was a race, so it slept and
# retried; the real cause is persistent — an interactive session pushes to master
# through the day, so the local branch lags origin and no number of retries can
# push a commit built on a stale base. Rebasing in cron was not an option either:
# that working tree is shared, and rebasing under someone's uncommitted work is
# the exact collision this script must never cause.
echo "-- PHASE 4 bump superproject gitlink $(date -u +%T)"
FAILS="$ROOT/.polygon-gitlink-fails"
if cd "$REPO"; then
  SUB=$(git -C data/polygon rev-parse HEAD 2>/dev/null)
  if [ -z "$SUB" ]; then
    echo "gitlink: FAILED cannot read data/polygon HEAD"
    echo $(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )) >"$FAILS"
  elif ! git fetch -q origin master 2>/dev/null; then
    echo "gitlink: FAILED cannot fetch origin"
    echo $(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )) >"$FAILS"
  else
    BASE=$(git rev-parse FETCH_HEAD)
    RECORDED=$(git rev-parse "$BASE:data/polygon" 2>/dev/null)
    if [ "$RECORDED" = "$SUB" ]; then
      echo "gitlink: already current on origin ($(echo $SUB | cut -c1-12))"
      rm -f "$FAILS"
    else
      TMPIDX=$(mktemp "$ROOT/.polygon-index.XXXXXX")
      NEW=""
      if GIT_INDEX_FILE="$TMPIDX" git read-tree "$BASE" 2>/dev/null \
         && GIT_INDEX_FILE="$TMPIDX" git update-index --cacheinfo 160000,"$SUB",data/polygon 2>/dev/null; then
        TREE=$(GIT_INDEX_FILE="$TMPIDX" git write-tree 2>/dev/null)
        [ -n "$TREE" ] && NEW=$(git commit-tree "$TREE" -p "$BASE" \
          -m "polygon: $(date -u +%F) daily gitlink" 2>/dev/null)
      fi
      rm -f "$TMPIDX"
      if [ -z "$NEW" ]; then
        echo "gitlink: FAILED could not build the bump commit"
        echo $(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )) >"$FAILS"
      else
        pushed=""
        failed=""
        for R in $GITLINK_REMOTES; do
          if git push -q "$R" "$NEW:master" 2>/dev/null; then
            pushed="$pushed $R"
          else
            failed="$failed $R"
          fi
        done
        if [ -n "$pushed" ] && [ -z "$failed" ]; then
          echo "gitlink: bumped to $(echo $SUB | cut -c1-12), pushed$pushed"
          rm -f "$FAILS"
        elif [ -n "$pushed" ]; then
          echo "gitlink: bumped, pushed$pushed but FAILED$failed"
          echo $(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )) >"$FAILS"
        else
          echo "gitlink: FAILED push to every remote (base moved again?)"
          echo $(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )) >"$FAILS"
        fi
      fi
    fi
  fi
  N=$(cat "$FAILS" 2>/dev/null || echo 0)
  [ "$N" -ge 2 ] && echo "gitlink: !! $N CONSECUTIVE FAILURES — the superproject pointer is stale"
else
  echo "WARN: cannot cd $REPO; gitlink not bumped"
fi

echo "=== polygon-daily done $(date -u +%FT%TZ) ==="
