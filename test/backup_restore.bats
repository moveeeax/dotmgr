#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "backup snapshots existing target files" {
  mkrepo_file ".bashrc"
  mktarget_file ".bashrc" "live-content"
  write_manifest ".bashrc -> .bashrc"
  run cmd_backup
  [ "$status" -eq 0 ]
  found="$(grep -rl "live-content" "$DOTMGR_BACKUP_DIR")"
  [ -n "$found" ]
}

@test "backup skips entries with no destination file" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  run cmd_backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to snapshot"* ]]
  [ ! -d "$DOTMGR_BACKUP_DIR" ]
}

@test "restore returns the latest snapshot to the target" {
  mkrepo_file ".bashrc"
  mktarget_file ".bashrc" "v1"
  write_manifest ".bashrc -> .bashrc"
  cmd_backup
  rm -f "$DOTMGR_TARGET/.bashrc"
  run cmd_restore
  [ "$status" -eq 0 ]
  [ "$(cat "$DOTMGR_TARGET/.bashrc")" = "v1" ]
}

@test "restore accepts a named snapshot under the backup root" {
  mkrepo_file ".bashrc"
  mktarget_file ".bashrc" "named"
  write_manifest ".bashrc -> .bashrc"
  cmd_backup
  snap="$(basename "$(dm_latest_snapshot)")"
  rm -f "$DOTMGR_TARGET/.bashrc"
  run cmd_restore "$snap"
  [ "$status" -eq 0 ]
  [ "$(cat "$DOTMGR_TARGET/.bashrc")" = "named" ]
}

@test "restore dies when there are no snapshots" {
  write_manifest ".bashrc -> .bashrc"
  run cmd_restore
  [ "$status" -ne 0 ]
  [[ "$output" == *"no backups"* ]]
}

# Regression: outside-target destinations were snapshotted under their bare
# basename, so two entries sharing a basename silently clobbered each other.
@test "backup keeps two absolute destinations with the same basename apart" {
  mkdir -p "$TMP/etc/a" "$TMP/etc/b"
  printf 'AAA\n' > "$TMP/etc/a/conf"
  printf 'BBB\n' > "$TMP/etc/b/conf"
  write_manifest "a -> $TMP/etc/a/conf" "b -> $TMP/etc/b/conf"
  run cmd_backup
  [ "$status" -eq 0 ]
  [ -n "$(grep -rl 'AAA' "$DOTMGR_BACKUP_DIR")" ]
  [ -n "$(grep -rl 'BBB' "$DOTMGR_BACKUP_DIR")" ]
}

# Regression: restore rebuilt every path under the target, so a file backed up
# from an absolute destination came back as $TARGET/<basename> and the real
# location stayed empty -- unrecoverable once link had moved the original.
@test "restore returns an absolute destination to its original location" {
  mkdir -p "$TMP/etc/a"
  printf 'ORIGINAL\n' > "$TMP/etc/a/conf"
  write_manifest "a -> $TMP/etc/a/conf"
  cmd_backup
  rm -f "$TMP/etc/a/conf"
  run cmd_restore
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/etc/a/conf")" = "ORIGINAL" ]
  [ ! -e "$DOTMGR_TARGET/conf" ]
}

@test "link then unlink --restore round-trips an absolute destination" {
  mkdir -p "$TMP/etc/a"
  mkrepo_file "a" "repo-version"
  printf 'user-version\n' > "$TMP/etc/a/conf"
  write_manifest "a -> $TMP/etc/a/conf"
  cmd_link
  [ -L "$TMP/etc/a/conf" ]
  run cmd_unlink --restore
  [ "$status" -eq 0 ]
  [ ! -L "$TMP/etc/a/conf" ]
  [ "$(cat "$TMP/etc/a/conf")" = "user-version" ]
}

@test "dry-run backup writes nothing" {
  mkrepo_file ".bashrc"
  mktarget_file ".bashrc" "content"
  write_manifest ".bashrc -> .bashrc"
  DOTMGR_DRY_RUN=1 run cmd_backup
  [ "$status" -eq 0 ]
  [ ! -d "$DOTMGR_BACKUP_DIR" ]
}
