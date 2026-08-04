#!/usr/bin/env bash
# Shared failure alerting for the scheduled jobs. Source it, do not execute it.
#
# WHY THIS IS NEEDED AT ALL: every scheduled script here runs
# `exec >>"$LOG" 2>&1` on startup, so from that line onward cron receives no
# output and MAILTO can mail nothing. A job could therefore fail every night in
# complete silence — and one did, for two weeks, until its partitions nearly ran
# out. MAILTO remains useful, but only for the class of failure that happens
# BEFORE the redirect: a missing file, a syntax error, a failed exec, an OOM
# kill. Everything after it has to be mailed by the script itself.
#
# The destination comes from SNAPPER_ALERT_EMAIL in the crontab environment,
# never from this file. Pointing it at "root" and letting /etc/aliases resolve
# it keeps the real address in exactly one place on the host.

# Mail one failure summary. Body is the CURRENT run's operational lines only.
#
# Filtering is not cosmetic. The first alert this repo ever sent was a raw
# `tail -60`, which came through as forty lines of application startup banners
# with the actual refusal buried in the middle — unreadable on a phone, which is
# where an overnight alert is actually read.
#
#   $1  subject
#   $2  log file to summarise
#   $3  optional regex marking the start of a run (default: a `=== ` banner)
snapper_alert() {
  local subject="$1" logfile="$2" marker="${3:-^=== }"
  [ -n "${SNAPPER_ALERT_EMAIL:-}" ] || return 0
  command -v mail >/dev/null 2>&1 || return 0
  local body rc=0
  if [ -r "$logfile" ]; then
    body=$(awk -v m="$marker" '$0 ~ m { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$logfile" \
      | grep -E '^(===|==|--|OK|WARN|ABORT|REFUSE|SKIP|Snapper|refused:|FILE ROWCOUNT|purge mismatch)' \
      | tail -n 40) || body=""
  fi
  [ -n "$body" ] || body="$subject"

  # NEVER swallow a delivery failure. An alerting path that fails quietly is
  # strictly worse than none: it converts "nobody was told" into "we believe
  # somebody was told". Observed for real — msmtp's OAuth2 token refresh dies
  # when it cannot re-encrypt the token, so delivery works for about an hour
  # after a manual refresh and then stops, with `mail` reporting only a generic
  # non-zero exit. The `|| true` keeps a dead channel from taking the job down
  # with it, but the log now says so plainly.
  printf '%s\n' "$body" | mail -s "$subject" "$SNAPPER_ALERT_EMAIL" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ALERT-UNDELIVERED (mail rc=$rc) subject: $subject"
  fi
  return 0
}

# Install an EXIT trap that mails only when the script actually failed.
#
# Deliberately EXIT and not ERR. A lock-contention skip is a legitimate
# `exit 0`, and ERR cannot tell that apart from a failure — it would page
# someone every time two runs overlapped. An EXIT trap reads the real status.
#
# Install it AFTER the flock check, so a skip is never reported, and after the
# log redirect, so there is a log to summarise.
#
#   $1  job name used in the subject
#   $2  log file to summarise
#   $3  optional run-start regex, passed through to snapper_alert
snapper_alert_on_failure() {
  local job="$1" logfile="$2" marker="${3:-^=== }"
  # shellcheck disable=SC2064
  trap "rc=\$?; if [ \$rc -ne 0 ]; then snapper_alert \"Snapper ${job} FAILED (exit \$rc)\" \"${logfile}\" \"${marker}\"; fi" EXIT
}
