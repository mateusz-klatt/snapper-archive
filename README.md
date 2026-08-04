# snapper-archive

Operational tooling that moves market data out of the Snapper production
database and into the configured archive root, and the retention jobs that then
remove it.

**This repository versions the scripts, never the data.** The archive payload —
tens of gigabytes of `.csv.zst` under `archive/` and `ticks/`, plus the
`MANIFEST` ledgers — is deliberately excluded. Its integrity is guaranteed by
the sha256 and row counts recorded in the manifests, which is a stronger
guarantee than git could offer for files of that size, and versioning
append-only ledgers would conflict on every run.

## Why this exists as a repository at all

These scripts delete production data. `purge-ticks-day.sh` and
`purge-trades-day.sh` detach and drop only the exact daily partition for a day
whose manifest and archive they verify first. Until 2026-07-29 the scripts lived
on one disk with no history, so a bad edit had no way back and no way to review.
That is the gap this closes.

## The safety contract every script here honours

- **The production host also carries latency-sensitive network traffic.** Every
  heavy operation runs under `nice -n19 ionice -c3`, and the backfill driver
  parks itself when load per CPU rises above its ceiling rather than competing.
- **Purges refuse unless the export is proven.** Row count and sha256 must match
  the manifest, and `purge-trades-day.sh` additionally requires
  `ALLOW_PRODUCTION_TRADES_PURGE=YES` before it will touch `public`.
- **Exports refuse a bad query plan.** `export-trades-day.sh` aborts if `EXPLAIN`
  does not show an index in the catalog-attached `executed_at` index family; a
  sequential scan of the production table is an outage, not a slow job.
- **The password is never echoed**, including under `bash -x`.
- **Column order is pinned and immutable.** The restorer consumes the first three
  fields positionally, so `SELECT *` is unsafe — physical column order does not
  match the restore contract.

## Layout

    bin/                 the scripts (versioned)
    archive/, ticks/     exported payload (ignored)
    MANIFEST.tsv         ticks ledger, keyed by day (ignored)
    TRADES-MANIFEST.tsv  trades ledger, keyed by day (ignored)
    logs/                run logs (ignored)

## Partition renewal needs two anchors, and the tool's own count lies

`partitions-daily.sh` keeps the forward window of daily leaves alive. Two things
about it are counter-intuitive enough to be worth stating before someone
"simplifies" them.

**Two `ensure` calls per table is not redundant.** The tool's window is
`anchor .. anchor+13` — a total span, not "N days back plus fourteen forward".
Anchoring in the past therefore buys backward coverage *out of* forward headroom
rather than adding to it. Measured against a live database: `--anchor today`
planned two new leaves at the forward edge, while `--anchor today-4` planned
exactly one backward leaf and nothing forward at all.

**Never report headroom from the tool's "future daily leaves".** It counts
leaves at or after the *anchor*, so a past anchor over-reports by the width of
the backward window — the same database that genuinely had eleven days of
forward cover reported sixteen. The script computes headroom itself, as
contiguous daily leaves starting at today, in UTC.

**The backward buffer is per table, and zero for ticks.** Tick partitions key on
receive time, so late data still lands on the current day and a backward leaf
buys nothing; ticks is also the only table whose leaves this repository drops,
so a backward leaf for an already-exported day could accept rows the manifest
already calls done — wedging retention permanently. Candles and trades key on
event time, nothing scheduled drops their leaves, and they get four days.

**A nonzero exit is not an alert.** Every script here redirects its own output to
a monthly log on startup, so cron has nothing to mail and `MAILTO` would change
nothing. Failures are mailed explicitly via `SNAPPER_ALERT_EMAIL`, and a run
that only ever skips on a held lock is caught by a last-success stamp — a skip
exits zero by design and is otherwise indistinguishable from a quiet healthy day.

**DDL goes through the application CLI, never hand-written SQL.** A bare
`CREATE TABLE ... PARTITION OF` inherits the parent's indexes but silently omits
the leaf-local primary key and the active-`public_id` unique index. Two leaves
created by hand this way carried no primary key at all until it was noticed.

## Day-slicing differs by table, and it matters

Ticks are sliced by **bus time** and bracketed by binary search on `id`, which is
valid only because tick `id` is monotonic with arrival. Trades are sliced by
**event time** (`executed_at`), which is *not* monotonic with `id` — a trade
executed in May can arrive in June and carry a high id. The trades exporter
therefore uses an indexed range predicate, never a binary search. Copying the
ticks approach onto trades would silently file late arrivals under the wrong day.
