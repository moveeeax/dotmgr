#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "dm_main --help prints usage and exits zero" {
  run dm_main --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: dotmgr"* ]]
}

@test "dm_main --version prints the VERSION file" {
  run dm_main --version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$REPO_ROOT/VERSION")" ]
}

@test "dm_main with no command fails" {
  run dm_main
  [ "$status" -ne 0 ]
  [[ "$output" == *"no command given"* ]]
}

@test "dm_main rejects an unknown command" {
  run dm_main frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "dm_main rejects an unknown global option" {
  run dm_main --bogus link
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "dm_main dispatches status through global options" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  run dm_main --repo "$DOTMGR_REPO" --target "$DOTMGR_TARGET" \
    --manifest "$DOTMGR_MANIFEST" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing"* ]]
}

@test "dm_main link then status shows linked end to end" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  dm_main --backup-dir "$DOTMGR_BACKUP_DIR" link
  run dm_main status
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked"* ]]
}
