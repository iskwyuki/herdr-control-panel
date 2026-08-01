#!/usr/bin/env bash
# パス操作のテスト（expand_path / split_query / short_path / complete_dirs）。
#
# Open Folder の「打つたびに候補が入れ替わる」挙動はここが全部。find と awk の
# 組み合わせなので、GNU と BSD の差が出るならこの層で出る。
#
# complete_dirs の出力の約束: 種別<TAB>表示<TAB>パス
#   OPEN … 確定行（▸ ここを開く）  UP … 親へ  DIR … 候補ディレクトリ

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup() {
  ui_lang=en
  # macOS の $TMPDIR は /var/folders/... というシンボリックリンク越しの場所なので、
  # 比較のために実体のパスへ寄せておく
  TMP="$(cd "$TMP" && pwd -P)"
  # aalpha は「辞書順では先頭・前方一致ではない」役。これが無いと、並び替えを
  # 素通しにしても結果が変わらず、前方一致優先のテストが恒真になる
  mkdir -p "$TMP/alpha" "$TMP/alphabet" "$TMP/aalpha" "$TMP/beta" "$TMP/xalpha" "$TMP/.hidden"
  : > "$TMP/plain.txt"
  ln -s "$TMP/alpha"     "$TMP/dirlink"
  ln -s "$TMP/plain.txt" "$TMP/filelink"
  ln -s "$TMP/nowhere"   "$TMP/brokenlink"
}

kinds_of()  { complete_dirs "$1" | cut -d"$TAB" -f1; }
names_of()  { complete_dirs "$1" | grep "^DIR" | cut -d"$TAB" -f3 | sed 's|.*/||'; }
target_of() { complete_dirs "$1" | grep "^OPEN" | cut -d"$TAB" -f3; }
joined()    { printf '%s' "$(tr '\n' ' ' | sed 's/ $//')"; }

#-------------------------------------------------------------------------------
# expand_path — 入力欄に打たれた文字列を絶対パスにする
#-------------------------------------------------------------------------------
test_expand_path_expands_a_bare_tilde() {
  assert_eq "$HOME" "$(expand_path '~')"
}

test_expand_path_expands_a_tilde_prefix() {
  assert_eq "$HOME/dev" "$(expand_path '~/dev')"
}

test_expand_path_leaves_an_absolute_path_alone() {
  assert_eq "/etc/hosts" "$(expand_path '/etc/hosts')"
}

test_expand_path_treats_a_relative_path_as_relative_to_home() {
  assert_eq "$HOME/dev" "$(expand_path 'dev')"
}

test_expand_path_turns_an_empty_query_into_home() {
  # 入力を全消ししたらホームの中身を出す（袋小路にしない）
  assert_eq "$HOME/" "$(expand_path '')"
}

test_expand_path_does_not_expand_a_tilde_user_name() {
  # ~user 展開は未対応。誤って展開するより、そのまま扱って「見つからない」に倒す
  assert_eq "$HOME/~root" "$(expand_path '~root')"
}

#-------------------------------------------------------------------------------
# split_query — 候補を探すディレクトリと入力途中の名前に分ける
#-------------------------------------------------------------------------------
test_split_query_uses_the_directory_itself_when_the_path_ends_in_a_slash() {
  split_query "$TMP/"
  assert_eq "$TMP" "$q_base"
  assert_empty "$q_leaf"
}

test_split_query_splits_a_partial_name_from_its_parent() {
  split_query "$TMP/alp"
  assert_eq "$TMP" "$q_base"
  assert_eq "alp" "$q_leaf"
}

test_split_query_keeps_the_root_as_base() {
  split_query "/"
  assert_eq "/" "$q_base"
  assert_empty "$q_leaf"
}

test_split_query_falls_back_to_home_for_an_empty_query() {
  split_query ""
  assert_eq "$HOME" "$q_base"
  assert_empty "$q_leaf"
}

#-------------------------------------------------------------------------------
# short_path — 表示用の ~ 表記
#-------------------------------------------------------------------------------
test_short_path_shortens_the_home_directory_itself() {
  assert_eq "~" "$(short_path "$HOME")"
}

test_short_path_shortens_a_path_under_home() {
  assert_eq "~/dev/x" "$(short_path "$HOME/dev/x")"
}

test_short_path_leaves_other_paths_alone() {
  assert_eq "/etc" "$(short_path "/etc")"
}

test_short_path_does_not_shorten_a_sibling_that_shares_the_home_prefix() {
  # $HOME=/Users/foo のとき /Users/foobar を ~bar にしてはいけない
  assert_eq "${HOME}bar" "$(short_path "${HOME}bar")"
}

#-------------------------------------------------------------------------------
# complete_dirs — 候補の中身
#-------------------------------------------------------------------------------
test_lists_directories_under_a_path_ending_in_a_slash() {
  assert_eq "aalpha alpha alphabet beta dirlink xalpha" "$(names_of "$TMP/" | joined)"
}

test_skips_regular_files() {
  assert_not_contains "$(names_of "$TMP/" | joined)" "plain.txt"
}

test_skips_hidden_directories_by_default() {
  assert_not_contains "$(names_of "$TMP/" | joined)" ".hidden"
}

test_lists_hidden_directories_once_the_query_starts_with_a_dot() {
  assert_eq ".hidden" "$(names_of "$TMP/." | joined)"
}

test_follows_a_symlink_that_points_to_a_directory() {
  # find の -H が無いと、リンク越しのディレクトリで候補が 1 件も出なくなる
  assert_contains "$(names_of "$TMP/" | joined)" "dirlink"
}

test_skips_a_symlink_that_points_to_a_file() {
  assert_not_contains "$(names_of "$TMP/" | joined)" "filelink"
}

test_skips_a_broken_symlink() {
  assert_not_contains "$(names_of "$TMP/" | joined)" "brokenlink"
}

test_lists_the_contents_of_a_directory_reached_through_a_symlink() {
  mkdir -p "$TMP/alpha/inner"
  assert_eq "inner" "$(names_of "$TMP/dirlink/" | joined)"
}

test_sorts_prefix_matches_before_substring_matches() {
  # パス補完としての自然さを優先する。aalpha は辞書順なら先頭に来るので、
  # 並び替えを外すと結果が変わる＝この並びが実装の証拠になる
  assert_eq "alpha alphabet aalpha xalpha" "$(names_of "$TMP/alpha" | joined)"
}

test_matches_case_insensitively() {
  assert_eq "alpha alphabet aalpha xalpha" "$(names_of "$TMP/ALPHA" | joined)"
}

#-------------------------------------------------------------------------------
# complete_dirs — 行の構成
#-------------------------------------------------------------------------------
test_puts_the_open_here_row_first() {
  assert_eq "OPEN" "$(kinds_of "$TMP/" | head -1)"
}

test_offers_a_parent_row_below_it() {
  assert_eq "UP" "$(kinds_of "$TMP/" | sed -n 2p)"
}

test_offers_no_parent_row_at_the_root() {
  assert_not_contains "$(kinds_of "/" | joined)" "UP"
}

test_targets_the_typed_path_when_it_exists() {
  assert_eq "$TMP/alpha" "$(target_of "$TMP/alpha")"
}

test_targets_the_parent_when_the_typed_path_does_not_exist() {
  # 打ち切っていない途中入力でも「ここを開く」が意味を持つようにする
  assert_eq "$TMP" "$(target_of "$TMP/zzz")"
}

test_emits_three_tab_separated_columns() {
  assert_eq "3" "$(complete_dirs "$TMP/" | awk -F"$TAB" '{print NF}' | sort -u | joined)"
}

test_shortens_home_paths_in_the_display_column() {
  local out
  out="$(complete_dirs "$HOME/" | grep "^DIR" | head -1 | cut -d"$TAB" -f2)"
  assert_contains "$out" "~/"
}

test_shortens_the_home_directory_itself_in_the_display_column() {
  # $HOME 自身は "$HOME/*" にマッチしない。専用の分岐が無いとここだけフルパスで並ぶ
  local row
  row="$(complete_dirs "$(dirname "$HOME")/" | awk -F"$TAB" -v h="$HOME" '$1 == "DIR" && $3 == h {print $2}')"
  assert_eq "~/" "$row"
}

test_returns_nothing_but_the_fixed_rows_for_an_unreadable_directory() {
  # 権限が無い場所でも黙って空を返す（find のエラーで画面を汚さない）
  assert_empty "$(names_of "/dev/null/nope" | joined)"
}

run_tests
