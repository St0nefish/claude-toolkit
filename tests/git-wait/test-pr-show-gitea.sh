#!/usr/bin/env bash
# test-pr-show-gitea.sh — Test harness for git-wait's Gitea PR-detail
# normalizer (the private `_pr_show` function), exercised through the public
# `pr wait` surface.
#
# Regression test for #140: `tea pr list`'s JSON omits the `merged` boolean
# and `merged_at` timestamp and emits `mergeable` as a string, so a merged PR
# reported merged:false / mergedAt:null and consumers thought it was still
# open. The fix fetches the PR detail via
# `tea api repos/{owner}/{repo}/pulls/<n>` and derives the merge fields from
# it. `_pr_show` is no longer a public subcommand (`pr show <N>` was removed
# along with the rest of the CLI-wrapper surface) but its normalizer is still
# load-bearing inside `pr wait`'s poll loop, so these tests drive it from
# there.
#
# The regression is proved by deliberately mismatching the two data sources:
# `tea pr list` (used only to resolve branch → PR number) reports state=open,
# merged=false — the stale/unreliable shape #140 was about — while
# `tea api .../pulls/<n>` (the fix) reports merged=true. If `pr wait` ever
# regresses to trusting `pr list`'s own state again, these tests will report
# the PR as still open instead of merged.
#
# Uses mock git/tea scripts via PATH injection.
#
# Usage: bash tests/git-wait/test-pr-show-gitea.sh [filter]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_WAIT="$SCRIPT_DIR/../../utils/git-wait"
source "$SCRIPT_DIR/../lib/mock-git.sh"

PASS=0
FAIL=0
SKIP=0
FILTER="${1:-}"

MOCK_DIR=""
cleanup() { [[ -n "$MOCK_DIR" ]] && rm -rf "$MOCK_DIR"; }
trap cleanup EXIT
MOCK_DIR=$(mktemp -d)

pass() {
  printf "  \033[32m✓\033[0m %s\n" "$1"
  ((PASS++)) || true
}

fail() {
  printf "  \033[31m✗\033[0m %s  (%s)\n" "$1" "$2"
  ((FAIL++)) || true
}

skip_filter() {
  [[ -n "$FILTER" ]] && ! echo "$1" | grep -qi "$FILTER"
}

# Mock git: report a Gitea remote so platform detection resolves to "gitea".
write_mock_git "$MOCK_DIR" "https://git.stonefish.tech/owner/repo.git"

# write_tea_mock <pr-list-state> <pr-list-merged> <pulls-detail-body-or-"FAIL">
#
# pr list (branch resolution only) always reports the STALE shape (#140):
# state=open, merged=false, mergeable as a bare string. pulls/7 (the fix path)
# returns whatever detail body is passed in — the source of truth pr wait
# must actually use.
write_tea_mock() {
  local list_state="$1" list_merged="$2" detail="$3"
  cat >"$MOCK_DIR/tea" <<EOF
#!/usr/bin/env bash
case "\$1 \$2 \$3" in
  "login list --output") echo '[{"url":"https://git.stonefish.tech"}]'; exit 0 ;;
  "pr list --output")
    echo '[{"index":7,"title":"Add widget","body":"","state":"$list_state","head":"feature-widget","base":"master","author":"stonefish","labels":[],"assignees":[],"mergeable":null,"created":"2026-05-31T09:00:00Z","updated":"2026-06-01T10:00:00Z","url":"https://git.stonefish.tech/owner/repo/pulls/7"}]'
    exit 0
    ;;
esac
case "\$1:\$2" in
  api:repos/{owner}/{repo}/pulls/7)
EOF
  if [[ "$detail" == "FAIL" ]]; then
    cat >>"$MOCK_DIR/tea" <<'EOF'
    echo "404 Not Found" >&2; exit 1 ;;
EOF
  else
    {
      echo "    cat <<'JSON'"
      echo "$detail"
      echo "JSON"
      echo "    ;;"
    } >>"$MOCK_DIR/tea"
  fi
  cat >>"$MOCK_DIR/tea" <<'EOF'
  *) echo "unexpected tea call: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$MOCK_DIR/tea"
}

# ---------------------------------------------------------------------------
# Test: pr wait reports merged via the REST-fetched detail even though the
# list-based lookup (the pre-#140 source) still shows the PR as open.
# ---------------------------------------------------------------------------

echo "── pr show normalizer (via pr wait): Gitea REST merge fields (#140) ──"

label="pr wait reports status: merged from REST detail, not from stale pr-list state"
if ! skip_filter "$label"; then
  write_tea_mock "open" "false" '{
  "number": 7,
  "title": "Add widget",
  "body": "body text",
  "state": "closed",
  "merged": true,
  "merged_at": "2026-06-01T10:00:00Z",
  "mergeable": true,
  "user": {"login": "stonefish"},
  "head": {"ref": "feature-widget"},
  "base": {"ref": "master"},
  "labels": [{"name": "enhancement"}],
  "assignees": [{"login": "stonefish"}],
  "created_at": "2026-05-31T09:00:00Z",
  "updated_at": "2026-06-01T10:00:00Z",
  "html_url": "https://git.stonefish.tech/owner/repo/pulls/7"
}'

  exit_code=0
  output=$(PATH="$MOCK_DIR:$PATH" bash "$GIT_WAIT" pr wait --branch feature-widget \
    --timeout 5 --idle-timeout 5 --interval 1 2>"$MOCK_DIR/stderr") || exit_code=$?
  stderr=$(cat "$MOCK_DIR/stderr")

  errs=()
  [[ "$exit_code" == "0" ]] || errs+=("exit=$exit_code")
  echo "$output" | grep -q "^status: merged" || errs+=("no 'status: merged'")
  echo "$output" | grep -q "^pr_number: 7" || errs+=("no 'pr_number: 7'")
  echo "$output" | grep -q "^url: https://git.stonefish.tech/owner/repo/pulls/7" || errs+=("wrong url")

  if [[ ${#errs[@]} -eq 0 ]]; then
    pass "$label"
  else
    fail "$label" "$(
      IFS='; '
      echo "${errs[*]}"
    ); output=$output stderr=$stderr"
  fi
fi

# ---------------------------------------------------------------------------
# Test: an open (not merged) PR keeps polling — proved via the progress log
# line, which surfaces the normalizer's state/merged fields directly.
# ---------------------------------------------------------------------------

label="pr wait progress log shows state=open merged=false for an open PR"
if ! skip_filter "$label"; then
  write_tea_mock "open" "false" '{
  "number": 7, "title": "WIP", "body": "", "state": "open",
  "merged": false, "merged_at": null, "mergeable": true,
  "user": {"login": "stonefish"}, "head": {"ref": "feature-widget"}, "base": {"ref": "master"},
  "labels": [], "assignees": [],
  "created_at": "2026-05-31T09:00:00Z", "updated_at": "2026-05-31T09:00:00Z",
  "html_url": "https://git.stonefish.tech/owner/repo/pulls/7"
}'

  exit_code=0
  PATH="$MOCK_DIR:$PATH" bash "$GIT_WAIT" pr wait --branch feature-widget \
    --timeout 1 --idle-timeout 1 --interval 1 >/dev/null 2>"$MOCK_DIR/stderr" || exit_code=$?
  stderr=$(cat "$MOCK_DIR/stderr")

  if [[ "$exit_code" == "2" ]] && echo "$stderr" | grep -q "state=open merged=false"; then
    pass "$label"
  else
    fail "$label" "exit=$exit_code stderr=$stderr"
  fi
fi

# ---------------------------------------------------------------------------
# Test: REST fetch failure degrades to unknown-state retries (never aborts
# the poll loop) — after 3 consecutive unknown reads, pr wait reports
# status: error rather than looping forever or crashing on the `die` inside
# the private normalizer.
# ---------------------------------------------------------------------------

label="pr wait: REST fetch failure degrades to unknown state → status: error after 3 attempts"
if ! skip_filter "$label"; then
  write_tea_mock "open" "false" "FAIL"

  exit_code=0
  output=$(PATH="$MOCK_DIR:$PATH" bash "$GIT_WAIT" pr wait --branch feature-widget \
    --timeout 5 --idle-timeout 5 --interval 1 2>"$MOCK_DIR/stderr") || exit_code=$?
  stderr=$(cat "$MOCK_DIR/stderr")

  if [[ "$exit_code" == "4" ]] && echo "$output" | grep -q "^status: error"; then
    pass "$label"
  else
    fail "$label" "exit=$exit_code output=$output stderr=$stderr"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Total: $((PASS + FAIL))  PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
[[ "$FAIL" -eq 0 ]] || exit 1
