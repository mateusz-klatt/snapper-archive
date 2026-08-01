#!/usr/bin/env bash
# Export one UTC trade day by exchange event time, guarded by the catalog's
# partitioned executed_at index family before COPY is allowed on production.
#
# Archive format v1. The order is immutable because the restorer consumes the
# first three fields positionally as public_id, timestamp, and known_to.
readonly TRADE_EXPORT_COLUMNS_V1='public_id, "timestamp", known_to, session_id, sequence_id, instrument_public_id, trade_id, executed_at, price, size, side, id'

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
OUT_DIR="$ROOT/trades"
MANIFEST=${TRADES_MANIFEST:-"$ROOT/TRADES-MANIFEST.tsv"}
LOCK_FILE=${TRADES_LOCK_FILE:-"$ROOT/.trades-archive.lock"}
SCHEMA=${TRADES_SCHEMA:-public}
DB_URL_FILE=${SNAPPER_ENV_FILE:-}
EXPORT_STATEMENT_TIMEOUT=${EXPORT_STATEMENT_TIMEOUT:-2h}
EXPLAIN_STATEMENT_TIMEOUT=${EXPLAIN_STATEMENT_TIMEOUT:-30s}

[[ "$SCHEMA" =~ ^[a-z_][a-z0-9_]*$ ]] || {
  echo "ABORT $DAY: invalid TRADES_SCHEMA" >&2
  exit 2
}
[[ "$EXPORT_STATEMENT_TIMEOUT" =~ ^[1-9][0-9]*(ms|s|min|h)$ ]] || {
  echo "ABORT $DAY: invalid EXPORT_STATEMENT_TIMEOUT" >&2
  exit 2
}
[[ "$EXPLAIN_STATEMENT_TIMEOUT" =~ ^[1-9][0-9]*(ms|s|min|h)$ ]] || {
  echo "ABORT $DAY: invalid EXPLAIN_STATEMENT_TIMEOUT" >&2
  exit 2
}

mkdir -p "$OUT_DIR" "$(dirname "$MANIFEST")" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || {
  echo "REFUSE $DAY: another trades archive operation holds $LOCK_FILE" >&2
  exit 1
}

FILENAME="trades-$DAY.csv.zst"
OUT="$OUT_DIR/$FILENAME"
LOWER="${DAY}T00:00:00Z"
UPPER="${NEXT}T00:00:00Z"

if [[ -f "$MANIFEST" ]] &&
  awk -F $'\t' -v d="$DAY" '$2 == d { found=1 } END { exit !found }' "$MANIFEST"; then
  echo "REFUSE $DAY: trades manifest line already exists" >&2
  exit 1
fi
[[ ! -e "$OUT" ]] || {
  echo "REFUSE $DAY: archive already exists at $OUT" >&2
  exit 1
}

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
QUERY="SELECT $TRADE_EXPORT_COLUMNS_V1
FROM $RELATION
WHERE executed_at >= '$LOWER'::timestamptz
  AND executed_at < '$UPPER'::timestamptz
ORDER BY executed_at, id"

# This is deliberately plain EXPLAIN, never EXPLAIN ANALYZE. On production,
# refuse to run COPY unless the exact export query plans through an index in the
# parent's executed_at index family. A tiny scratch table may legitimately
# prefer a sequential scan.
PLAN=$("${PSQL[@]}" \
  -c "SET statement_timeout='$EXPLAIN_STATEMENT_TIMEOUT'" \
  -c "EXPLAIN (COSTS ON, VERBOSE OFF) $QUERY")
echo "EXPLAIN $SCHEMA.trades executed_at [$LOWER, $UPPER):"
printf '%s\n' "$PLAN"
if [[ "$SCHEMA" == "public" ]]; then
  EVENT_TIME_INDEXES=$("${PSQL[@]}" \
    -c "SET statement_timeout='$EXPLAIN_STATEMENT_TIMEOUT'" \
    -c "
WITH RECURSIVE event_time_indexes(index_oid) AS (
  SELECT index_state.indexrelid
  FROM pg_catalog.pg_class parent
  JOIN pg_catalog.pg_namespace parent_namespace
    ON parent_namespace.oid = parent.relnamespace
  JOIN pg_catalog.pg_attribute key_column
    ON key_column.attrelid = parent.oid
   AND key_column.attname = 'executed_at'
  JOIN pg_catalog.pg_index index_state
    ON index_state.indrelid = parent.oid
   AND index_state.indnkeyatts >= 1
   AND index_state.indkey[0] = key_column.attnum
   AND index_state.indexprs IS NULL
   AND index_state.indpred IS NULL
   AND index_state.indisvalid
   AND index_state.indisready
   AND index_state.indislive
  WHERE parent_namespace.nspname = '$SCHEMA'
    AND parent.relname = 'trades'

  UNION ALL

  SELECT inheritance.inhrelid
  FROM event_time_indexes
  JOIN pg_catalog.pg_inherits inheritance
    ON inheritance.inhparent = event_time_indexes.index_oid
)
SELECT pg_catalog.quote_ident(index_relation.relname)
FROM event_time_indexes
JOIN pg_catalog.pg_class index_relation
  ON index_relation.oid = event_time_indexes.index_oid
JOIN pg_catalog.pg_index index_state
  ON index_state.indexrelid = event_time_indexes.index_oid
WHERE index_relation.relkind = 'i'
  AND index_state.indisvalid
  AND index_state.indisready
  AND index_state.indislive
ORDER BY index_relation.relname;") || {
      echo "ABORT $DAY: could not inspect the trades event-time index family" >&2
      exit 1
    }

  PLAN_USES_EVENT_TIME_INDEX=false
  while IFS= read -r EVENT_TIME_INDEX; do
    [[ -n "$EVENT_TIME_INDEX" ]] || continue
    if [[ "$PLAN" == *"Index Scan using $EVENT_TIME_INDEX "* ||
      "$PLAN" == *"Index Only Scan using $EVENT_TIME_INDEX "* ||
      "$PLAN" == *"Bitmap Index Scan on $EVENT_TIME_INDEX "* ]]; then
      PLAN_USES_EVENT_TIME_INDEX=true
      break
    fi
  done <<<"$EVENT_TIME_INDEXES"

  if [[ "$PLAN_USES_EVENT_TIME_INDEX" != "true" ]]; then
    echo "ABORT $DAY: EXPLAIN did not use the trades executed_at index family; COPY was not run" >&2
    exit 1
  fi
fi

count_csv_rows() {
  nice -n19 ionice -c3 python3 -c '
import csv
import io
import sys

expected = [
    "public_id", "timestamp", "known_to", "session_id", "sequence_id",
    "instrument_public_id", "trade_id", "executed_at", "price", "size",
    "side", "id",
]
stream = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", newline="")
rows = csv.reader(stream, strict=True)
header = next(rows, None)
if header != expected:
    raise SystemExit(f"unexpected trades CSV header: {header!r}")
print(sum(1 for _ in rows))
'
}

COUNT_DIR=
ROW_COUNT_FILE=
COUNT_FIFO=
COUNT_PID=
PART=
cleanup() {
  if [[ -n "$COUNT_PID" ]] && kill -0 "$COUNT_PID" 2>/dev/null; then
    kill "$COUNT_PID" 2>/dev/null || true
    wait "$COUNT_PID" 2>/dev/null || true
  fi
  [[ -z "$ROW_COUNT_FILE" ]] || rm -f "$ROW_COUNT_FILE"
  [[ -z "$COUNT_FIFO" ]] || rm -f "$COUNT_FIFO"
  [[ -z "$COUNT_DIR" ]] || rmdir "$COUNT_DIR" 2>/dev/null || true
  [[ -z "$PART" ]] || rm -f "$PART"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

COUNT_DIR=$(mktemp -d "$OUT_DIR/.trades-$DAY.count.XXXXXX")
ROW_COUNT_FILE="$COUNT_DIR/rows"
COUNT_FIFO="$COUNT_DIR/stream"
mkfifo "$COUNT_FIFO"
PART=$(mktemp "$OUT_DIR/.trades-$DAY.csv.zst.part.XXXXXX")

count_csv_rows <"$COUNT_FIFO" >"$ROW_COUNT_FILE" &
COUNT_PID=$!
"${PSQL[@]}" \
  -c "SET statement_timeout='$EXPORT_STATEMENT_TIMEOUT'" \
  -c "COPY ($QUERY) TO STDOUT (FORMAT csv, HEADER)" \
  | tee "$COUNT_FIFO" \
  | nice -n19 ionice -c3 zstd -T4 -6 -q -f -o "$PART"
wait "$COUNT_PID"
COUNT_PID=

ROWS=$(<"$ROW_COUNT_FILE")
[[ "$ROWS" =~ ^[0-9]+$ ]] || {
  echo "ABORT $DAY: could not determine exported row count" >&2
  exit 1
}
FILE_ROWS=$(nice -n19 ionice -c3 zstdcat "$PART" | count_csv_rows)
[[ "$ROWS" == "$FILE_ROWS" ]] || {
  echo "FILE ROWCOUNT MISMATCH $DAY: db=$ROWS file=$FILE_ROWS" >&2
  exit 1
}

SHA=$(sha256sum "$PART" | cut -d' ' -f1)
BYTES=$(stat -c%s "$PART")
mv "$PART" "$OUT"
PART=

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$FILENAME" "$DAY" "$LOWER" "$UPPER" "$ROWS" "$BYTES" "$SHA" "$(date -u +%FT%TZ)" \
  >>"$MANIFEST"

echo "OK $DAY rows=$ROWS size=$BYTES sha=$SHA"
