# Shared helpers for the dotmgr bats suite.

# Absolute path to the repository root (parent of test/).
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export REPO_ROOT

# setup_env - build an isolated target/repo/backup layout and source the lib.
setup_env() {
  TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/dotmgr-test.XXXXXX")"
  export TMP
  export DOTMGR_TARGET="$TMP/home"
  export DOTMGR_REPO="$TMP/repo"
  export DOTMGR_BACKUP_DIR="$TMP/backups"
  export DOTMGR_MANIFEST="$DOTMGR_REPO/dotmgr.manifest"
  export DOTMGR_DRY_RUN=0
  mkdir -p "$DOTMGR_TARGET" "$DOTMGR_REPO"
  # shellcheck source=../lib/dotmgr.sh
  source "$REPO_ROOT/lib/dotmgr.sh"
}

teardown_env() {
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
}

# write_manifest LINE... - write each argument as a manifest line.
write_manifest() {
  printf '%s\n' "$@" > "$DOTMGR_MANIFEST"
}

# mkrepo_file REL [CONTENT] - create a tracked file in the repo.
mkrepo_file() {
  local rel="$1" content="${2:-content of $1}"
  mkdir -p "$(dirname "$DOTMGR_REPO/$rel")"
  printf '%s\n' "$content" > "$DOTMGR_REPO/$rel"
}

# mktarget_file REL [CONTENT] - create a real file in the target dir.
mktarget_file() {
  local rel="$1" content="${2:-existing $1}"
  mkdir -p "$(dirname "$DOTMGR_TARGET/$rel")"
  printf '%s\n' "$content" > "$DOTMGR_TARGET/$rel"
}
