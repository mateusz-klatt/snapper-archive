#!/usr/bin/env bash
# Publish only the Polygon gitlink through a managed PR, then mirror approved mainline.
set -Eeuo pipefail
set +x
umask 077
export LC_ALL=C GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
unset GIT_INDEX_FILE GIT_WORK_TREE GIT_DIR GH_REPO GH_HOST

ROOT=${SNAPPER_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
REPO=${SNAPPER_APP_ROOT:-}
REMOTES=${SNAPPER_GITLINK_REMOTES:-}
BRANCH=automation/polygon-gitlink
MARKER='Snapper-Automation: polygon-gitlink-v1'
PR_MARKER='<!-- snapper-polygon-gitlink:v1 -->'
FAILS="$ROOT/.polygon-gitlink-fails"
PENDING="$ROOT/.polygon-gitlink-pending"
RUN_DIR=""
REF_ROOT=""
CHILD=""
PR_NUMBER=""
PR_HEAD=""
AUTO_HEAD=""
BASE=""
SUB=""
GH_REPOSITORY=""

failure() {
  local count
  trap - ERR
  printf 'gitlink: FAILED %s\n' "$1" >&2
  count=$(cat "$FAILS" 2>/dev/null || true)
  [[ "$count" =~ ^[0-9]{1,9}$ ]] || count=0
  printf '%s\n' "$((10#$count + 1))" >"$FAILS" || true
  exit 1
}

cleanup() {
  if [[ -n "$REF_ROOT" && -n "$REPO" ]]; then
    git -C "$REPO" update-ref -d "$REF_ROOT/master" >/dev/null 2>&1 || true
    git -C "$REPO" update-ref -d "$REF_ROOT/automation" >/dev/null 2>&1 || true
    if [[ -n "$CHILD" ]]; then
      git -C "$CHILD" update-ref -d "$REF_ROOT/child" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$RUN_DIR" ]]; then
    rm -rf -- "$RUN_DIR"
  fi
}

trap cleanup EXIT
trap 'failure "unexpected publisher error"' ERR
trap 'failure "publisher interrupted"' INT TERM

[[ -d "$ROOT" ]] || failure 'archive root is unavailable'
command -v flock >/dev/null 2>&1 || failure 'flock is required'
exec 8>"$ROOT/.polygon-gitlink.lock"
if flock -n 8; then
  :
else
  LOCK_RC=$?
  if [[ "$LOCK_RC" = 1 ]]; then
    echo 'gitlink: SKIP another publisher holds the lock'
    exit 0
  fi
  failure 'cannot acquire the publication lock'
fi
[[ -n "$REPO" && -d "$REPO" ]] || failure 'SNAPPER_APP_ROOT must name the application checkout'
[[ -n "$REMOTES" ]] || failure 'SNAPPER_GITLINK_REMOTES must name the existing remotes'
command -v gh >/dev/null 2>&1 || failure 'GitHub CLI is required'
RUN_DIR=$(mktemp -d "$ROOT/.polygon-gitlink.XXXXXX") || failure 'cannot create publication workspace'
REF_ROOT="refs/snapper-polygon-publish/run-$BASHPID-$RANDOM"
CHILD="$REPO/data/polygon"
[[ -d "$CHILD" ]] || failure 'Polygon checkout is unavailable'
CHILD_TOP=$(git -C "$CHILD" rev-parse --show-toplevel 2>/dev/null) || failure 'Polygon checkout is not a repository'
[[ "$(cd -- "$CHILD" && pwd -P)" = "$(cd -- "$CHILD_TOP" && pwd -P)" ]] \
  || failure 'Polygon submodule is not initialized'
cd -- "$REPO" || failure 'application checkout is unavailable'

resolve_github_repository() {
  local raw remainder authority host path owner name
  raw=$(git config --get-all remote.origin.url 2>/dev/null) \
    || failure 'cannot read the canonical origin identity'
  [[ -n "$raw" && "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] \
    || failure 'origin must have one supported GitHub URL'
  # Normalize in shell memory; raw URLs may contain credentials or query data.
  raw=${raw%%\?*}
  raw=${raw%%\#*}
  case "$raw" in
    git@github.com:*)
      path=${raw#git@github.com:}
      ;;
    ssh://git@github.com/*)
      path=${raw#ssh://git@github.com/}
      ;;
    ssh://git@github.com:22/*)
      path=${raw#ssh://git@github.com:22/}
      ;;
    https://*)
      remainder=${raw#https://}
      [[ "$remainder" = */* ]] || failure 'unsupported canonical GitHub origin'
      authority=${remainder%%/*}
      host=${authority##*@}
      [[ "$host" = github.com || "$host" = github.com:443 ]] \
        || failure 'unsupported canonical GitHub origin'
      path=${remainder#*/}
      ;;
    *)
      failure 'unsupported canonical GitHub origin'
      ;;
  esac
  path=${path%/}
  path=${path%.git}
  [[ "$path" =~ ^([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9_.-]+)$ ]] \
    || failure 'canonical GitHub origin has an unsupported repository path'
  owner=${BASH_REMATCH[1]}
  name=${BASH_REMATCH[2]}
  [[ "$name" != . && "$name" != .. ]] \
    || failure 'canonical GitHub origin has an unsupported repository path'
  GH_REPOSITORY="github.com/$owner/$name"
}

fetch_master() {
  git fetch --quiet --no-write-fetch-head origin "refs/heads/master:$REF_ROOT/master" 2>/dev/null \
    || failure 'cannot fetch canonical origin/master'
  BASE=$(git rev-parse "$REF_ROOT/master") || failure 'cannot resolve canonical master'
  [[ "$(git ls-tree "$BASE" data/polygon | cut -d' ' -f1)" = 160000 ]] \
    || failure 'canonical master does not contain the Polygon gitlink'
}

read_pr() {
  local rows number head managed cross extra count=0
  PR_NUMBER=""
  PR_HEAD=""
  rows=$(gh pr list --repo "$GH_REPOSITORY" --state open --base master --head "$BRANCH" \
    --json number,headRefOid,body,isCrossRepository \
    --jq '.[] | [.number, .headRefOid, (.body | contains("<!-- snapper-polygon-gitlink:v1 -->")), .isCrossRepository] | @tsv' \
    </dev/null 2>/dev/null) || failure 'cannot inspect the automation pull request'
  if [[ -z "$rows" ]]; then
    return
  fi
  while IFS=$'\t' read -r number head managed cross extra; do
    [[ -n "$number" ]] || continue
    count=$((count + 1))
    [[ "$number" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40}$ \
       && "$managed" = true && "$cross" = false && -z "$extra" ]] \
      || failure 'refusing an unmanaged automation pull request'
    PR_NUMBER=$number
    PR_HEAD=$head
  done <<<"$rows"
  [[ "$count" = 1 ]] || failure 'multiple automation pull requests require review'
}

fetch_automation() {
  local rc
  AUTO_HEAD=""
  if git ls-remote --exit-code origin "refs/heads/$BRANCH" >"$RUN_DIR/branch-refs" 2>/dev/null; then
    git fetch --quiet --no-write-fetch-head origin "refs/heads/$BRANCH:$REF_ROOT/automation" 2>/dev/null \
      || failure 'cannot fetch the automation branch'
    AUTO_HEAD=$(git rev-parse "$REF_ROOT/automation") || failure 'cannot resolve the automation branch'
  else
    rc=$?
    [[ "$rc" = 2 ]] || failure 'cannot inspect the automation branch'
  fi
  if [[ -n "$PR_NUMBER" && -n "$AUTO_HEAD" && "$PR_HEAD" != "$AUTO_HEAD" ]]; then
    failure 'automation branch changed during pull-request inspection; retry later'
  fi
}

validate_automation() {
  local commits commit parent message paths
  [[ -n "$AUTO_HEAD" ]] || return 0
  commits=$(git rev-list "$AUTO_HEAD" "^$BASE") || failure 'cannot inspect automation history'
  [[ -n "$commits" ]] || return 0
  while read -r commit; do
    parent=$(git rev-parse "$commit^1" 2>/dev/null) || failure 'automation history has no managed parent'
    message=$(git log -1 --format=%B "$commit") || failure 'cannot inspect automation provenance'
    grep -Fxq "$MARKER" <<<"$message" || failure 'refusing unmanaged automation history'
    paths=$(git diff-tree --no-commit-id --name-only -r "$parent" "$commit") \
      || failure 'cannot inspect automation changes'
    [[ "$paths" = data/polygon ]] || failure 'refusing non-gitlink automation changes'
    [[ "$(git ls-tree "$commit" data/polygon | cut -d' ' -f1)" = 160000 ]] \
      || failure 'automation history replaces the Polygon gitlink'
  done <<<"$commits"
}

publish_branch() {
  local tree existing message
  local -a parents
  GIT_INDEX_FILE="$RUN_DIR/index" git read-tree "$BASE" 2>/dev/null \
    || failure 'cannot prepare the isolated index'
  GIT_INDEX_FILE="$RUN_DIR/index" git update-index --cacheinfo "160000,$SUB,data/polygon" 2>/dev/null \
    || failure 'cannot update the isolated gitlink'
  tree=$(GIT_INDEX_FILE="$RUN_DIR/index" git write-tree 2>/dev/null) \
    || failure 'cannot write the isolated publication tree'
  [[ "$(git diff --name-only "$BASE" "$tree")" = data/polygon ]] \
    || failure 'publication tree changes more than the Polygon gitlink'
  if [[ -n "$AUTO_HEAD" ]]; then
    existing=$(git rev-parse "$AUTO_HEAD^{tree}") || failure 'cannot inspect the prior publication tree'
    if [[ "$tree" = "$existing" ]] && git merge-base --is-ancestor "$BASE" "$AUTO_HEAD"; then
      NEW_HEAD=$AUTO_HEAD
      return
    fi
  fi
  parents=(-p "$BASE")
  if [[ -n "$AUTO_HEAD" ]] && ! git merge-base --is-ancestor "$AUTO_HEAD" "$BASE"; then
    parents+=(-p "$AUTO_HEAD")
  fi
  message=$(printf 'polygon: update the approved data snapshot\n\n%s\n' "$MARKER")
  NEW_HEAD=$(git commit-tree "$tree" "${parents[@]}" -m "$message" 2>/dev/null) \
    || failure 'cannot create the managed gitlink commit'
  git push --quiet origin "$NEW_HEAD:refs/heads/$BRANCH" >/dev/null 2>&1 \
    || failure 'cannot fast-forward the automation branch; retry after reviewing concurrent changes'
}

queue_pr() {
  if [[ -z "$PR_NUMBER" ]]; then
    printf '%s\n\n%s\n%s\n' "$PR_MARKER" \
      'Update only data/polygon to its published origin/master snapshot.' \
      "Selected Polygon commit: $SUB" >"$RUN_DIR/pr-body"
    gh pr create --repo "$GH_REPOSITORY" --base master --head "$BRANCH" --title 'Update the Polygon data snapshot' \
      --body-file "$RUN_DIR/pr-body" </dev/null >/dev/null 2>&1 \
      || failure 'cannot create the automation pull request'
    read_pr
    [[ -n "$PR_NUMBER" ]] || failure 'created pull request is not visible'
  fi
  # GitHub may reject enabling auto-merge once the PR is already clean. A
  # normal merge with the identical head fence still enforces every rule.
  if ! gh pr merge "$PR_NUMBER" --repo "$GH_REPOSITORY" --auto --merge --match-head-commit "$NEW_HEAD" \
    </dev/null >/dev/null 2>&1; then
    gh pr merge "$PR_NUMBER" --repo "$GH_REPOSITORY" --merge --match-head-commit "$NEW_HEAD" \
      </dev/null >/dev/null 2>&1 || failure 'cannot request a policy-compliant merge at the expected head'
  fi
}

note_pending() {
  local now since saved_number saved_since extra age
  now=$(date -u +%s)
  since=$now
  if [[ -f "$PENDING" ]]; then
    if read -r saved_number saved_since extra <"$PENDING" \
       && [[ "$saved_number" = "$PR_NUMBER" && "$saved_since" =~ ^[0-9]{1,12}$ && -z "$extra" ]] \
       && (( 10#$saved_since <= now )); then
      since=$((10#$saved_since))
    fi
  fi
  printf '%s %s\n' "$PR_NUMBER" "$since" >"$RUN_DIR/pending"
  mv -- "$RUN_DIR/pending" "$PENDING"
  age=$((now - since))
  printf 'gitlink: PENDING PR #%s; queued for %ss, awaiting GitHub requirements\n' "$PR_NUMBER" "$age"
  if (( age >= 86400 )); then
    printf 'gitlink: PENDING PR #%s remains queued for at least a day; inspect its checks and reviews\n' "$PR_NUMBER"
  fi
}

mirror_approved_master() {
  local remote failed=0
  for remote in $REMOTES; do
    [[ "$remote" = origin ]] && continue
    [[ "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || failure 'invalid mirror remote name'
    git remote get-url -- "$remote" >/dev/null 2>&1 || failure 'a configured mirror remote is unavailable'
    if git push --porcelain --quiet "$remote" "$BASE:refs/heads/master" \
      >"$RUN_DIR/mirror-result" 2>"$RUN_DIR/mirror-errors"; then
      printf 'gitlink: mirror %s matches approved origin/master\n' "$remote"
    else
      failed=1
      if grep -Eq '\(non-fast-forward\)|\(fetch first\)' "$RUN_DIR/mirror-result" "$RUN_DIR/mirror-errors"; then
        printf 'gitlink: FAILED mirror %s diverges from approved origin/master; no history rewritten\n' "$remote" >&2
      else
        printf 'gitlink: FAILED mirror %s could not receive approved origin/master\n' "$remote" >&2
      fi
    fi
  done
  [[ "$failed" = 0 ]] || failure 'approved-master mirror synchronization failed'
}

resolve_github_repository
SUB=$(git -C "$CHILD" rev-parse HEAD 2>/dev/null) || failure 'cannot resolve selected Polygon HEAD'
git -C "$CHILD" fetch --quiet --no-write-fetch-head origin "refs/heads/master:$REF_ROOT/child" 2>/dev/null \
  || failure 'cannot verify the published Polygon snapshot'
[[ "$SUB" = "$(git -C "$CHILD" rev-parse "$REF_ROOT/child")" ]] \
  || failure 'selected Polygon HEAD is not the published origin/master snapshot'
fetch_master
read_pr
fetch_automation
validate_automation
RECORDED=$(git rev-parse "$BASE:data/polygon") || failure 'cannot inspect the canonical Polygon pin'
if [[ "$RECORDED" = "$SUB" ]]; then
  if [[ -n "$PR_NUMBER" ]]; then
    gh pr close "$PR_NUMBER" --repo "$GH_REPOSITORY" </dev/null >/dev/null 2>&1 || failure 'cannot close a stale managed pull request'
    printf 'gitlink: CLOSED stale PR #%s; canonical master already has the selected snapshot\n' "$PR_NUMBER"
  fi
  rm -f -- "$PENDING"
  echo 'gitlink: CURRENT canonical origin/master already has the selected snapshot'
else
  [[ -z "$PR_NUMBER" || -n "$AUTO_HEAD" ]] || failure 'managed pull-request branch is unavailable'
  publish_branch
  queue_pr
  fetch_master
  RECORDED=$(git rev-parse "$BASE:data/polygon") || failure 'cannot inspect the merged Polygon pin'
  if [[ "$RECORDED" = "$SUB" ]]; then
    rm -f -- "$PENDING"
    printf 'gitlink: MERGED PR #%s; canonical origin/master contains the selected snapshot\n' "$PR_NUMBER"
  else
    note_pending
  fi
fi
mirror_approved_master
rm -f -- "$FAILS"
