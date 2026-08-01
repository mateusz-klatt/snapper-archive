#!/usr/bin/env bash
# Purge one verified UTC trade day by exchange event time.
#
# Refuses before connecting unless the trades manifest line and archive exist
# and the compressed file's sha256 and byte size match. An exact daily partition
# is counted, detached, and dropped atomically; a day in a wider legacy partition
# keeps the transactional DELETE and row-count assertion path.
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

# Resolve the storage for this day from PostgreSQL's partition catalog. An exact
# daily range is the only shape eligible for DETACH + DROP. A wider explicit
# range (the legacy partition in production) stays on DELETE. If no explicit
# range covers the complete day, the DEFAULT partition would receive it and is
# a routing failure, not a purge target.
PARENT_STATE=$("${PSQL[@]}" -F $'\t' \
  -c "SET statement_timeout='$EXPLAIN_STATEMENT_TIMEOUT'" \
  -c "
SELECT parent.relkind,
       CASE
         WHEN parent.relkind <> 'p' THEN true
         ELSE EXISTS (
           SELECT 1
           FROM pg_catalog.pg_partitioned_table partitioned
           JOIN pg_catalog.pg_attribute key_column
             ON key_column.attrelid = partitioned.partrelid
            AND key_column.attnum = partitioned.partattrs[0]
           WHERE partitioned.partrelid = parent.oid
             AND partitioned.partstrat = 'r'
             AND partitioned.partnatts = 1
             AND partitioned.partexprs IS NULL
             AND key_column.attname = 'executed_at'
         )
       END
FROM pg_catalog.pg_class parent
JOIN pg_catalog.pg_namespace parent_namespace
  ON parent_namespace.oid = parent.relnamespace
WHERE parent_namespace.nspname = '$SCHEMA'
  AND parent.relname = 'trades';") || {
  echo "ABORT $DAY: could not inspect trades partition catalog" >&2
  exit 1
}

[[ -n "$PARENT_STATE" && "$PARENT_STATE" != *$'\n'* ]] || {
  echo "ABORT $DAY: trades relation is missing or ambiguous" >&2
  exit 1
}
IFS=$'\t' read -r PARENT_RELKIND PARTITION_KEY_OK <<<"$PARENT_STATE"
case "$PARENT_RELKIND" in
  r)
    PURGE_MODE=DELETE
    ;;
  p)
    [[ "$PARTITION_KEY_OK" == "t" ]] || {
      echo "ABORT $DAY: $SCHEMA.trades is not range-partitioned on executed_at" >&2
      exit 1
    }

    PARTITION_DECISION=$("${PSQL[@]}" -F $'\t' \
      -c "SET statement_timeout='$EXPLAIN_STATEMENT_TIMEOUT'" \
      -c "SET TIME ZONE 'UTC'" \
      -c "
WITH children AS (
  SELECT child.oid,
         child_namespace.nspname,
         child.relname,
         child.relkind,
         pg_catalog.pg_get_expr(child.relpartbound, child.oid) AS bound
  FROM pg_catalog.pg_class parent
  JOIN pg_catalog.pg_namespace parent_namespace
    ON parent_namespace.oid = parent.relnamespace
  JOIN pg_catalog.pg_inherits inheritance
    ON inheritance.inhparent = parent.oid
  JOIN pg_catalog.pg_class child
    ON child.oid = inheritance.inhrelid
  JOIN pg_catalog.pg_namespace child_namespace
    ON child_namespace.oid = child.relnamespace
  WHERE parent_namespace.nspname = '$SCHEMA'
    AND parent.relname = 'trades'
), exact_partition AS (
  SELECT *
  FROM children
  WHERE bound = format(
    'FOR VALUES FROM (%L) TO (%L)',
    '$LOWER'::timestamptz,
    '$UPPER'::timestamptz
  )
), parsed_ranges AS (
  SELECT children.*,
         CASE
           WHEN parts[1] = 'MINVALUE' THEN '-infinity'::timestamptz
           ELSE parts[2]::timestamptz
         END AS lower_bound,
         CASE
           WHEN parts[3] = 'MAXVALUE' THEN 'infinity'::timestamptz
           ELSE parts[4]::timestamptz
         END AS upper_bound
  FROM children
  CROSS JOIN LATERAL pg_catalog.regexp_match(
    children.bound,
    '^FOR VALUES FROM \((MINVALUE|''([^'']+)'')\) TO \((MAXVALUE|''([^'']+)'')\)$'
  ) AS matched(parts)
), covering_partition AS (
  SELECT *
  FROM parsed_ranges
  WHERE lower_bound <= '$LOWER'::timestamptz
    AND upper_bound >= '$UPPER'::timestamptz
), default_partition AS (
  SELECT *
  FROM children
  WHERE bound = 'DEFAULT'
), decisions AS (
  SELECT 1 AS priority, 'REFUSE'::text AS mode, ''::name AS nspname, ''::name AS relname
  WHERE (SELECT count(*) FROM exact_partition) > 1
     OR EXISTS (SELECT 1 FROM exact_partition WHERE relkind <> 'r')

  UNION ALL

  SELECT 2, 'PARTITION', nspname, relname
  FROM exact_partition
  WHERE relkind = 'r'

  UNION ALL

  SELECT 3, 'DELETE', ''::name, ''::name
  WHERE NOT EXISTS (SELECT 1 FROM exact_partition)
    AND EXISTS (SELECT 1 FROM covering_partition)

  UNION ALL

  SELECT 4, 'DEFAULT', nspname, relname
  FROM default_partition
  WHERE NOT EXISTS (SELECT 1 FROM exact_partition)
    AND NOT EXISTS (SELECT 1 FROM covering_partition)

  UNION ALL

  SELECT 5, 'DELETE', ''::name, ''::name
  WHERE NOT EXISTS (SELECT 1 FROM exact_partition)
    AND NOT EXISTS (SELECT 1 FROM covering_partition)
    AND NOT EXISTS (SELECT 1 FROM default_partition)
)
SELECT mode, nspname, relname
FROM decisions
ORDER BY priority
LIMIT 1;") || {
      echo "ABORT $DAY: could not resolve trades partition for target day" >&2
      exit 1
    }

    [[ -n "$PARTITION_DECISION" && "$PARTITION_DECISION" != *$'\n'* ]] || {
      echo "ABORT $DAY: ambiguous trades partition catalog result" >&2
      exit 1
    }
    IFS=$'\t' read -r PURGE_MODE TARGET_PARTITION_SCHEMA TARGET_PARTITION_NAME \
      <<<"$PARTITION_DECISION"
    ;;
  *)
    echo "ABORT $DAY: unsupported $SCHEMA.trades relation kind" >&2
    exit 1
    ;;
esac

case "$PURGE_MODE" in
  PARTITION)
    if ! "${PSQL[@]}" \
      -c "SET statement_timeout='$PURGE_STATEMENT_TIMEOUT'" \
      -c "SET TIME ZONE 'UTC'" \
      -c "
DO \$\$
DECLARE
  parent_oid oid;
  child_schema name;
  child_name name;
  partition_matches integer;
  n bigint;
BEGIN
  SELECT parent.oid
    INTO parent_oid
  FROM pg_catalog.pg_class parent
  JOIN pg_catalog.pg_namespace parent_namespace
    ON parent_namespace.oid = parent.relnamespace
  WHERE parent_namespace.nspname = '$SCHEMA'
    AND parent.relname = 'trades';

  IF parent_oid IS NULL THEN
    RAISE EXCEPTION 'trades parent disappeared before purge';
  END IF;

  LOCK TABLE ONLY $RELATION IN ACCESS EXCLUSIVE MODE;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_partitioned_table partitioned
    JOIN pg_catalog.pg_attribute key_column
      ON key_column.attrelid = partitioned.partrelid
     AND key_column.attnum = partitioned.partattrs[0]
    WHERE partitioned.partrelid = parent_oid
      AND partitioned.partstrat = 'r'
      AND partitioned.partnatts = 1
      AND partitioned.partexprs IS NULL
      AND key_column.attname = 'executed_at'
  ) THEN
    RAISE EXCEPTION 'trades partition key changed before purge';
  END IF;

  SELECT count(*)
    INTO partition_matches
  FROM pg_catalog.pg_inherits inheritance
  JOIN pg_catalog.pg_class child
    ON child.oid = inheritance.inhrelid
  WHERE inheritance.inhparent = parent_oid
    AND child.relispartition
    AND child.relkind = 'r'
    AND pg_catalog.pg_get_expr(child.relpartbound, child.oid) = format(
      'FOR VALUES FROM (%L) TO (%L)',
      '$LOWER'::timestamptz,
      '$UPPER'::timestamptz
    );

  IF partition_matches <> 1 THEN
    RAISE EXCEPTION 'exact trades partition changed before purge: found %', partition_matches;
  END IF;

  SELECT child_namespace.nspname, child.relname
    INTO STRICT child_schema, child_name
  FROM pg_catalog.pg_inherits inheritance
  JOIN pg_catalog.pg_class child
    ON child.oid = inheritance.inhrelid
  JOIN pg_catalog.pg_namespace child_namespace
    ON child_namespace.oid = child.relnamespace
  WHERE inheritance.inhparent = parent_oid
    AND child.relispartition
    AND child.relkind = 'r'
    AND pg_catalog.pg_get_expr(child.relpartbound, child.oid) = format(
      'FOR VALUES FROM (%L) TO (%L)',
      '$LOWER'::timestamptz,
      '$UPPER'::timestamptz
    );

  EXECUTE format(
    'LOCK TABLE ONLY %I.%I IN ACCESS EXCLUSIVE MODE',
    child_schema,
    child_name
  );
  EXECUTE format(
    'SELECT count(*) FROM ONLY %I.%I',
    child_schema,
    child_name
  ) INTO n;

  IF n <> $ROWS THEN
    RAISE EXCEPTION 'purge mismatch for $DAY: partition rows % vs manifest $ROWS', n;
  END IF;

  EXECUTE format(
    'ALTER TABLE %I.%I DETACH PARTITION %I.%I',
    '$SCHEMA',
    'trades',
    child_schema,
    child_name
  );
  EXECUTE format('DROP TABLE %I.%I', child_schema, child_name);
  RAISE NOTICE 'purged $DAY via partition: % rows', n;
END
\$\$;"; then
      echo "REFUSE $DAY: partition purge transaction did not commit" >&2
      exit 1
    fi

    echo "PURGED $DAY rows=$ROWS"
    exit 0
    ;;
  DEFAULT)
    echo "REFUSE $DAY: target day resolves to default partition $TARGET_PARTITION_SCHEMA.$TARGET_PARTITION_NAME" >&2
    exit 1
    ;;
  DELETE)
    ;;
  *)
    echo "REFUSE $DAY: target day does not have one safe purge mapping" >&2
    exit 1
    ;;
esac

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
  -c "SET TIME ZONE 'UTC'" \
  -c "
DO \$\$
DECLARE
  parent_oid oid;
  parent_relkind "char";
  n bigint;
BEGIN
  LOCK TABLE ONLY $RELATION IN SHARE UPDATE EXCLUSIVE MODE;

  SELECT parent.oid, parent.relkind
    INTO STRICT parent_oid, parent_relkind
  FROM pg_catalog.pg_class parent
  JOIN pg_catalog.pg_namespace parent_namespace
    ON parent_namespace.oid = parent.relnamespace
  WHERE parent_namespace.nspname = '$SCHEMA'
    AND parent.relname = 'trades';

  IF parent_relkind = 'p' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_partitioned_table partitioned
      JOIN pg_catalog.pg_attribute key_column
        ON key_column.attrelid = partitioned.partrelid
       AND key_column.attnum = partitioned.partattrs[0]
      WHERE partitioned.partrelid = parent_oid
        AND partitioned.partstrat = 'r'
        AND partitioned.partnatts = 1
        AND partitioned.partexprs IS NULL
        AND key_column.attname = 'executed_at'
    ) THEN
      RAISE EXCEPTION 'trades partition key changed before DELETE';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_inherits inheritance
      JOIN pg_catalog.pg_class child
        ON child.oid = inheritance.inhrelid
      CROSS JOIN LATERAL pg_catalog.regexp_match(
        pg_catalog.pg_get_expr(child.relpartbound, child.oid),
        '^FOR VALUES FROM \((MINVALUE|''([^'']+)'')\) TO \((MAXVALUE|''([^'']+)'')\)$'
      ) AS matched(parts)
      WHERE inheritance.inhparent = parent_oid
        AND child.relispartition
        AND child.relkind = 'r'
        AND pg_catalog.pg_get_expr(child.relpartbound, child.oid) <> format(
          'FOR VALUES FROM (%L) TO (%L)',
          '$LOWER'::timestamptz,
          '$UPPER'::timestamptz
        )
        AND CASE
              WHEN parts[1] = 'MINVALUE' THEN '-infinity'::timestamptz
              ELSE parts[2]::timestamptz
            END <= '$LOWER'::timestamptz
        AND CASE
              WHEN parts[3] = 'MAXVALUE' THEN 'infinity'::timestamptz
              ELSE parts[4]::timestamptz
            END >= '$UPPER'::timestamptz
    ) THEN
      RAISE EXCEPTION 'trades DELETE route for $DAY changed or resolves to default';
    END IF;
  ELSIF parent_relkind <> 'r' THEN
    RAISE EXCEPTION 'unsupported trades relation kind before DELETE';
  END IF;

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
