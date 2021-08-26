#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "unlink removes a managed symlink" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  cmd_link
  [ -L "$DOTMGR_TARGET/.bashrc" ]
  run cmd_unlink
  [ "$status" -eq 0 ]
  [ ! -e "$DOTMGR_TARGET/.bashrc" ]
}

@test "unlink leaves a foreign symlink untouched" {
  mkrepo_file ".bashrc"
  ln -s /elsewhere "$DOTMGR_TARGET/.bashrc"
  write_manifest ".bashrc -> .bashrc"
  run cmd_unlink
  [ "$status" -eq 0 ]
  [ -L "$DOTMGR_TARGET/.bashrc" ]
  [ "$(readlink "$DOTMGR_TARGET/.bashrc")" = "/elsewhere" ]
}

@test "unlink --restore brings back the file backed up during link" {
  mkrepo_file ".bashrc" "repo-version"
  mktarget_file ".bashrc" "user-version"
  write_manifest ".bashrc -> .bashrc"
  cmd_link
  [ -L "$DOTMGR_TARGET/.bashrc" ]
  run cmd_unlink --restore
  [ "$status" -eq 0 ]
  [ ! -L "$DOTMGR_TARGET/.bashrc" ]
  [ "$(cat "$DOTMGR_TARGET/.bashrc")" = "user-version" ]
}

@test "unlink --restore dies when there is no backup" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  cmd_link
  run cmd_unlink --restore
  [ "$status" -ne 0 ]
  [[ "$output" == *"no backups"* ]]
}

@test "unlink rejects an unknown option" {
  write_manifest ".bashrc -> .bashrc"
  run cmd_unlink --bogus
  [ "$status" -ne 0 ]
}

@test "dry-run unlink leaves the symlink in place" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  cmd_link
  DOTMGR_DRY_RUN=1 run cmd_unlink
  [ "$status" -eq 0 ]
  [ -L "$DOTMGR_TARGET/.bashrc" ]
}
