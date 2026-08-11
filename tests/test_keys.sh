#!/usr/bin/env bash
# ショートカット一覧が読む「herdr 側の設定」のテスト。
#
# ここは自分の設定ファイルと違い、書式を他人（herdr 本体）が決める。しかも
# `herdr --default-config` は設定そのものではなく「全項目をコメントアウトした
# 説明つきの雛形」なので、素直に読むと説明文まで項目として拾う。実際に
#   # type = "shell" runs detached in the background.
# を拾って Type → shell という存在しないキーが一覧に出た。以下はその回帰テスト。
#
# 出力の約束:
#   keys_table    種別<TAB>名前<TAB>キー
#   keys_commands キー<TAB>説明
#   herdr_keys    名前<TAB>キー
#   keys_rows     KEY<TAB>セクション<TAB>キー<TAB>説明

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup() {
  mkdir -p "$TMP/bin"
  config_file="$TMP/panel.toml"          # パネル自身の設定は既定では空にしておく
  herdr_config_file="$TMP/herdr.toml"
  herdr_bin="$TMP/bin/herdr"
  ui_lang=en
}

user_cfg() { cat > "$herdr_config_file"; }   # herdr 本体の設定を書き出す
panel_cfg() { cat > "$config_file"; }        # パネル自身の設定を書き出す

# --default-config だけに答える偽の herdr
fake_default_config() {
  {
    printf '#!/bin/sh\n[ "$1" = --default-config ] || exit 1\ncat <<'"'"'FIXTURE'"'"'\n'
    cat
    printf 'FIXTURE\n'
  } > "$herdr_bin"
  chmod +x "$herdr_bin"
}

# 実物の [keys] を縮めた雛形。説明文・行末コメント・空値・コメントアウトされた
# 見出しといった「読み間違えの種」を一通り含めてある
default_fixture() {
  fake_default_config <<'EOF'
[theme]
# name = "catppuccin"

[keys]
# Prefix key to enter prefix mode (default: "ctrl+b")
# Examples: "ctrl+b", "f12", "esc", "-"
# prefix = "ctrl+b"

# Prefix-mode actions
# next_tab = "prefix+n"
# previous_tab = "prefix+p"
# last_pane = ""          # optional, unset by default
# switch_tab = "prefix+1..9"

# Navigate-mode movement. These local shortcuts win while navigate mode is open.
# navigate_pane_left = "h"      # left arrow always focuses the pane to the left

# Custom commands use the same binding syntax.
# type = "shell" runs detached in the background.
# type = "popup" opens a session-modal terminal without changing the tab layout.
# [[keys.command]]
# key = "prefix+alt+g"
# command = "lazygit"

# [keys.indexed]
# tabs = ""

[ui]
# sidebar_width = 26
EOF
}

#-------------------------------------------------------------------------------
# keys_table — [keys] テーブルの読み取り
#-------------------------------------------------------------------------------
test_reads_commented_defaults() {
  default_fixture
  local out
  out="$("$herdr_bin" --default-config | keys_table 1 D)"
  assert_contains "$out" "D${TAB}prefix${TAB}ctrl+b"
  assert_contains "$out" "D${TAB}next_tab${TAB}prefix+n"
  assert_contains "$out" "D${TAB}switch_tab${TAB}prefix+1..9"
}

test_keeps_a_value_followed_by_a_trailing_comment() {
  default_fixture
  assert_contains "$("$herdr_bin" --default-config | keys_table 1 D)" \
    "D${TAB}navigate_pane_left${TAB}h"
}

test_keeps_an_empty_value_as_empty() {
  # 「既定では未割り当て」を空のまま返す。ここで捨てると、利用者が割り当てた
  # ときに既定の順序で並べられなくなる（落とすのは herdr_keys の仕事）
  default_fixture
  assert_contains "$("$herdr_bin" --default-config | keys_table 1 D)" \
    "D${TAB}last_pane${TAB}"
}

test_ignores_prose_that_looks_like_a_setting() {
  # 回帰テスト: `# type = "shell" runs detached in the background.`
  default_fixture
  assert_not_contains "$("$herdr_bin" --default-config | keys_table 1 D)" "${TAB}type${TAB}"
}

test_stops_at_a_commented_out_table_heading() {
  # [[keys.command]] の例は [keys] の中にコメントで置かれている。見出しとして
  # 扱わないと、例の key / command を [keys] の項目として拾う
  local out
  default_fixture
  out="$("$herdr_bin" --default-config | keys_table 1 D)"
  assert_not_contains "$out" "prefix+alt+g"
  assert_not_contains "$out" "lazygit"
  assert_not_contains "$out" "${TAB}tabs${TAB}"
}

test_stops_at_the_next_real_table() {
  default_fixture
  assert_not_contains "$("$herdr_bin" --default-config | keys_table 1 D)" "sidebar_width"
}

test_reads_uncommented_settings_from_a_user_config() {
  user_cfg <<'EOF'
[keys]
next_tab = "ctrl+alt+n"
# previous_tab = "never-read"

[ui]
sidebar_width = 26
EOF
  local out
  out="$(keys_table 0 U < "$herdr_config_file")"
  assert_eq "U${TAB}next_tab${TAB}ctrl+alt+n" "$out"
}

test_finds_a_heading_that_has_a_trailing_comment() {
  user_cfg <<'EOF'
[keys]   # my bindings
next_tab = "ctrl+alt+n"
EOF
  assert_contains "$(keys_table 0 U < "$herdr_config_file")" "U${TAB}next_tab${TAB}ctrl+alt+n"
}

#-------------------------------------------------------------------------------
# keys_commands — [[keys.command]]
#-------------------------------------------------------------------------------
test_reads_custom_commands() {
  user_cfg <<'EOF'
[[keys.command]]
key = "prefix+f"
description = "open file-viewer"
type = "shell"
command = "herdr plugin action invoke open-file-viewer"
EOF
  assert_eq "prefix+f${TAB}open file-viewer" "$(keys_commands < "$herdr_config_file")"
}

test_reads_every_command_block() {
  # 見出し行に説明を書くのは普通の書き方。完全一致で見ていた頃はここで
  # ブロックの切れ目を見落とし、3 つ書いても最後の 1 つしか出なかった
  user_cfg <<'EOF'
[[keys.command]]              # split ペインで開く
key = "prefix+f"
description = "one"

[[keys.command]]              # 独立タブで開く
key = "prefix+shift+f"
description = "two"

[[keys.command]]
key = "prefix+space"
description = "three"
EOF
  assert_eq "prefix+f${TAB}one${NL}prefix+shift+f${TAB}two${NL}prefix+space${TAB}three" \
            "$(keys_commands < "$herdr_config_file")"
}

test_falls_back_to_the_command_when_there_is_no_description() {
  # description は herdr 側で任意。空欄で出すより手掛かりを見せる
  user_cfg <<'EOF'
[[keys.command]]
key = "prefix+alt+g"
type = "popup"
command = "lazygit"
EOF
  assert_eq "prefix+alt+g${TAB}lazygit" "$(keys_commands < "$herdr_config_file")"
}

test_ignores_keys_outside_a_command_block() {
  user_cfg <<'EOF'
[keys]
prefix = "ctrl+a"

[ui]
sidebar_width = 26
EOF
  assert_empty "$(keys_commands < "$herdr_config_file")"
}

#-------------------------------------------------------------------------------
# herdr_keys — 既定に利用者の設定を被せる
#-------------------------------------------------------------------------------
test_uses_the_defaults_when_nothing_is_overridden() {
  default_fixture
  : > "$herdr_config_file"
  assert_contains "$(herdr_keys)" "next_tab${TAB}prefix+n"
}

test_lets_the_user_config_win() {
  default_fixture
  user_cfg <<'EOF'
[keys]
next_tab = "ctrl+alt+n"
EOF
  local out
  out="$(herdr_keys)"
  assert_contains "$out" "next_tab${TAB}ctrl+alt+n"
  assert_not_contains "$out" "prefix+n${NL}"
}

test_keeps_the_order_of_the_defaults() {
  # 既定の並びは機能ごとにまとまっている。上書きしても並びは動かさない
  default_fixture
  user_cfg <<'EOF'
[keys]
next_tab = "ctrl+alt+n"
EOF
  assert_eq "prefix${NL}next_tab${NL}previous_tab${NL}switch_tab${NL}navigate_pane_left" \
            "$(herdr_keys | cut -d"$TAB" -f1)"
}

test_drops_bindings_that_are_unset() {
  default_fixture
  : > "$herdr_config_file"
  assert_not_contains "$(herdr_keys)" "last_pane"
}

test_shows_a_binding_the_user_assigned_to_an_unset_default() {
  default_fixture
  user_cfg <<'EOF'
[keys]
last_pane = "prefix+tab"
EOF
  assert_contains "$(herdr_keys)" "last_pane${TAB}prefix+tab"
}

test_drops_a_binding_the_user_cleared() {
  default_fixture
  user_cfg <<'EOF'
[keys]
next_tab = ""
EOF
  assert_not_contains "$(herdr_keys)" "next_tab"
}

test_appends_names_the_defaults_do_not_have() {
  # herdr が先に新しい設定を覚えても、パネルは黙って落とさない
  default_fixture
  user_cfg <<'EOF'
[keys]
some_future_action = "prefix+y"
EOF
  assert_eq "some_future_action${TAB}prefix+y" "$(herdr_keys | tail -1)"
}

test_survives_a_missing_herdr() {
  # herdr を呼べなくても、利用者の設定から分かるぶんは出す
  herdr_bin="$TMP/bin/no-such-herdr"
  user_cfg <<'EOF'
[keys]
next_tab = "ctrl+alt+n"
EOF
  assert_eq "next_tab${TAB}ctrl+alt+n" "$(herdr_keys)"
}

test_survives_a_missing_herdr_config() {
  default_fixture
  herdr_config_file="$TMP/does-not-exist.toml"
  assert_contains "$(herdr_keys)" "next_tab${TAB}prefix+n"
}

#-------------------------------------------------------------------------------
# keys_rows — 表示用の行
#-------------------------------------------------------------------------------
test_turns_a_setting_name_into_a_label() {
  default_fixture
  : > "$herdr_config_file"
  assert_contains "$(keys_rows)" "KEY${TAB}herdr${TAB}prefix+n${TAB}Next tab"
}

test_puts_navigate_mode_in_its_own_section() {
  # navigate_ 接頭辞は見出しへ移す（項目名に残すと全部同じ語で始まって読みにくい）
  default_fixture
  : > "$herdr_config_file"
  assert_contains "$(keys_rows)" "KEY${TAB}herdr (navigate mode)${TAB}h${TAB}Pane left"
}

test_lists_custom_commands_in_their_own_section() {
  default_fixture
  user_cfg <<'EOF'
[[keys.command]]
key = "prefix+space"
description = "open control panel"
EOF
  assert_contains "$(keys_rows)" \
    "KEY${TAB}herdr (custom commands)${TAB}prefix+space${TAB}open control panel"
}

test_includes_keys_from_the_panel_config() {
  # herdr の外のキー（端末エミュレータ等）は利用者が書いたぶんだけ出る
  default_fixture
  : > "$herdr_config_file"
  panel_cfg <<'EOF'
[[keys]]
section     = "WezTerm"
key         = "Alt+l"
description = "Domain launcher"
EOF
  assert_contains "$(keys_rows)" "KEY${TAB}WezTerm${TAB}Alt+l${TAB}Domain launcher"
}

#-------------------------------------------------------------------------------
# keys_lines — 見出しと桁揃え
#-------------------------------------------------------------------------------
test_groups_rows_under_a_heading() {
  default_fixture
  : > "$herdr_config_file"
  assert_eq "── herdr" "$(keys_lines | head -1 | cut -d"$TAB" -f2)"
}

test_aligns_the_key_column() {
  default_fixture
  : > "$herdr_config_file"
  panel_cfg <<'EOF'
[[keys]]
section     = "Terminal"
key         = "Ctrl+Shift+Alt+Space"
description = "long"
EOF
  # 一番長いキーに合わせて全体が揃う（セクションをまたいでも同じ幅）
  local widths
  widths="$(keys_lines | cut -d"$TAB" -f2 | grep '^  ' | sed 's/  [^ ].*//' | sort -u | wc -l)"
  assert_eq "1" "$(printf '%s' "$widths" | tr -d ' ')" "every item row must share one indent width"
  assert_contains "$(keys_lines)" "  Ctrl+Shift+Alt+Space  long"
}

test_aligns_a_key_that_contains_full_width_characters() {
  # 回帰テスト: printf の %-Ns はバイト数で詰めるので、`Ctrl+クリック` のような
  # 全角混じりのキーだけ説明の開始位置が手前へずれていた
  default_fixture
  : > "$herdr_config_file"
  panel_cfg <<'EOF'
[[keys]]
section     = "Terminal"
key         = "Ctrl+クリック"
description = "wide"

[[keys]]
section     = "Terminal"
key         = "Ctrl+Shift+Click"
description = "narrow"
EOF
  # 表示幅で数えれば "Ctrl+クリック"(13) は "Ctrl+Shift+Click"(16) より 3 桁短い
  local wide narrow
  wide="$(keys_lines | cut -d"$TAB" -f2 | grep 'wide$')"
  narrow="$(keys_lines | cut -d"$TAB" -f2 | grep 'narrow$')"
  assert_eq "  Ctrl+クリック     wide" "$wide"
  assert_eq "  Ctrl+Shift+Click  narrow" "$narrow"
}

test_separates_sections_with_a_blank_row() {
  default_fixture
  : > "$herdr_config_file"
  panel_cfg <<'EOF'
[[keys]]
section     = "WezTerm"
key         = "Alt+l"
description = "Domain launcher"
EOF
  assert_contains "$(keys_lines | cut -d"$TAB" -f2)" "${NL}${NL}── WezTerm"
}

test_returns_nothing_when_there_is_nothing_to_show() {
  # パネルは「一覧が空」を検出して案内を出す。空行だけ返すとその判定が壊れる
  herdr_bin="$TMP/bin/no-such-herdr"
  herdr_config_file="$TMP/does-not-exist.toml"
  assert_empty "$(keys_lines)"
}

run_tests
