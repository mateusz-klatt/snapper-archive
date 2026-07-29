#!/usr/bin/env bash
set -euo pipefail
set +x
DAY="$1"; NEXT=$(date -u -d "$DAY + 1 day" +%F)
ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}; OUT="$ROOT/ticks/ticks-$DAY.csv.zst"
ENV_FILE=${SNAPPER_ENV_FILE:?set SNAPPER_ENV_FILE to the .env file containing DB_URL}
RAW=$(grep -E '^DB_URL=' "$ENV_FILE" | cut -d= -f2-)
u=${RAW#*//}; creds=${u%%@*}; export PGPASSWORD=${creds#*:}
DB_HOST_TO=${SNAPPER_DB_HOST_TO:?set SNAPPER_DB_HOST_TO to the database host reachable from this host}
PSQL="psql -h $DB_HOST_TO -U ${creds%%:*} -d snapper -X -qtA -v ON_ERROR_STOP=1"
bs(){ local t="$1" lo=1 hi mid r; hi=$($PSQL -c "SELECT max(id) FROM ticks")
  while (( lo < hi )); do mid=$(( (lo+hi)/2 ))
    r=$($PSQL -c "SELECT (\"timestamp\" >= '$t') FROM ticks WHERE id >= $mid ORDER BY id LIMIT 1")
    [[ "$r" == t ]] && hi=$mid || lo=$((mid+1)); done; echo $lo; }
LO=$(bs "$DAY 00:00:00+00"); HI=$(bs "$NEXT 00:00:00+00")
LOM=$(( LO>2000000 ? LO-2000000 : 1 )); HIM=$(( HI+2000000 ))
RC=$(mktemp)
$PSQL -c "SET statement_timeout=0" \
      -c "COPY (SELECT * FROM ticks WHERE id >= $LOM AND id < $HIM AND \"timestamp\" >= '$DAY 00:00:00+00' AND \"timestamp\" < '$NEXT 00:00:00+00' ORDER BY id) TO STDOUT (FORMAT csv, HEADER)" \
  | tee >(tail -n +2 | wc -l > "$RC") | zstd -T4 -6 -q -f -o "$OUT"
ROWS=$(cat "$RC"); rm -f "$RC"; SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
FROWS=$(zstdcat "$OUT" | tail -n +2 | wc -l)
[[ "$ROWS" == "$FROWS" ]] || { echo "FILE ROWCOUNT MISMATCH $DAY: db=$ROWS file=$FROWS"; exit 1; }
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "ticks-$DAY.csv.zst" "$DAY" "$LOM" "$HIM" "$ROWS" "$(stat -c%s "$OUT")" "$SHA" "$(date -u +%FT%TZ)" >> "$ROOT/MANIFEST.tsv"
echo "OK $DAY rows=$ROWS size=$(stat -c%s "$OUT") sha=$SHA"
