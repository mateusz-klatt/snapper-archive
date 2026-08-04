#!/usr/bin/env bash
# Export one UTC tick day to ticks/ticks-<DAY>.csv.zst and record it in
# MANIFEST.tsv.
#
# The day is resolved from the CATALOG, not by searching the id space. Before
# the 0043 daily-partition adoption a day had no physical boundary, so this
# script binary-searched `id` for the first row of each date — roughly sixty
# queries per export — and that search was correct only while `id` order matched
# `timestamp` order. A bulk load of historical evidence broke exactly that
# assumption once, filing June and July rows under the highest ids, and the
# computed window would then have clipped the export short. Nothing anywhere
# enforced the invariant it relied on.
#
# A day is now a partition, so its boundary is a catalog fact. Requiring the
# day's own leaf is also stronger than the old id window in a way that matters:
# it refuses a day whose leaf has already been dropped, where a DEFAULT-only
# scan would legitimately plan and COPY zero rows and report a successful export
# of nothing.
set -euo pipefail
set +x

DAY="$1"; NEXT=$(date -u -d "$DAY + 1 day" +%F)
LOWER="$DAY 00:00:00+00"; UPPER="$NEXT 00:00:00+00"
ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
OUT="$ROOT/ticks/ticks-$DAY.csv.zst"
SCHEMA=${SNAPPER_DB_SCHEMA:-public}
ENV_FILE=${SNAPPER_ENV_FILE:?set SNAPPER_ENV_FILE to the .env file containing DB_URL}
RAW=$(grep -E '^DB_URL=' "$ENV_FILE" | cut -d= -f2-)
u=${RAW#*//}; creds=${u%%@*}; export PGPASSWORD=${creds#*:}
DB_HOST_TO=${SNAPPER_DB_HOST_TO:?set SNAPPER_DB_HOST_TO to the database host reachable from this host}
PSQL="psql -h $DB_HOST_TO -U ${creds%%:*} -d snapper -X -qtA -v ON_ERROR_STOP=1"

# Match the day's leaf on its exact rendered partition bound, not on its name.
# A renamed or hand-made child then cannot be mistaken for the real one.
LEAF=$($PSQL -c "SET TIME ZONE 'UTC'" -c "
SELECT pg_catalog.quote_ident(child.relname)
FROM pg_catalog.pg_class parent
JOIN pg_catalog.pg_namespace parent_namespace
  ON parent_namespace.oid = parent.relnamespace
JOIN pg_catalog.pg_partitioned_table partitioned
  ON partitioned.partrelid = parent.oid
JOIN pg_catalog.pg_attribute key_column
  ON key_column.attrelid = partitioned.partrelid
 AND key_column.attnum = partitioned.partattrs[0]
JOIN pg_catalog.pg_inherits inheritance
  ON inheritance.inhparent = parent.oid
JOIN pg_catalog.pg_class child
  ON child.oid = inheritance.inhrelid
WHERE parent_namespace.nspname = '$SCHEMA'
  AND parent.relname = 'ticks'
  AND partitioned.partstrat = 'r'
  AND partitioned.partnatts = 1
  AND partitioned.partexprs IS NULL
  AND key_column.attname = 'timestamp'
  AND child.relispartition
  AND child.relkind = 'r'
  AND pg_catalog.pg_get_expr(child.relpartbound, child.oid) = format(
    'FOR VALUES FROM (%L) TO (%L)',
    '$LOWER'::timestamptz,
    '$UPPER'::timestamptz
  );") || {
  echo "ABORT $DAY: could not resolve the exact ticks partition" >&2
  exit 1
}

[[ -n "$LEAF" ]] || {
  echo "REFUSE $DAY: no exact daily ticks partition; export could be empty or incomplete" >&2
  exit 1
}
[[ "$LEAF" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
  echo "ABORT $DAY: ambiguous or unquotable ticks partition catalog result" >&2
  exit 1
}

# MANIFEST columns 3 and 4 stay an id range: purge-ticks-day.sh reads them
# positionally and validates that both are numeric and ascending. They are now
# the leaf's EXACT bounds, read from its primary key, rather than a padded
# estimate around a searched boundary. An empty day yields 0 and 1, which still
# satisfies that validation.
ID_BOUNDS=$($PSQL -c "SELECT COALESCE(min(id), 0) || ' ' || (COALESCE(max(id), 0) + 1) FROM $LEAF")
read -r ID_LOWER ID_UPPER <<<"$ID_BOUNDS"

RC=$(mktemp)
$PSQL -c "SET statement_timeout=0" \
      -c "SET TIME ZONE 'UTC'" \
      -c "COPY (SELECT * FROM ticks WHERE \"timestamp\" >= '$LOWER' AND \"timestamp\" < '$UPPER' ORDER BY id) TO STDOUT (FORMAT csv, HEADER)" \
  | tee >(tail -n +2 | wc -l > "$RC") | zstd -T4 -6 -q -f -o "$OUT"
ROWS=$(cat "$RC"); rm -f "$RC"; SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
FROWS=$(zstdcat "$OUT" | tail -n +2 | wc -l)
[[ "$ROWS" == "$FROWS" ]] || { echo "FILE ROWCOUNT MISMATCH $DAY: db=$ROWS file=$FROWS"; exit 1; }
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "ticks-$DAY.csv.zst" "$DAY" "$ID_LOWER" "$ID_UPPER" "$ROWS" "$(stat -c%s "$OUT")" "$SHA" "$(date -u +%FT%TZ)" >> "$ROOT/MANIFEST.tsv"
echo "OK $DAY rows=$ROWS size=$(stat -c%s "$OUT") sha=$SHA leaf=$LEAF"
