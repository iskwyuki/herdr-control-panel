#!/usr/bin/env bash
# 項目まわりのテスト（requirement_of / have_requirement / append_action /
# ensure_config / catalog）。
#
# 「Add action... から足したものが、手書きしたものと同じファイルに同じ記法で入る」が
# 売りなので、書き込み（append_action）と読み込み（parse_config）の往復を固定する。
# ここが食い違うと、UI から足した項目が自分のパーサで弾かれるという最悪の形になる。

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup() {
  ui_lang=en
  cfg_dir="$TMP/config"
  config_file="$cfg_dir/config.toml"
  herdr_bin="$TMP/bin/herdr"
  mkdir -p "$TMP/bin"
}

mock_herdr() {  # mock_herdr <plugin list として出力させる文字列>
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$TMP/bin/herdr"
  chmod +x "$TMP/bin/herdr"
}

#-------------------------------------------------------------------------------
# requirement_of — 何を存在確認するか
#-------------------------------------------------------------------------------
test_requirement_of_prefers_an_explicit_requires() {
  assert_eq "herdr" "$(requirement_of "some command --with args" "herdr")"
}

test_requirement_of_falls_back_to_the_first_word_of_the_command() {
  # 大半の項目は label と command の 2 行で済ませたい
  assert_eq "lazygit" "$(requirement_of "lazygit --all" "")"
}

test_requirement_of_handles_a_command_without_arguments() {
  assert_eq "btop" "$(requirement_of "btop" "")"
}

#-------------------------------------------------------------------------------
# have_requirement — 存在確認そのもの
#-------------------------------------------------------------------------------
test_have_requirement_accepts_an_empty_requirement() {
  # requires も command も無い項目は素通しにする（弾く理由がない）
  assert_status 0 have_requirement ""
}

test_have_requirement_finds_a_command_on_the_path() {
  assert_status 0 have_requirement "sh"
}

test_have_requirement_rejects_a_missing_command() {
  assert_status 1 have_requirement "definitely-not-installed-xyz"
}

test_have_requirement_understands_the_cmd_prefix() {
  assert_status 0 have_requirement "cmd:sh"
}

test_have_requirement_rejects_a_missing_cmd_prefix() {
  assert_status 1 have_requirement "cmd:definitely-not-installed-xyz"
}

test_have_requirement_finds_an_installed_plugin() {
  mock_herdr "herdr-file-viewer (herdr-file-viewer) enabled"
  assert_status 0 have_requirement "plugin:herdr-file-viewer"
}

test_have_requirement_rejects_a_plugin_that_is_not_installed() {
  mock_herdr "herdr-control-panel (herdr-control-panel) enabled"
  assert_status 1 have_requirement "plugin:herdr-file-viewer"
}

test_have_requirement_rejects_a_plugin_when_herdr_is_absent() {
  herdr_bin="$TMP/bin/no-such-herdr"
  assert_status 1 have_requirement "plugin:anything"
}

#-------------------------------------------------------------------------------
# append_action — 書いたものが自分で読めるか
#-------------------------------------------------------------------------------
test_appends_a_block_that_parses_back() {
  append_action "My Tool" "mytool --flag"
  assert_eq "ACT${TAB}My Tool${TAB}mytool --flag${TAB}" "$(parse_config)"
}

test_appends_without_disturbing_existing_blocks() {
  append_action "First" "first"
  append_action "Second" "second"
  assert_eq "ACT${TAB}First${TAB}first${TAB}${NL}ACT${TAB}Second${TAB}second${TAB}" \
            "$(parse_config)"
}

test_appends_after_a_hand_written_block() {
  mkdir -p "$cfg_dir"
  printf '[[actions]]\nlabel   = "Hand"\ncommand = "hand"\n' > "$config_file"
  append_action "Added" "added"
  assert_eq "ACT${TAB}Hand${TAB}hand${TAB}${NL}ACT${TAB}Added${TAB}added${TAB}" \
            "$(parse_config)"
}

test_creates_the_config_directory_on_demand() {
  assert_status 0 append_action "A" "a"
  assert_eq "ACT${TAB}A${TAB}a${TAB}" "$(parse_config)"
}

test_keeps_a_command_with_pipes_readable() {
  append_action "Piped" "sh -c 'ls | less'"
  assert_eq "ACT${TAB}Piped${TAB}sh -c 'ls | less'${TAB}" "$(parse_config)"
}

#-------------------------------------------------------------------------------
# ensure_config — 初回に書き出す雛形
#-------------------------------------------------------------------------------
test_writes_a_template_on_first_run() {
  ensure_config
  assert_contains "$(cat "$config_file")" "[[actions]]"
}

test_the_template_passes_its_own_parser() {
  # 雛形が自分のパーサでエラーになるようでは、初回起動から ⚠ が出てしまう
  ensure_config
  assert_status 0 check_config
  assert_empty "$(parse_config)" "the template must define nothing yet"
}

test_does_not_overwrite_an_existing_config() {
  mkdir -p "$cfg_dir"
  printf 'mine\n' > "$config_file"
  ensure_config
  assert_eq "mine" "$(cat "$config_file")"
}

test_writes_the_japanese_template_when_selected() {
  ui_lang=ja
  ensure_config
  assert_contains "$(cat "$config_file")" "ブロックの開始"
}

test_the_japanese_template_also_passes_its_own_parser() {
  ui_lang=ja
  ensure_config
  assert_status 0 check_config
}

#-------------------------------------------------------------------------------
# catalog — Add action... に並ぶ同梱の候補
#-------------------------------------------------------------------------------
test_catalog_rows_have_three_columns() {
  assert_eq "3" "$(catalog | awk -F"$TAB" '{print NF}' | sort -u | tr -d '\n')"
}

test_catalog_values_never_contain_a_double_quote() {
  # 値に " が入ると、書き込んだ瞬間に自分のパーサで読めなくなる
  assert_empty "$(catalog | grep '"' || true)"
}

test_every_catalog_entry_survives_a_round_trip() {
  local want
  want="$(catalog | wc -l | tr -d ' ')"
  catalog | while IFS="$TAB" read -r label command _; do
    append_action "$label" "$command"
  done
  assert_eq "$want" "$(parse_config | grep -c '^ACT' | tr -d ' ')"
}

test_catalog_requirements_use_a_known_prefix() {
  # have_requirement が解釈できるのは cmd: / plugin: / 素のコマンド名だけ
  assert_empty "$(catalog | cut -d"$TAB" -f3 | grep ':' | grep -v '^cmd:' | grep -v '^plugin:' || true)"
}

run_tests
