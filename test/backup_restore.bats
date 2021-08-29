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

@test "dry-run backup writes nothing" {
  mkrepo_file ".bashrc"
  mktarget_file ".bashrc" "content"
  write_manifest ".bashrc -> .bashrc"
  DOTMGR_DRY_RUN=1 run cmd_backup
  [ "$status" -eq 0 ]
  [ ! -d "$DOTMGR_BACKUP_DIR" ]
}
