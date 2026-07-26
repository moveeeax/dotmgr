#!/usr/bin/env bash
#
# dotmgr.sh - core library for the dotmgr dotfiles manager.
#
# This file is sourced by bin/dotmgr and by the bats test suite. It only
# defines functions and does not enable errexit itself, leaving shell option
# control to the caller (bin/dotmgr sets `set -euo pipefail`).
#
# The functions operate on four globals, which bin/dotmgr fills with defaults
# and the test suite sets explicitly:
#
#   DOTMGR_REPO       directory holding the tracked dotfiles
#   DOTMGR_TARGET     directory the files are linked into (usually $HOME)
#   DOTMGR_MANIFEST   manifest file mapping repo sources to targets
#   DOTMGR_BACKUP_DIR root under which timestamped backups are written
#   DOTMGR_DRY_RUN    when 1, mutating actions are logged but not performed

# Colour output only when stderr is a terminal.
if [ -t 2 ]; then
  _DM_C_RED=$'\033[31m'
  _DM_C_YELLOW=$'\033[33m'
  _DM_C_RESET=$'\033[0m'
else
  _DM_C_RED=""
  _DM_C_YELLOW=""
  _DM_C_RESET=""
fi

_dm_ts() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

# info MESSAGE... - log an informational line to stderr.
info() {
  printf '%s [INFO] %s\n' "$(_dm_ts)" "$*" >&2
}

# warn MESSAGE... - log a warning to stderr.
warn() {
  printf '%s [WARN] %s%s%s\n' "$(_dm_ts)" "$_DM_C_YELLOW" "$*" "$_DM_C_RESET" >&2
}

# die MESSAGE... - log an error to stderr and exit non-zero.
die() {
  printf '%s [ERROR] %s%s%s\n' "$(_dm_ts)" "$_DM_C_RED" "$*" "$_DM_C_RESET" >&2
  exit 1
}

# dm_dry_run - true when the caller asked for a dry run.
dm_dry_run() {
  [ "${DOTMGR_DRY_RUN:-0}" = "1" ]
}

# dm_do COMMAND... - run a mutating command, or log it under --dry-run.
dm_do() {
  if dm_dry_run; then
    info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# dm_require_repo - abort unless the configured repository directory exists.
dm_require_repo() {
  [ -d "$DOTMGR_REPO" ] || die "repo directory not found: $DOTMGR_REPO"
}

# dm_timestamp - a sortable stamp used to name backup snapshots.
dm_timestamp() {
  date +"%Y%m%d-%H%M%S"
}

# dm_abs_src SRC - absolute path of a manifest source inside the repo.
dm_abs_src() {
  printf '%s\n' "${DOTMGR_REPO%/}/$1"
}

# dm_expand_dest DEST - resolve a manifest destination to an absolute path.
#
# A leading "/" is kept verbatim, a leading "~" expands against the target
# directory, and anything else is treated as relative to the target.
dm_expand_dest() {
  local dest="$1" tilde='~'
  case "$dest" in
    /*) printf '%s\n' "$dest" ;;
    "$tilde") printf '%s\n' "${DOTMGR_TARGET%/}" ;;
    "$tilde"/*) printf '%s\n' "${DOTMGR_TARGET%/}/${dest:2}" ;;
    *) printf '%s\n' "${DOTMGR_TARGET%/}/$dest" ;;
  esac
}

# Snapshot subdirectory holding destinations that live outside the target
# directory. Kept deliberately unlikely to collide with a real dotfile name.
_DM_ABS_PREFIX="_dotmgr_abs"

# dm_rel_to_target PATH - the snapshot-relative location used to store PATH.
#
# Paths under the target directory keep their relative layout. An absolute
# path outside the target is stored under "$_DM_ABS_PREFIX/" with its full
# path preserved, so that two entries sharing a basename cannot overwrite each
# other in a snapshot and so that dm_restore_from can put the file back where
# it actually came from.
dm_rel_to_target() {
  local path="$1" base="${DOTMGR_TARGET%/}"
  case "$path" in
    "$base"/*) printf '%s\n' "${path#"$base"/}" ;;
    /*) printf '%s\n' "$_DM_ABS_PREFIX/${path#/}" ;;
    *) basename "$path" ;;
  esac
}

# dm_reject_traversal LABEL PATH - abort when PATH has a ".." component.
#
# Without this a manifest entry such as "x -> ../../.ssh/authorized_keys"
# resolves outside the target directory. Absolute destinations are still
# supported and are the intended way to manage files elsewhere.
dm_reject_traversal() {
  case "/$2/" in
    */../*) die "$1 must not contain a '..' path component: $2" ;;
  esac
}

# dm_trim STRING - strip leading and trailing whitespace.
dm_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# dm_parse_manifest FILE - emit normalised "SRC<TAB>DEST" rows.
#
# Manifest lines are one of:
#   src -> dest    explicit mapping
#   path           shorthand for "path -> path"
# Blank lines and lines whose first non-space character is '#' are ignored.
dm_parse_manifest() {
  local file="$1" line src dest
  [ -f "$file" ] || die "manifest not found: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(dm_trim "$line")"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac
    if [[ "$line" == *"->"* ]]; then
      src="$(dm_trim "${line%%->*}")"
      dest="$(dm_trim "${line#*->}")"
    else
      src="$line"
      dest="$line"
    fi
    [ -n "$src" ] || die "manifest line has empty source: $line"
    [ -n "$dest" ] || die "manifest line has empty destination: $line"
    dm_reject_traversal "manifest source" "$src"
    dm_reject_traversal "manifest destination" "$dest"
    printf '%s\t%s\n' "$src" "$dest"
  done < "$file"
}

# dm_load_manifest - parse DOTMGR_MANIFEST into the DM_MANIFEST_ROWS global.
#
# dm_parse_manifest reports fatal problems with die(), and die() runs `exit`
# in whichever shell it happens to be in. Read as `< <(dm_parse_manifest ...)`
# that shell is only the process-substitution subshell, so every command
# silently carried on with an empty entry list and still returned success --
# `dotmgr link` against a mistyped manifest path exited 0 having done nothing.
# A checked command substitution puts that failure back in the caller's hands.
dm_load_manifest() {
  DM_MANIFEST_ROWS="$(dm_parse_manifest "$DOTMGR_MANIFEST")" || return 1
}

# dm_is_linked DEST SRC - true when DEST is a symlink already pointing at SRC.
dm_is_linked() {
  local dest="$1" src="$2"
  [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]
}

# dm_backup_into DEST RUNDIR - move an existing DEST into the backup run dir,
# preserving its path relative to the target directory.
dm_backup_into() {
  local dest="$1" rundir="$2" rel bpath
  rel="$(dm_rel_to_target "$dest")"
  bpath="$rundir/$rel"
  dm_do mkdir -p "$(dirname "$bpath")"
  dm_do mv "$dest" "$bpath"
  info "backed up: $dest -> $bpath"
}

# cmd_link - link every manifest entry into the target directory.
#
# Existing real files or foreign symlinks are moved into a single timestamped
# backup run before the managed symlink is created. Entries that are already
# correctly linked are left untouched, which makes re-running a no-op.
cmd_link() {
  dm_require_repo
  local run_dir made_backup=0 src dest src_abs dest_abs
  run_dir="${DOTMGR_BACKUP_DIR%/}/$(dm_timestamp)"
  dm_load_manifest || return 1
  while IFS=$'\t' read -r src dest; do
    [ -n "$src" ] || continue
    src_abs="$(dm_abs_src "$src")"
    dest_abs="$(dm_expand_dest "$dest")"
    # Linking a path to itself moves the only real copy into a backup and
    # leaves a self-referential symlink behind, which later runs then report
    # as "linked". Refuse instead of destroying the file.
    if [ "$src_abs" = "$dest_abs" ]; then
      die "manifest entry maps a path onto itself, refusing to link: $src -> $dest (both resolve to $src_abs)"
    fi
    if [ ! -e "$src_abs" ] && [ ! -L "$src_abs" ]; then
      warn "source missing in repo, skipping: $src"
      continue
    fi
    if dm_is_linked "$dest_abs" "$src_abs"; then
      info "ok: $dest already linked"
      continue
    fi
    if [ -e "$dest_abs" ] || [ -L "$dest_abs" ]; then
      if [ "$made_backup" -eq 0 ]; then
        dm_do mkdir -p "$run_dir"
        made_backup=1
      fi
      dm_backup_into "$dest_abs" "$run_dir"
    fi
    dm_do mkdir -p "$(dirname "$dest_abs")"
    dm_do ln -s "$src_abs" "$dest_abs"
    info "linked: $dest -> $src"
  done <<< "$DM_MANIFEST_ROWS"
}

# dm_version - print the toolkit version from the VERSION file.
dm_version() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -f "$dir/VERSION" ]; then
    cat "$dir/VERSION"
  else
    printf 'unknown\n'
  fi
}

# dm_usage - print command-line help.
dm_usage() {
  cat <<'USAGE'
Usage: dotmgr [GLOBAL OPTIONS] COMMAND [ARGS]

Manage dotfiles by symlinking sources from a repository into a target
directory (your $HOME by default), driven by a manifest.

Commands:
  link                 Create managed symlinks, backing up any conflicts
  unlink [--restore]   Remove managed symlinks, optionally restoring a backup
  status               Show link / missing / conflict state for each entry
  backup               Snapshot the current target files
  restore [SNAPSHOT]   Restore a snapshot (latest when none is given)
  adopt PATH           Move an existing file into the repo and symlink it back

Global options:
  --repo DIR           Dotfiles repository (default: $DOTMGR_REPO or cwd)
  --target DIR         Where to link files (default: $HOME)
  --manifest FILE      Manifest path (default: <repo>/dotmgr.manifest)
  --backup-dir DIR     Backup root (default: XDG data dir)
  -n, --dry-run        Show actions without changing anything
  -h, --help           Show this help and exit
      --version        Print the version and exit
USAGE
}

# dm_main ARGS - parse global options and dispatch to a command.
dm_main() {
  : "${DOTMGR_REPO:=$PWD}"
  : "${DOTMGR_TARGET:=$HOME}"
  : "${DOTMGR_BACKUP_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/dotmgr/backups}"
  : "${DOTMGR_DRY_RUN:=0}"

  local cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) DOTMGR_REPO="$2"; shift 2 ;;
      --repo=*) DOTMGR_REPO="${1#*=}"; shift ;;
      --target) DOTMGR_TARGET="$2"; shift 2 ;;
      --target=*) DOTMGR_TARGET="${1#*=}"; shift ;;
      --manifest) DOTMGR_MANIFEST="$2"; shift 2 ;;
      --manifest=*) DOTMGR_MANIFEST="${1#*=}"; shift ;;
      --backup-dir) DOTMGR_BACKUP_DIR="$2"; shift 2 ;;
      --backup-dir=*) DOTMGR_BACKUP_DIR="${1#*=}"; shift ;;
      -n|--dry-run) DOTMGR_DRY_RUN=1; shift ;;
      -h|--help) dm_usage; return 0 ;;
      --version) dm_version; return 0 ;;
      --) shift; break ;;
      -*) dm_usage >&2; die "unknown option: $1" ;;
      *) cmd="$1"; shift; break ;;
    esac
  done

  [ -n "$cmd" ] || { dm_usage >&2; die "no command given"; }

  # These directories are the base of every path this tool creates, moves and
  # removes. An empty value (an unset or blank $HOME, an option given an empty
  # argument) would silently retarget all of that at the filesystem root, so
  # refuse rather than trust the environment.
  [ -n "$DOTMGR_REPO" ] || die "repo directory must not be empty"
  [ -n "$DOTMGR_TARGET" ] || die "target directory must not be empty"
  [ -n "$DOTMGR_BACKUP_DIR" ] || die "backup directory must not be empty"
  [ -n "${DOTMGR_TARGET%/}" ] || die "target directory must not be the filesystem root"

  # Anchor a relative --repo/--target/--backup-dir to the invocation cwd.
  #
  # DOTMGR_REPO in particular becomes literal symlink target text in
  # dm_abs_src: `ln -s "$src_abs" "$dest_abs"`. Left relative, the symlink is
  # resolved by the kernel against the *symlink's own directory*, not the cwd
  # dotmgr was run from. `dotmgr --repo dotfiles link` run from anywhere other
  # than the target directory silently produced dangling links pointing at
  # "dotfiles/..." under $HOME instead of the intended checkout. Target and
  # backup-dir are normalised too so every path this tool prints or records
  # stays meaningful after the process's cwd is no longer available.
  case "$DOTMGR_REPO" in
    /*) ;;
    *) DOTMGR_REPO="$PWD/$DOTMGR_REPO" ;;
  esac
  case "$DOTMGR_TARGET" in
    /*) ;;
    *) DOTMGR_TARGET="$PWD/$DOTMGR_TARGET" ;;
  esac
  case "$DOTMGR_BACKUP_DIR" in
    /*) ;;
    *) DOTMGR_BACKUP_DIR="$PWD/$DOTMGR_BACKUP_DIR" ;;
  esac

  : "${DOTMGR_MANIFEST:=${DOTMGR_REPO%/}/dotmgr.manifest}"
  [ -n "$DOTMGR_MANIFEST" ] || die "manifest path must not be empty"

  case "$cmd" in
    link) cmd_link "$@" ;;
    unlink) cmd_unlink "$@" ;;
    status) cmd_status "$@" ;;
    backup) cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    adopt) cmd_adopt "$@" ;;
    help) dm_usage ;;
    *) dm_usage >&2; die "unknown command: $cmd" ;;
  esac
}

# dm_classify SRC_ABS DEST_ABS - echo the state of a single managed entry:
# "linked", "missing" or "conflict".
dm_classify() {
  local src_abs="$1" dest_abs="$2"
  if dm_is_linked "$dest_abs" "$src_abs"; then
    printf 'linked\n'
  elif [ -e "$dest_abs" ] || [ -L "$dest_abs" ]; then
    printf 'conflict\n'
  else
    printf 'missing\n'
  fi
}

# cmd_status - print the state of every manifest entry to stdout.
cmd_status() {
  local src dest src_abs dest_abs state
  dm_load_manifest || return 1
  while IFS=$'\t' read -r src dest; do
    [ -n "$src" ] || continue
    src_abs="$(dm_abs_src "$src")"
    dest_abs="$(dm_expand_dest "$dest")"
    state="$(dm_classify "$src_abs" "$dest_abs")"
    printf '%-9s %s -> %s\n' "$state" "$dest" "$src"
  done <<< "$DM_MANIFEST_ROWS"
}

# dm_latest_snapshot - print the newest snapshot directory under the backup
# root, or return non-zero when there are none. Snapshot names are timestamps,
# so lexical order matches chronological order.
dm_latest_snapshot() {
  [ -d "$DOTMGR_BACKUP_DIR" ] || return 1
  local d newest=""
  for d in "$DOTMGR_BACKUP_DIR"/*/; do
    [ -d "$d" ] || continue
    newest="$d"
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "${newest%/}"
}

# dm_restore_from SNAPDIR - move every file and symlink from a snapshot back
# to its original location under the target directory.
dm_restore_from() {
  local snap="${1%/}" f rel dest
  [ -d "$snap" ] || die "snapshot not found: $snap"
  while IFS= read -r -d '' f; do
    rel="${f#"$snap"/}"
    case "$rel" in
      "$_DM_ABS_PREFIX"/*) dest="/${rel#"$_DM_ABS_PREFIX"/}" ;;
      *) dest="${DOTMGR_TARGET%/}/$rel" ;;
    esac
    # Last line of defence: an empty or root destination here would hand the
    # filesystem root to rm -rf.
    case "$dest" in
      "" | "/") die "refusing to restore to unsafe path: '$dest'" ;;
    esac
    dm_do mkdir -p "$(dirname "$dest")"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      dm_do rm -rf "$dest"
    fi
    dm_do mv "$f" "$dest"
    info "restored: $dest"
  done < <(find "$snap" -mindepth 1 \( -type f -o -type l \) -print0)
}

# cmd_unlink [--restore] - remove managed symlinks. With --restore, the latest
# backup snapshot is restored afterwards.
cmd_unlink() {
  local do_restore=0 src dest src_abs dest_abs
  while [ $# -gt 0 ]; do
    case "$1" in
      --restore) do_restore=1; shift ;;
      -*) die "unknown unlink option: $1" ;;
      *) die "unlink takes no positional arguments" ;;
    esac
  done
  dm_load_manifest || return 1
  while IFS=$'\t' read -r src dest; do
    [ -n "$src" ] || continue
    src_abs="$(dm_abs_src "$src")"
    dest_abs="$(dm_expand_dest "$dest")"
    if dm_is_linked "$dest_abs" "$src_abs"; then
      dm_do rm "$dest_abs"
      info "unlinked: $dest"
    else
      info "not managed, leaving in place: $dest"
    fi
  done <<< "$DM_MANIFEST_ROWS"
  if [ "$do_restore" -eq 1 ]; then
    local snap
    snap="$(dm_latest_snapshot)" || die "no backups to restore"
    dm_restore_from "$snap"
  fi
}

# cmd_backup - copy the current target files for every manifest entry into a
# fresh timestamped snapshot. Symlinks are preserved as symlinks.
cmd_backup() {
  local snap made=0 src dest dest_abs rel bpath
  snap="${DOTMGR_BACKUP_DIR%/}/$(dm_timestamp)"
  dm_load_manifest || return 1
  while IFS=$'\t' read -r src dest; do
    [ -n "$src" ] || continue
    dest_abs="$(dm_expand_dest "$dest")"
    if [ ! -e "$dest_abs" ] && [ ! -L "$dest_abs" ]; then
      continue
    fi
    if [ "$made" -eq 0 ]; then
      dm_do mkdir -p "$snap"
      made=1
    fi
    rel="$(dm_rel_to_target "$dest_abs")"
    bpath="$snap/$rel"
    dm_do mkdir -p "$(dirname "$bpath")"
    dm_do cp -a "$dest_abs" "$bpath"
    info "snapshot: $rel"
  done <<< "$DM_MANIFEST_ROWS"
  if [ "$made" -eq 0 ]; then
    warn "nothing to snapshot"
  else
    info "snapshot written to $snap"
  fi
}

# cmd_restore [SNAPSHOT] - restore a snapshot. With no argument the latest is
# used; a bare name is resolved under the backup root, and an absolute or
# existing path is used as given.
cmd_restore() {
  local arg="${1:-}" snap
  if [ -z "$arg" ]; then
    snap="$(dm_latest_snapshot)" || die "no backups to restore"
  elif [ -d "$arg" ]; then
    snap="$arg"
  else
    snap="${DOTMGR_BACKUP_DIR%/}/$arg"
  fi
  dm_restore_from "$snap"
}

# dm_append_manifest SRC DEST - append a mapping line to the manifest.
dm_append_manifest() {
  printf '%s -> %s\n' "$1" "$2" >> "$DOTMGR_MANIFEST"
}

# dm_manifest_has SRC - true when the manifest already lists SRC as a source.
dm_manifest_has() {
  local want="$1" src dest
  [ -f "$DOTMGR_MANIFEST" ] || return 1
  dm_load_manifest || return 1
  while IFS=$'\t' read -r src dest; do
    [ "$src" = "$want" ] && return 0
  done <<< "$DM_MANIFEST_ROWS"
  return 1
}

# cmd_adopt PATH - move an existing real file at PATH into the repo at the
# matching relative location, replace it with a symlink, and record it in the
# manifest if it is not already listed.
cmd_adopt() {
  [ $# -eq 1 ] || die "adopt requires exactly one PATH"
  dm_require_repo
  local dest_abs rel src_abs base="${DOTMGR_TARGET%/}"
  dm_reject_traversal "adopt path" "$1"
  dest_abs="$(dm_expand_dest "$1")"
  # Outside the target directory the repo-relative location collapses to a
  # basename, so the manifest entry it writes points somewhere else entirely:
  # link/status/unlink would all act on $TARGET/<basename> while the real
  # symlink sat at the original path, permanently orphaned.
  case "$dest_abs" in
    "$base"/*) ;;
    *) die "adopt only handles paths under the target directory ($base): $dest_abs" ;;
  esac
  if [ -L "$dest_abs" ]; then
    die "already a symlink, nothing to adopt: $dest_abs"
  fi
  if [ ! -e "$dest_abs" ]; then
    die "no such file to adopt: $dest_abs"
  fi
  rel="$(dm_rel_to_target "$dest_abs")"
  src_abs="$(dm_abs_src "$rel")"
  if [ -e "$src_abs" ] || [ -L "$src_abs" ]; then
    die "repo already has a file at: $src_abs"
  fi
  dm_do mkdir -p "$(dirname "$src_abs")"
  dm_do mv "$dest_abs" "$src_abs"
  dm_do ln -s "$src_abs" "$dest_abs"
  info "adopted: $rel"
  if dm_manifest_has "$rel"; then
    info "manifest already lists: $rel"
  else
    dm_do dm_append_manifest "$rel" "$rel"
    info "added to manifest: $rel -> $rel"
  fi
}
