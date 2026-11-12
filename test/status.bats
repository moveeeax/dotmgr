#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "status reports missing when the destination does not exist" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  run cmd_status
  [ "$status" -eq 1 ]
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
  [ "$status" -eq 1 ]
  [[ "$output" == "conflict"* ]]
}

@test "status reports conflict for a foreign symlink" {
  mkrepo_file ".bashrc"
  ln -s /elsewhere "$DOTMGR_TARGET/.bashrc"
  write_manifest ".bashrc -> .bashrc"
  run cmd_status
  [ "$status" -eq 1 ]
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
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "linked"* ]]
  [[ "${lines[1]}" == "missing"* ]]
  [[ "${lines[2]}" == "conflict"* ]]
}

@test "status exits 0 when every entry is linked" {
  mkrepo_file ".bashrc"
  mkrepo_file ".gitconfig"
  write_manifest ".bashrc -> .bashrc" ".gitconfig -> .gitconfig"
  cmd_link
  run cmd_status
  [ "$status" -eq 0 ]
}

@test "status exits 0 for a manifest with no entries" {
  write_manifest "# nothing tracked yet"
  run cmd_status
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "status reports nosource when the repo file is gone" {
  write_manifest ".bashrc -> .bashrc"
  run cmd_status
  [ "$status" -eq 1 ]
  [[ "$output" == "nosource"* ]]
}

@test "status reports nosource for a managed link whose repo file was deleted" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc -> .bashrc"
  cmd_link
  rm "$DOTMGR_REPO/.bashrc"
  run cmd_status
  [ "$status" -eq 1 ]
  [[ "$output" == "nosource"* ]]
}

@test "status exits 2 when the manifest is missing" {
  export DOTMGR_MANIFEST="$TMP/absent.manifest"
  run cmd_status
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest not found"* ]]
}

@test "status exits 2 when the manifest cannot be parsed" {
  write_manifest "x -> ../escape"
  run cmd_status
  [ "$status" -eq 2 ]
}

@test "status exits 2 on an unknown option or a positional argument" {
  write_manifest ".bashrc"
  run cmd_status --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown status option"* ]]
  run cmd_status extra
  [ "$status" -eq 2 ]
}

@test "status --porcelain prints STATE TAB DEST TAB SRC per entry" {
  mkrepo_file ".bashrc"
  mkrepo_file "nvim/init.vim"
  ln -s "$DOTMGR_REPO/.bashrc" "$DOTMGR_TARGET/.bashrc"
  write_manifest ".bashrc -> .bashrc" "nvim/init.vim -> .config/nvim/init.vim" ".gone"
  run cmd_status --porcelain
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$(printf 'linked\t.bashrc\t.bashrc')" ]
  [ "${lines[1]}" = "$(printf 'missing\t.config/nvim/init.vim\tnvim/init.vim')" ]
  [ "${lines[2]}" = "$(printf 'nosource\t.gone\t.gone')" ]
}

@test "status -q prints only the per-state counts" {
  mkrepo_file ".bashrc"
  mkrepo_file ".vimrc"
  mktarget_file ".vimrc" "real"
  ln -s "$DOTMGR_REPO/.bashrc" "$DOTMGR_TARGET/.bashrc"
  mkrepo_file ".gitconfig"
  write_manifest ".bashrc" ".vimrc" ".gitconfig" ".gone"
  run cmd_status -q
  [ "$status" -eq 1 ]
  [ "$output" = "linked=1 missing=1 conflict=1 nosource=1" ]
}

@test "status -q exits 0 and prints zero drift counts when all linked" {
  mkrepo_file ".bashrc"
  write_manifest ".bashrc"
  cmd_link
  run cmd_status --quiet
  [ "$status" -eq 0 ]
  [ "$output" = "linked=1 missing=0 conflict=0 nosource=0" ]
}
