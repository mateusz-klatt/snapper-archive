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

## Day-slicing differs by table, and it matters

Ticks are sliced by **bus time** and bracketed by binary search on `id`, which is
valid only because tick `id` is monotonic with arrival. Trades are sliced by
**event time** (`executed_at`), which is *not* monotonic with `id` — a trade
executed in May can arrive in June and carry a high id. The trades exporter
therefore uses an indexed range predicate, never a binary search. Copying the
ticks approach onto trades would silently file late arrivals under the wrong day.
