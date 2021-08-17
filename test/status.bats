#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "status reports missing when the destination does not exist" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == "missing"* ]]
}

@test "status reports linked after a link" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  cmd_link
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == "linked"* ]]
}

@test "status reports conflict for a real file at the destination" {
  mkrepo_file ".bashrc"
  mktarget_file ".bashrc" "user-owned"
  write_manifest ".bashrc -> .bashrc"
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == "conflict"* ]]
}

@test "status reports conflict for a foreign symlink" {
  mkrepo_file ".bashrc"
  ln -s /elsewhere "$DOTMGR_TARGET/.bashrc"
  write_manifest ".bashrc -> .bashrc"
  run cmd_status
  [[ "$output" == "conflict"* ]]
}

@test "status classifies a mix of entries independently" {
  mkrepo_file ".bashrc"
  mkrepo_file ".gitconfig"
  mkrepo_file ".vimrc"
  mktarget_file ".vimrc" "real"
  ln -s "$DOTMGR_REPO/.bashrc" "$DOTMGR_TARGET/.bashrc"
  write_manifest ".bashrc -> .bashrc" ".gitconfig -> .gitconfig" ".vimrc -> .vimrc"
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "linked"* ]]
  [[ "${lines[1]}" == "missing"* ]]
  [[ "${lines[2]}" == "conflict"* ]]
}
