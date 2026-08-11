#!/usr/bin/env bash
# parse_config() と check_config() のテスト。
#
# ここが一番厚いのは、受け付ける記法のサブセットと「逸脱は行番号つきで報告する」が
# README に書いた公開仕様だから。手書きパーサなので回帰しやすく、静かに壊れると
# 利用者への約束がそのまま破れる。
#
# 出力の約束（parse_config）:
#   ACT<TAB>label<TAB>command<TAB>requires
#   KEY<TAB>section<TAB>key<TAB>description
#   ERR<TAB>L<行番号>: 本文

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup() {
  config_file="$TMP/config.toml"
  ui_lang=en
}

cfg() { cat > "$config_file"; }          # heredoc を設定ファイルとして書き出す
errors_of() { check_config 2>&1 || true; }  # check_config は問題があると 1 を返す
line_numbers_of() { errors_of | grep '  ERR' | grep -o 'L[0-9]*'; }

#-------------------------------------------------------------------------------
# 正常系
#-------------------------------------------------------------------------------
test_parses_a_minimal_action() {
  cfg <<'EOF'
[[actions]]
label   = "Lazygit"
command = "lazygit"
EOF
  assert_eq "ACT${TAB}Lazygit${TAB}lazygit${TAB}" "$(parse_config)"
}

test_keeps_the_requires_field() {
  cfg <<'EOF'
[[actions]]
label    = "Files"
command  = "herdr plugin action invoke open-file-viewer"
requires = "herdr"
EOF
  assert_eq "ACT${TAB}Files${TAB}herdr plugin action invoke open-file-viewer${TAB}herdr" \
            "$(parse_config)"
}

test_parses_multiple_blocks() {
  cfg <<'EOF'
[[actions]]
label   = "A"
command = "a"

[[actions]]
label   = "B"
command = "b"
EOF
  assert_eq "ACT${TAB}A${TAB}a${TAB}${NL}ACT${TAB}B${TAB}b${TAB}" "$(parse_config)"
}

test_ignores_comments_and_blank_lines() {
  cfg <<'EOF'
# a comment

   # an indented comment
[[actions]]
label   = "A"

command = "a"
EOF
  assert_eq "ACT${TAB}A${TAB}a${TAB}" "$(parse_config)"
}

test_trims_whitespace_around_keys_and_values() {
  printf '   [[actions]]   \n  label    =    "A"  \n\tcommand\t=\t"a"\t\n' > "$config_file"
  assert_eq "ACT${TAB}A${TAB}a${TAB}" "$(parse_config)"
}

test_keeps_an_equals_sign_inside_a_value() {
  cfg <<'EOF'
[[actions]]
label   = "Env"
command = "FOO=bar run"
EOF
  assert_eq "ACT${TAB}Env${TAB}FOO=bar run${TAB}" "$(parse_config)"
}

test_keeps_pipes_and_single_quotes_inside_a_command() {
  cfg <<'EOF'
[[actions]]
label   = "List"
command = "sh -c 'ls | less'"
EOF
  assert_eq "ACT${TAB}List${TAB}sh -c 'ls | less'${TAB}" "$(parse_config)"
}

test_flushes_the_last_block_at_end_of_file() {
  # 最後のブロックは次の [[actions]] が来ないので、EOF 後の flush でしか出力されない
  cfg <<'EOF'
[[actions]]
label   = "A"
command = "a"

[[actions]]
label   = "Last"
command = "last"
EOF
  assert_contains "$(parse_config)" "ACT${TAB}Last${TAB}last${TAB}"
}

test_reads_a_file_without_a_trailing_newline() {
  # read は改行で終わらない最終行に対して非ゼロを返す。|| [ -n "$line" ] が無いと落ちる
  printf '[[actions]]\nlabel   = "A"\ncommand = "a"' > "$config_file"
  assert_eq "ACT${TAB}A${TAB}a${TAB}" "$(parse_config)"
}

test_returns_nothing_for_an_empty_file() {
  : > "$config_file"
  assert_empty "$(parse_config)"
}

test_returns_nothing_when_the_file_is_missing() {
  config_file="$TMP/does-not-exist.toml"
  assert_empty "$(parse_config)"
}

#-------------------------------------------------------------------------------
# [[keys]] — ショートカット一覧に足す行
#-------------------------------------------------------------------------------
test_parses_a_keys_block() {
  cfg <<'EOF'
[[keys]]
section     = "WezTerm"
key         = "Alt+l"
description = "Domain launcher"
EOF
  assert_eq "KEY${TAB}WezTerm${TAB}Alt+l${TAB}Domain launcher" "$(parse_config)"
}

test_falls_back_to_a_default_section() {
  # section は任意。省略しても捨てずに受け皿の見出しへ入れる
  cfg <<'EOF'
[[keys]]
key         = "F1"
description = "Help"
EOF
  assert_eq "KEY${TAB}Other${TAB}F1${TAB}Help" "$(parse_config)"
}

test_mixes_actions_and_keys_in_one_file() {
  cfg <<'EOF'
[[actions]]
label   = "Lazygit"
command = "lazygit"

[[keys]]
section     = "WezTerm"
key         = "Alt+n"
description = "NAS tab"
EOF
  assert_eq "ACT${TAB}Lazygit${TAB}lazygit${TAB}${NL}KEY${TAB}WezTerm${TAB}Alt+n${TAB}NAS tab" \
            "$(parse_config)"
}

test_reports_a_keys_block_missing_its_description() {
  cfg <<'EOF'
[[keys]]
key = "Alt+l"
EOF
  assert_eq "ERR${TAB}L1: key and description are both required" "$(parse_config)"
}

test_reports_an_unknown_key_inside_a_keys_block() {
  # 綴りを間違えたとき、どちらのテーブルの語彙を出すかで案内が変わる
  cfg <<'EOF'
[[keys]]
key         = "Alt+l"
description = "Domain launcher"
label       = "nope"
EOF
  assert_contains "$(parse_config)" \
    "ERR${TAB}L4: unknown key (only key / description / section): label"
}

test_reports_an_actions_key_inside_an_actions_block() {
  # 逆向き。[[actions]] の中では key / description のほうが未知になる
  cfg <<'EOF'
[[actions]]
label       = "A"
command     = "a"
description = "nope"
EOF
  assert_contains "$(parse_config)" \
    "ERR${TAB}L4: unknown key (only label / command / requires): description"
}

test_check_config_lists_keys_entries() {
  cfg <<'EOF'
[[keys]]
section     = "WezTerm"
key         = "Alt+l"
description = "Domain launcher"
EOF
  assert_status 0 check_config
  assert_contains "$(errors_of)" "  ok   [WezTerm] Alt+l -> Domain launcher"
}

#-------------------------------------------------------------------------------
# エラー報告 — 行番号と分類
#-------------------------------------------------------------------------------
test_reports_a_block_missing_its_label() {
  # 不足を報告する行はキーの行ではなくブロックの開始行（利用者が直す単位に合わせる）
  cfg <<'EOF'
[[actions]]
command = "a"
EOF
  assert_eq "ERR${TAB}L1: label and command are both required" "$(parse_config)"
}

test_reports_a_block_missing_its_command() {
  cfg <<'EOF'

[[actions]]
label = "A"
EOF
  assert_eq "ERR${TAB}L2: label and command are both required" "$(parse_config)"
}

test_reports_an_unknown_table() {
  cfg <<'EOF'
[settings]
EOF
  assert_eq "ERR${TAB}L1: unknown table (only [[actions]] and [[keys]] are allowed): [settings]" \
            "$(parse_config)"
}

test_reports_a_line_without_an_equals_sign() {
  cfg <<'EOF'
[[actions]]
label   = "A"
command = "a"
nonsense
EOF
  assert_contains "$(parse_config)" "ERR${TAB}L4: cannot parse this line: nonsense"
}

test_reports_a_key_outside_any_block() {
  cfg <<'EOF'
label = "orphan"
EOF
  assert_contains "$(parse_config)" "ERR${TAB}L1: key outside of [[actions]] / [[keys]]: label"
}

test_reports_an_unquoted_value() {
  cfg <<'EOF'
[[actions]]
label   = A
command = "a"
EOF
  assert_contains "$(parse_config)" \
    "ERR${TAB}L2: value must be wrapped in double quotes: label"
}

test_reports_a_double_quote_inside_a_value() {
  cfg <<'EOF'
[[actions]]
label   = "say "hi""
command = "a"
EOF
  assert_contains "$(parse_config)" \
    "ERR${TAB}L2: double quotes inside a value are not supported (use single quotes): label"
}

test_reports_an_unknown_key() {
  cfg <<'EOF'
[[actions]]
label   = "A"
command = "a"
icon    = "x"
EOF
  assert_contains "$(parse_config)" \
    "ERR${TAB}L4: unknown key (only label / command / requires): icon"
}

test_reports_every_empty_block() {
  cfg <<'EOF'
[[actions]]
[[actions]]
EOF
  assert_eq "ERR${TAB}L1: label and command are both required${NL}ERR${TAB}L2: label and command are both required" \
            "$(parse_config)"
}

#-------------------------------------------------------------------------------
# 設定エラーとコア機能の分離（README に書いた約束）
#-------------------------------------------------------------------------------
test_keeps_valid_actions_when_others_are_broken() {
  cfg <<'EOF'
[[actions]]
label   = "Good"
command = "good"

[[actions]]
label = "Broken"

garbage here
EOF
  local out
  out="$(parse_config)"
  assert_contains "$out" "ACT${TAB}Good${TAB}good${TAB}" "valid action must survive"
  assert_contains "$out" "ERR${TAB}L5: label and command are both required"
  assert_contains "$out" "ERR${TAB}L8: cannot parse this line: garbage here"
}

test_never_fails_even_on_a_broken_file() {
  # パネルが開かなくなるのが最悪の体験なので、パーサは常に 0 を返す契約
  printf '[[[[nonsense\n= = =\n"" ""\n' > "$config_file"
  assert_status 0 parse_config
}

#-------------------------------------------------------------------------------
# check_config — 終了コードと並び順
#-------------------------------------------------------------------------------
test_check_config_succeeds_on_a_valid_file() {
  cfg <<'EOF'
[[actions]]
label   = "A"
command = "a"
EOF
  assert_status 0 check_config
  assert_contains "$(errors_of)" "  ok   A -> a"
}

test_check_config_shows_the_requires_field() {
  cfg <<'EOF'
[[actions]]
label    = "A"
command  = "a"
requires = "b"
EOF
  assert_contains "$(errors_of)" "  ok   A -> a [requires: b]"
}

test_check_config_fails_when_there_are_errors() {
  cfg <<'EOF'
[[actions]]
label = "A"
EOF
  assert_status 1 check_config
}

test_check_config_succeeds_when_the_file_is_missing() {
  config_file="$TMP/none.toml"
  assert_status 0 check_config
  assert_contains "$(errors_of)" "No config file yet"
}

test_check_config_lists_the_file_path_first() {
  cfg <<'EOF'
[[actions]]
label   = "A"
command = "a"
EOF
  assert_eq "$config_file" "$(errors_of | head -1)"
}

test_check_config_still_lists_valid_actions_alongside_errors() {
  cfg <<'EOF'
[[actions]]
label   = "Good"
command = "good"

[[actions]]
label = "Broken"
EOF
  local out
  out="$(errors_of)"
  assert_contains "$out" "  ok   Good -> good"
  assert_contains "$out" "  ERR  L5"
}

test_check_config_sorts_errors_by_line_number() {
  # パーサはブロックの不足を「次の [[actions]] に着いた時」に報告するので、
  # 解析順のままだと後ろの行のエラーが先に出る。読む順序に直すのが sort_errors の役目
  cfg <<'EOF'
[[actions]]
label = "A"
garbage
[[actions]]
label   = "B"
command = "b"
EOF
  assert_eq "L1${NL}L3" "$(line_numbers_of)"
}

test_check_config_sorts_line_numbers_numerically() {
  # L9 は不足の報告なので EOF まで出ず、L10 の解釈エラーが先に出る。つまり
  # 解析順なら L10→L9、辞書順なら "L10" < "L9" でやはり L10→L9。数値で並べたときだけ
  # L9→L10 になる。3 つの実装を見分けられる入力にしてある
  printf '[[actions]]\nlabel   = "A"\ncommand = "a"\n\n\n\n\n\n[[actions]]\ngarbage\n' > "$config_file"
  assert_eq "L9${NL}L10" "$(line_numbers_of)"
}

#-------------------------------------------------------------------------------
# 文言
#-------------------------------------------------------------------------------
test_reports_errors_in_japanese_when_selected() {
  ui_lang=ja
  cfg <<'EOF'
[[actions]]
command = "a"
EOF
  assert_eq "ERR${TAB}L1: label / command が揃っていません" "$(parse_config)"
}

test_falls_back_to_the_key_for_an_unknown_message() {
  assert_eq "no_such_message" "$(msg no_such_message)"
}

run_tests
