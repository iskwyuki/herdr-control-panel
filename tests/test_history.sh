#!/usr/bin/env bash
# ワークスペース履歴のテスト（add_history / list_history）。
#
# add_history のパイプラインは pipefail の罠を踏みやすい。grep -vxF は「除外した結果が
# 空」のときに 1 を返し、それがブロックの終了ステータスになり、pipefail でパイプライン
# 全体が失敗扱いになる。add_history の戻り値は open_workspace の戻り値になり、呼び出し側は
# `open_workspace "$dir" || exit 1` で見ているので、ワークスペースを開いた直後に
# エラー終了する。初回と「履歴が 1 件だけ」のときに起きるので、両方を固定しておく。
#
# 出力の約束（list_history）: HIST<TAB>表示<TAB>パス

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup() {
  ui_lang=en
  TMP="$(cd "$TMP" && pwd -P)"
  hist_file="$TMP/state/workspaces"   # 親ディレクトリはまだ無い
  mkdir -p "$TMP/a" "$TMP/b" "$TMP/c"
}

entries() { cat "$hist_file" 2>/dev/null; }
joined()  { printf '%s' "$(tr '\n' ' ' | sed 's/ $//')"; }

#-------------------------------------------------------------------------------
# add_history — 終了ステータス（呼び出し側が exit 判定に使う）
#-------------------------------------------------------------------------------
test_add_history_succeeds_on_the_very_first_entry() {
  assert_status 0 add_history "$TMP/a"
}

test_add_history_succeeds_when_the_only_entry_is_added_again() {
  # 除外した結果が空になり grep が 1 を返す経路
  add_history "$TMP/a"
  assert_status 0 add_history "$TMP/a"
}

test_add_history_succeeds_when_an_entry_is_promoted_to_the_top() {
  add_history "$TMP/a"
  add_history "$TMP/b"
  assert_status 0 add_history "$TMP/a"
}

#-------------------------------------------------------------------------------
# add_history — 中身
#-------------------------------------------------------------------------------
test_creates_the_state_directory_on_demand() {
  add_history "$TMP/a"
  assert_eq "$TMP/a" "$(entries)"
}

test_puts_the_newest_entry_first() {
  add_history "$TMP/a"
  add_history "$TMP/b"
  assert_eq "$TMP/b $TMP/a" "$(entries | joined)"
}

test_moves_an_existing_entry_to_the_top_instead_of_duplicating_it() {
  add_history "$TMP/a"
  add_history "$TMP/b"
  add_history "$TMP/a"
  assert_eq "$TMP/a $TMP/b" "$(entries | joined)"
}

test_keeps_one_entry_when_it_is_added_twice() {
  add_history "$TMP/a"
  add_history "$TMP/a"
  assert_eq "$TMP/a" "$(entries | joined)"
}

test_does_not_treat_an_entry_as_a_prefix_of_another() {
  # grep -vxF の -x（行全体一致）が無いと $TMP/a が $TMP/ab を巻き込んで消す
  add_history "$TMP/ab"
  add_history "$TMP/a"
  assert_eq "$TMP/a $TMP/ab" "$(entries | joined)"
}

test_caps_the_history_at_the_configured_maximum() {
  local i=0
  while [ "$i" -lt $((hist_max + 5)) ]; do
    add_history "$TMP/dir-$i"
    i=$((i + 1))
  done
  assert_eq "$hist_max" "$(entries | wc -l | tr -d ' ')"
}

test_keeps_the_newest_entries_when_it_overflows() {
  local i=0
  while [ "$i" -lt $((hist_max + 1)) ]; do
    add_history "$TMP/dir-$i"
    i=$((i + 1))
  done
  assert_eq "$TMP/dir-$hist_max" "$(entries | head -1)"
  assert_not_contains "$(entries)" "$TMP/dir-0" "the oldest entry must fall off"
}

test_never_leaves_the_history_empty_after_a_write() {
  # 書き出しに失敗したら元を残す（空ファイルで上書きしない）契約
  add_history "$TMP/a"
  add_history "$TMP/b"
  assert_eq "2" "$(entries | wc -l | tr -d ' ')"
}

#-------------------------------------------------------------------------------
# list_history — 表示
#-------------------------------------------------------------------------------
test_list_history_returns_nothing_without_a_history_file() {
  assert_empty "$(list_history)"
}

test_list_history_emits_three_tab_separated_columns() {
  add_history "$TMP/a"
  assert_eq "3" "$(list_history | awk -F"$TAB" '{print NF}' | sort -u | joined)"
}

test_list_history_marks_rows_with_the_hist_kind() {
  add_history "$TMP/a"
  assert_eq "HIST" "$(list_history | cut -d"$TAB" -f1)"
}

test_list_history_skips_directories_that_no_longer_exist() {
  add_history "$TMP/a"
  add_history "$TMP/gone"
  rm -rf "$TMP/gone"
  assert_eq "$TMP/a" "$(list_history | cut -d"$TAB" -f3 | joined)"
}

test_list_history_keeps_the_stored_order() {
  add_history "$TMP/a"
  add_history "$TMP/b"
  add_history "$TMP/c"
  assert_eq "$TMP/c $TMP/b $TMP/a" "$(list_history | cut -d"$TAB" -f3 | joined)"
}

test_list_history_shortens_paths_under_home() {
  mkdir -p "$(dirname "$hist_file")"
  printf '%s\n' "$HOME" > "$hist_file"
  assert_eq "~" "$(list_history | cut -d"$TAB" -f2)"
}

test_list_history_ignores_blank_lines() {
  mkdir -p "$(dirname "$hist_file")"
  printf '%s\n\n%s\n' "$TMP/a" "$TMP/b" > "$hist_file"
  assert_eq "$TMP/a $TMP/b" "$(list_history | cut -d"$TAB" -f3 | joined)"
}

run_tests
