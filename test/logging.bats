#!/usr/bin/env bats

load test_helper

setup() { setup_env; }
teardown() { teardown_env; }

@test "info writes an INFO line to stderr" {
  run info "hello world"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[INFO] hello world"* ]]
}

@test "warn writes a WARN line to stderr" {
  run warn "careful"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[WARN] careful"* ]]
}

@test "die logs an ERROR and exits non-zero" {
  run die "boom"
  [ "$status" -ne 0 ]
  [[ "$output" == *"[ERROR] boom"* ]]
}

@test "dm_timestamp is a sortable YYYYMMDD-HHMMSS stamp" {
  run dm_timestamp
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{8}-[0-9]{6}$ ]]
}

@test "dm_abs_src joins repo and source" {
  run dm_abs_src ".bashrc"
  [ "$output" = "$DOTMGR_REPO/.bashrc" ]
}

@test "dm_expand_dest keeps absolute paths verbatim" {
  run dm_expand_dest "/etc/hosts"
  [ "$output" = "/etc/hosts" ]
}

@test "dm_expand_dest resolves relative paths under the target" {
  run dm_expand_dest ".vimrc"
  [ "$output" = "$DOTMGR_TARGET/.vimrc" ]
}

@test "dm_expand_dest expands a leading tilde against the target" {
  run dm_expand_dest "~/.config/app.conf"
  [ "$output" = "$DOTMGR_TARGET/.config/app.conf" ]
}

@test "dm_rel_to_target strips the target prefix" {
  run dm_rel_to_target "$DOTMGR_TARGET/.config/nvim/init.vim"
  [ "$output" = ".config/nvim/init.vim" ]
}

@test "dm_rel_to_target keeps the full path for absolute paths outside the target" {
  run dm_rel_to_target "/opt/thing/file.conf"
  [ "$output" = "_dotmgr_abs/opt/thing/file.conf" ]
}

@test "dm_rel_to_target keeps outside-target paths distinct when basenames match" {
  a="$(dm_rel_to_target "/opt/a/conf")"
  b="$(dm_rel_to_target "/opt/b/conf")"
  [ "$a" != "$b" ]
}

@test "dm_reject_traversal rejects a .. component but allows dots in names" {
  run dm_reject_traversal "manifest destination" "../../etc/passwd"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not contain a '..'"* ]]
  run dm_reject_traversal "manifest destination" "a/../b"
  [ "$status" -ne 0 ]
  run dm_reject_traversal "manifest destination" ".config/my..app/file"
  [ "$status" -eq 0 ]
}
