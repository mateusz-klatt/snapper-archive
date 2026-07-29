#!/usr/bin/env bash
# Purge one verified UTC trade day by exchange event time.
#
# Refuses before connecting unless the trades manifest line and archive exist
# and the compressed file's sha256 and byte size match. The DELETE and manifest
# row-count assertion execute in one PostgreSQL statement transaction.
set -euo pipefail
# A caller's `bash -x` must never trace DB_URL or PGPASSWORD assignments.
set +x

usage() {
  echo "usage: $0 YYYY-MM-DD" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
DAY=$1
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
[[ "$(date -u -d "$DAY" +%F 2>/dev/null)" == "$DAY" ]] || usage
NEXT=$(date -u -d "$DAY + 1 day" +%F)

ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
MANIFEST=${TRADES_MANIFEST:-"$ROOT/TRADES-MANIFEST.tsv"}
LOCK_FILE=${TRADES_LOCK_FILE:-"$ROOT/.trades-archive.lock"}
SCHEMA=${TRADES_SCHEMA:-public}
DB_URL_FILE=${SNAPPER_ENV_FILE:-}
PURGE_STATEMENT_TIMEOUT=${PURGE_STATEMENT_TIMEOUT:-6h}
EXPLAIN_STATEMENT_TIMEOUT=${EXPLAIN_STATEMENT_TIMEOUT:-30s}

[[ "$SCHEMA" =~ ^[a-z_][a-z0-9_]*$ ]] || {
  echo "ABORT $DAY: invalid TRADES_SCHEMA" >&2
  exit 2
}
[[ "$PURGE_STATEMENT_TIMEOUT" =~ ^[1-9][0-9]*(ms|s|min|h)$ ]] || {
  echo "ABORT $DAY: invalid PURGE_STATEMENT_TIMEOUT" >&2
  exit 2
}
[[ "$EXPLAIN_STATEMENT_TIMEOUT" =~ ^[1-9][0-9]*(ms|s|min|h)$ ]] || {
  echo "ABORT $DAY: invalid EXPLAIN_STATEMENT_TIMEOUT" >&2
  exit 2
}

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || {
  echo "REFUSE $DAY: another trades archive operation holds $LOCK_FILE" >&2
  exit 1
}

[[ -f "$MANIFEST" ]] || {
  echo "REFUSE $DAY: no trades manifest line" >&2
  exit 1
}

set +e
LINE=$(awk -F $'\t' -v d="$DAY" '
  $2 == d {
    if (NF != 8) malformed=1
    line=$0
    matches++
  }
  END {
    if (malformed) exit 43
    if (matches == 1) print line
    else if (matches > 1) exit 42
  }
' "$MANIFEST")
MANIFEST_STATUS=$?
set -e
case "$MANIFEST_STATUS" in
  0) ;;
  42)
    echo "REFUSE $DAY: duplicate trades manifest lines" >&2
    exit 1
    ;;
  43)
    echo "REFUSE $DAY: invalid trades manifest line" >&2
    exit 1
    ;;
  *)
    echo "ABORT $DAY: could not read trades manifest" >&2
    exit 1
    ;;
esac
[[ -n "$LINE" ]] || {
  echo "REFUSE $DAY: no trades manifest line" >&2
  exit 1
}

IFS=$'\t' read -r FILENAME MANIFEST_DAY LOWER UPPER ROWS BYTES SHA EXPORTED_AT <<<"$LINE"
EXPECTED_FILENAME="trades-$DAY.csv.zst"
EXPECTED_LOWER="${DAY}T00:00:00Z"
EXPECTED_UPPER="${NEXT}T00:00:00Z"
[[ "$FILENAME" == "$EXPECTED_FILENAME" &&
  "$MANIFEST_DAY" == "$DAY" &&
  "$LOWER" == "$EXPECTED_LOWER" &&
  "$UPPER" == "$EXPECTED_UPPER" &&
  "$ROWS" =~ ^[0-9]+$ &&
  "$BYTES" =~ ^[0-9]+$ &&
  "$SHA" =~ ^[0-9a-f]{64}$ &&
  "$EXPORTED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
  echo "REFUSE $DAY: invalid trades manifest line" >&2
  exit 1
}

ARCHIVE="$ROOT/trades/$EXPECTED_FILENAME"
[[ -f "$ARCHIVE" ]] || {
  echo "REFUSE $DAY: archive file missing" >&2
  exit 1
}
ACTUAL_SHA=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
[[ "$ACTUAL_SHA" == "$SHA" ]] || {
  echo "REFUSE $DAY: sha mismatch" >&2
  exit 1
}
ACTUAL_BYTES=$(stat -c%s "$ARCHIVE")
[[ "$ACTUAL_BYTES" == "$BYTES" ]] || {
  echo "REFUSE $DAY: size mismatch" >&2
  exit 1
}

# This explicit acknowledgement makes an accidental standalone invocation
# harmless. A future gated retention driver must opt in deliberately.
if [[ "$SCHEMA" == "public" && "${ALLOW_PRODUCTION_TRADES_PURGE:-}" != "YES" ]]; then
  echo "REFUSE $DAY: production purge is not armed (set ALLOW_PRODUCTION_TRADES_PURGE=YES)" >&2
  exit 1
fi

load_db_config() {
  [[ -n "$DB_URL_FILE" ]] || {
    echo "ABORT $DAY: SNAPPER_ENV_FILE is required" >&2
    exit 1
  }
  [[ -r "$DB_URL_FILE" ]] || {
    echo "ABORT $DAY: cannot read DB_URL file $DB_URL_FILE" >&2
    exit 1
  }

  local raw scheme authority userinfo hostpath hostport dbpath
  raw=$(awk 'index($0, "DB_URL=") == 1 { sub(/^DB_URL=/, ""); print; exit }' "$DB_URL_FILE")
  [[ -n "$raw" && "$raw" == *"://"* ]] || {
    echo "ABORT $DAY: DB_URL is missing or malformed" >&2
    exit 1
  }

  scheme=${raw%%://*}
  scheme=${scheme/+asyncpg/}
  [[ "$scheme" == "postgresql" ]] || {
    echo "ABORT $DAY: DB_URL must use PostgreSQL" >&2
    exit 1
  }

  authority=${raw#*://}
  userinfo=${authority%%@*}
  hostpath=${authority#*@}
  [[ "$hostpath" != "$authority" && "$userinfo" == *:* && "$hostpath" == */* ]] || {
    echo "ABORT $DAY: DB_URL authority is malformed" >&2
    exit 1
  }

  DB_USER=${userinfo%%:*}
  export PGPASSWORD=${userinfo#*:}
  hostport=${hostpath%%/*}
  dbpath=${hostpath#*/}
  DB_NAME=${dbpath%%\?*}

  if [[ "$hostport" == *:* ]]; then
    DB_HOST=${hostport%%:*}
    DB_PORT=${hostport##*:}
  else
    DB_HOST=$hostport
    DB_PORT=5432
  fi
  [[ -n "${SNAPPER_DB_HOST_FROM:-}" ]] || {
    echo "ABORT $DAY: SNAPPER_DB_HOST_FROM is required" >&2
    exit 1
  }
  [[ -n "${SNAPPER_DB_HOST_TO:-}" ]] || {
    echo "ABORT $DAY: SNAPPER_DB_HOST_TO is required" >&2
    exit 1
  }
  [[ "$DB_HOST" == "$SNAPPER_DB_HOST_FROM" ]] && DB_HOST=$SNAPPER_DB_HOST_TO

  [[ -n "$DB_USER" && -n "$PGPASSWORD" && -n "$DB_HOST" && -n "$DB_NAME" ]] || {
    echo "ABORT $DAY: DB_URL components are incomplete" >&2
    exit 1
  }
  [[ "$DB_PORT" =~ ^[0-9]+$ ]] || {
    echo "ABORT $DAY: DB_URL port is invalid" >&2
    exit 1
  }

  unset raw authority userinfo hostpath hostport dbpath
}

load_db_config
PSQL=(
  nice -n19 ionice -c3
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME"
  -X -qAt -v ON_ERROR_STOP=1
)

RELATION="\"$SCHEMA\".\"trades\""
PREDICATE="executed_at >= '$LOWER'::timestamptz AND executed_at < '$UPPER'::timestamptz"

# Plain EXPLAIN only. The production DELETE is refused if its plan does not use
# the event-time index. A tiny scratch table may legitimately choose a seq scan.
PLAN=$("${PSQL[@]}" \
  -c "SET statement_timeout='$EXPLAIN_STATEMENT_TIMEOUT'" \
  -c "EXPLAIN (COSTS ON, VERBOSE OFF) DELETE FROM $RELATION WHERE $PREDICATE")
echo "EXPLAIN DELETE $SCHEMA.trades executed_at [$LOWER, $UPPER):"
printf '%s\n' "$PLAN"
if [[ "$SCHEMA" == "public" && "$PLAN" != *"ix_trades_executed_at"* ]]; then
  echo "ABORT $DAY: EXPLAIN did not use ix_trades_executed_at; DELETE was not run" >&2
  exit 1
fi

if ! "${PSQL[@]}" \
  -c "SET statement_timeout='$PURGE_STATEMENT_TIMEOUT'" \
  -c "
DO \$\$
DECLARE n bigint;
BEGIN
  DELETE FROM $RELATION WHERE $PREDICATE;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> $ROWS THEN
    RAISE EXCEPTION 'purge mismatch for $DAY: deleted % vs manifest $ROWS', n;
  END IF;
  RAISE NOTICE 'purged $DAY: % rows', n;
END
\$\$;"; then
  echo "REFUSE $DAY: purge transaction did not pass its row-count assertion" >&2
  exit 1
fi

echo "PURGED $DAY rows=$ROWS"
