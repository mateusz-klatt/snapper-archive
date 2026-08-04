#!/usr/bin/env bash
# Weekly sweep of closed (SCD2 superseded) candle versions. Active candles are
# never eligible: `--closed-only` restricts to rows whose known_to has already
# been moved off the sentinel by upsert_candles.
#
# NOTE the date range filters on the candle's open_at, NOT on when the version
# was closed — a bar backfilled for 2023 and re-closed yesterday still lives in
# the 2023 slice. That is why the range starts at 2023-01-01 and not at "recent".
set -euo pipefail
set +x

ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
LOG="$ROOT/logs/candles-sweep-$(date -u +%Y-%m).log"
mkdir -p "$ROOT/logs"

exec 9>"$ROOT/.candles.lock"
flock -n 9 || { echo "$(date -u +%FT%TZ) SKIP: another candle sweep holds the lock" >>"$LOG"; exit 0; }
exec >>"$LOG" 2>&1

# Failure alerting. Sourced AFTER the flock check so a legitimate skip never
# pages anyone, and after the redirect so there is a log to summarise. A missing
# helper is fatal on purpose: this job's failures would otherwise go nowhere,
# and cron's MAILTO still catches an abort at this point.
. "$(dirname -- "${BASH_SOURCE[0]}")/_alert.sh"
snapper_alert_on_failure "candles-sweep" "$LOG"

FROM=${FROM:-2023-01-01}
TO=${TO:-$(date -u -d "today - 7 days" +%F)}
echo "=== candles sweep $(date -u +%FT%TZ) range=$FROM..$TO ==="

FREE_GB=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
(( FREE_GB >= 20 )) || { echo "ABORT: archive disk ${FREE_GB}G free"; exit 1; }

REPO=${SNAPPER_APP_ROOT:?set SNAPPER_APP_ROOT to the Snapper application checkout}
cd "$REPO"
# Connecting over the bridge address makes the server see a different source
# address, which pg_hba.conf rejects. Rewrite the URL host to the allowed address.
ENV_FILE=${SNAPPER_ENV_FILE:?set SNAPPER_ENV_FILE to the .env file containing DB_URL}
DB_HOST_FROM=${SNAPPER_DB_HOST_FROM:?set SNAPPER_DB_HOST_FROM to the host written in DB_URL}
DB_HOST_TO=${SNAPPER_DB_HOST_TO:?set SNAPPER_DB_HOST_TO to the database host reachable from this host}
RAW=$(grep -E '^DB_URL=' "$ENV_FILE" | cut -d= -f2-)
export DB_URL="${RAW//$DB_HOST_FROM/$DB_HOST_TO}"

for TF in 1m 5m 15m 30m 1h 4h 1d; do
  echo "== $TF $(date -u +%T)"
  .venv/bin/snapper archive --table candles-audit --closed-only --timeframe "$TF" \
    --from "$FROM" --to "$TO" --output-dir "$ROOT" --purge
  echo "rc=$?"
done

echo "=== candles sweep done $(date -u +%FT%TZ) ==="
