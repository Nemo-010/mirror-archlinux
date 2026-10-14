# Shared harness for the test suites. Sourced, never executed.
#
# Output is TAP. Each test file is one plan. A failing assertion prints the
# measurement and the command that reproduces it, so a CI log is enough to act
# on without re-deriving anything.

if [ -z "${REPO_ROOT:-}" ]; then
  echo "harness: REPO_ROOT is not set" >&2
  exit 2
fi

TESTS_RUN=0
TESTS_FAILED=0

ok() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

not_ok() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'not ok %d - %s\n' "$TESTS_RUN" "$1"
}

diag() {
  printf '#   %s\n' "$1"
}

# fail DESC [DIAG ...]
fail() {
  local desc="$1"
  shift
  not_ok "$desc"
  while [ "$#" -gt 0 ]; do
    diag "$1"
    shift
  done
}

# check DESC EXPECTED GOT REPRODUCE
check() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    fail "$1" "expected: $2" "got:      $3" "reproduce: $4"
  fi
}

summary() {
  printf '1..%d\n' "$TESTS_RUN"
  if [ "$TESTS_RUN" -eq 0 ]; then
    printf '# no assertions ran, which is itself a failure\n'
    return 1
  fi
  if [ "$TESTS_FAILED" -gt 0 ]; then
    printf '# failed %d of %d\n' "$TESTS_FAILED" "$TESTS_RUN"
    return 1
  fi
  printf '# passed %d of %d\n' "$TESTS_RUN" "$TESTS_RUN"
  return 0
}

# work_dir -> a scratch directory; the caller removes it in its EXIT trap
work_dir() {
  mktemp -d
}

#---------------------------------------------------------------------------#
# grep_matches PATTERN FILE
#
# Prints matching lines with line numbers. No match is a normal result and
# exits 0 with no output. A real grep failure exits 2 and is not swallowed,
# which is the difference between "nothing matched" and "the check did not run".
#---------------------------------------------------------------------------#
grep_matches() {
  local out rc=0
  out="$(grep -nE "$1" "$2")" || rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$out"
      return 0
      ;;
    1) return 0 ;;
    *)
      echo "harness: grep exited $rc on $2 for pattern: $1" >&2
      return 2
      ;;
  esac
}

#---------------------------------------------------------------------------#
# Container runtime, for the integration suite.
#---------------------------------------------------------------------------#
# shellcheck disable=SC2034 # read by the integration suite
RUNTIME=""

runtime_detect() {
  if [ -n "${CONTAINER_RUNTIME:-}" ]; then
    RUNTIME="$CONTAINER_RUNTIME"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
  elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
  else
    echo "harness: no container runtime found, set CONTAINER_RUNTIME" >&2
    return 1
  fi
  export RUNTIME
}

# Every script the repository ships, by path relative to REPO_ROOT. The
# scripts carry no extension, so a find by suffix would miss them.
shipped_scripts() {
  printf '%s\n' client/pacman-oci
  find "$REPO_ROOT/scripts" -type f | sed "s|^$REPO_ROOT/||" | sort
}
