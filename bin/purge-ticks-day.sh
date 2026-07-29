#!/usr/bin/env bash
# Purge one exported ticks day. Refuses unless the manifest line exists, the file's
# sha256 matches, and the DELETE row count equals the manifest row count (transactional).
set -euo pipefail
set +x
DAY="$1"; NEXT=$(date -u -d "$DAY + 1 day" +%F)
ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}; F="$ROOT/ticks/ticks-$DAY.csv.zst"
LINE=$(awk -F'\t' -v d="$DAY" '$2==d {print; exit}' "$ROOT/MANIFEST.tsv")
[[ -n "$LINE" ]] || { echo "REFUSE $DAY: no manifest line"; exit 1; }
IFS=$'\t' read -r _f _d LOM HIM ROWS BYTES SHA _t <<< "$LINE"
[[ -f "$F" ]] || { echo "REFUSE $DAY: file missing"; exit 1; }
ACTUAL=$(sha256sum "$F" | cut -d' ' -f1)
[[ "$ACTUAL" == "$SHA" ]] || { echo "REFUSE $DAY: sha mismatch"; exit 1; }
[[ "$(stat -c%s "$F")" == "$BYTES" ]] || { echo "REFUSE $DAY: size mismatch"; exit 1; }
ENV_FILE=${SNAPPER_ENV_FILE:?set SNAPPER_ENV_FILE to the .env file containing DB_URL}
RAW=$(grep -E '^DB_URL=' "$ENV_FILE" | cut -d= -f2-)
u=${RAW#*//}; creds=${u%%@*}; export PGPASSWORD=${creds#*:}
DB_HOST_TO=${SNAPPER_DB_HOST_TO:?set SNAPPER_DB_HOST_TO to the database host reachable from this host}
psql -h "$DB_HOST_TO" -U "${creds%%:*}" -d snapper -X -qtA -v ON_ERROR_STOP=1 \
  -c "SET statement_timeout=0" -c "SET maintenance_work_mem='1GB'" -c "
DO \$\$
DECLARE n bigint;
BEGIN
  DELETE FROM ticks WHERE id >= $LOM AND id < $HIM
    AND \"timestamp\" >= '$DAY 00:00:00+00' AND \"timestamp\" < '$NEXT 00:00:00+00';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> $ROWS THEN
    RAISE EXCEPTION 'purge mismatch for $DAY: deleted % vs manifest $ROWS', n;
  END IF;
  RAISE NOTICE 'purged $DAY: % rows', n;
END\$\$;"
echo "PURGED $DAY rows=$ROWS"
