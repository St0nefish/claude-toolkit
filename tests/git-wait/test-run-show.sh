#!/usr/bin/env bash
# test-run-show.sh — Test harness for git-wait's Gitea run-detail normalizer
# (the private `_run_show` function), exercised through the public
# `run watch` surface.
#
# Regression test for #133: `tea actions runs view --output json` emits a
# human key/value table (not JSON) in tea 0.14.1, so the old code fed
# non-JSON to jq and died with "parse error: Invalid numeric literal". The fix
# fetches the run via `tea api repos/{owner}/{repo}/actions/runs/<id>`
# instead. `_run_show` is no longer a public subcommand (`run show <id>` was
# removed along with the rest of the CLI-wrapper surface) but its normalizer
# is still load-bearing: `run watch`'s Gitea path calls it (via
# `_run_failed_jobs`) to aggregate per-job status before declaring a run
# passed (see #87), so these tests drive it from there.
#
# `run watch` always takes the non-PR (run-list) path on Gitea — `use_pr` is
# only set for PLATFORM==github — so the fallback polling loop below is what
# reaches `_run_show` on every run.
#
# Uses mock git/tea scripts via PATH injection.
#
# Usage: bash tests/git-wait/test-run-show.sh [filter]

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

SENTINEL="$MOCK_DIR/.runs_view_called"

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

# Mock tea:
#  - login list        → gitea platform detection
#  - actions runs view  → MUST NOT be called by the fixed code (#133); emits
#                         the human key/value table tea 0.14.1 actually
#                         returns, and records a sentinel if invoked
#  - api .../runs?...            → run list (branch-correlated)
#  - api .../runs/<id>           → run detail (REST shape, numeric id)
#  - api .../runs/<id>/jobs      → per-job detail
cat >"$MOCK_DIR/tea" <<EOF
#!/usr/bin/env bash
case "\$1 \$2 \$3" in
  "login list --output")
    echo '[{"url":"https://git.stonefish.tech"}]'
    exit 0
    ;;
  "actions runs view")
    touch "$SENTINEL"
    echo "Run ID: 1075"
    echo "Status: in_progress"
    exit 0
    ;;
esac
case "\$1" in
  api)
    case "\$2" in
      repos/\\{owner\\}/\\{repo\\}/actions/runs/*/jobs)
        echo '{"jobs":[
          {"id":1,"name":"build","status":"completed","conclusion":"success"},
          {"id":2,"name":"test","status":"completed","conclusion":"failure"}
        ]}'
        ;;
      repos/\\{owner\\}/\\{repo\\}/actions/runs/*)
        cat <<'JSON'
{
  "id": 1075,
  "status": "completed",
  "conclusion": "success",
  "name": "CI",
  "head_branch": "feature-x",
  "head_sha": "sha1075",
  "event": "push",
  "run_started_at": "2026-05-30T12:00:00Z",
  "url": "https://git.stonefish.tech/owner/repo/actions/runs/1075"
}
JSON
        ;;
      repos/\\{owner\\}/\\{repo\\}/actions/runs*)
        cat <<'JSON'
{"workflow_runs":[
  {
    "id": 1075, "status": "completed", "conclusion": "success",
    "name": "CI", "head_branch": "feature-x", "head_sha": "sha1075",
    "event": "push", "run_started_at": "2026-05-30T12:00:00Z",
    "url": "https://git.stonefish.tech/owner/repo/actions/runs/1075"
  }
]}
JSON
        ;;
      *) echo "unexpected tea api call: \$2" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected tea call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$MOCK_DIR/tea"

# ---------------------------------------------------------------------------
# Test: run-level status reads "success", but a job failed — `run watch`
# must aggregate per-job status (via `_run_show`'s normalized `.jobs[]`) and
# report the run as failed, naming the failed job.
# ---------------------------------------------------------------------------

echo "── run show normalizer (via run watch): Gitea REST path (#133) ──"

label="run watch aggregates per-job status from REST detail → status: fail, failed_jobs: test"
if ! skip_filter "$label"; then
  exit_code=0
  output=$(PATH="$MOCK_DIR:$PATH" bash "$GIT_WAIT" run watch --branch feature-x \
    --initial-delay 0 --timeout 5 --interval 1 2>"$MOCK_DIR/stderr") || exit_code=$?
  stderr=$(cat "$MOCK_DIR/stderr")

  errs=()
  [[ "$exit_code" == "0" ]] || errs+=("exit=$exit_code")
  echo "$output" | grep -q "^status: fail" || errs+=("no 'status: fail'")
  echo "$output" | grep -q "^failed_jobs: test" || errs+=("failed_jobs missing 'test'")
  echo "$output" | grep -q "^url: https://git.stonefish.tech/owner/repo/actions/runs/1075" || errs+=("wrong url")

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
# Test: regression guard — `tea actions runs view` (the human-table endpoint
# from #133) is never invoked.
# ---------------------------------------------------------------------------

label="run watch does not call 'tea actions runs view'"
if ! skip_filter "$label"; then
  if [[ -f "$SENTINEL" ]]; then
    fail "$label" "sentinel present — old non-JSON code path was used"
  else
    pass "$label"
  fi
fi

# ---------------------------------------------------------------------------
# Test: run-detail REST fetch failure degrades gracefully — `_run_failed_jobs`
# swallows a `_run_show` failure and returns no failed jobs rather than
# aborting the watch loop, so a probe failure never crashes `run watch`; the
# top-level run status still drives the outcome.
# ---------------------------------------------------------------------------

label="run watch: run-detail REST fetch failure degrades to no failed_jobs (does not abort)"
if ! skip_filter "$label"; then
  cat >"$MOCK_DIR/tea" <<'EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "login list --output") echo '[{"url":"https://git.stonefish.tech"}]'; exit 0 ;;
esac
case "$1" in
  api)
    case "$2" in
      repos/\{owner\}/\{repo\}/actions/runs/*/jobs) exit 1 ;;
      repos/\{owner\}/\{repo\}/actions/runs/*) echo "404 Not Found" >&2; exit 1 ;;
      repos/\{owner\}/\{repo\}/actions/runs*)
        echo '{"workflow_runs":[{"id":1076,"status":"completed","conclusion":"success","name":"CI","head_branch":"feature-x","head_sha":"sha1076","event":"push","run_started_at":"2026-05-30T12:00:00Z","url":"https://git.stonefish.tech/owner/repo/actions/runs/1076"}]}'
        ;;
      *) echo "unexpected tea api call: $2" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected tea call: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$MOCK_DIR/tea"

  exit_code=0
  output=$(PATH="$MOCK_DIR:$PATH" bash "$GIT_WAIT" run watch --branch feature-x \
    --initial-delay 0 --timeout 5 --interval 1 2>"$MOCK_DIR/stderr") || exit_code=$?
  stderr=$(cat "$MOCK_DIR/stderr")

  if [[ "$exit_code" == "0" ]] && echo "$output" | grep -q "^status: pass"; then
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
