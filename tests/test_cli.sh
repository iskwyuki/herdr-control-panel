#!/usr/bin/env bash
# エントリポイントのテスト — panel.sh を「コマンドとして」起動する。
#
# 他のテストは panel.sh を source して関数を直接呼ぶ。速くて書きやすいが、その
# 代わり main の case 文と実行ガードだけがどのテストにも触られない。実際、この
# ファイルを書く前は `--complete-dirs` の綴りを壊しても全件グリーンだった。
# ここだけはサブプロセスで起動して、終了コードと標準出力を見る。
#
# --complete-dirs は fzf の change:reload が本番で叩く経路でもある（パネルの中で
# 打鍵のたびに呼ばれる）ので、壊れると Open Folder が無言で候補ゼロになる。

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup() {
  TMP="$(cd "$TMP" && pwd -P)"
  mkdir -p "$TMP/cfg" "$TMP/state"
}

# panel.sh をコマンドとして起動する。テスト用の置き場を渡し、herdr には触らせない。
#
# PATH から fzf と jq を外しているのは、この 2 つのサブコマンドが選択 UI を通らずに
# 完結するという契約の検証を兼ねる。加えて安全装置でもある: dispatch が壊れて
# メニュー経路へ落ちた場合、fzf があると /dev/tty を掴んで止まり（stdin を
# /dev/null にしても fzf は tty を直接開くので効かない）、テストが「失敗」ではなく
# 「ハング」になる。fzf が無ければ依存チェックが即座に非ゼロで返る。
panel() {  # panel <引数...>
  env HERDR_PLUGIN_CONFIG_DIR="$TMP/cfg" HERDR_PLUGIN_STATE_DIR="$TMP/state" \
      PATH="/bin:/usr/bin" \
      /bin/bash "$PANEL" "$@" < /dev/null
}

valid_config() {
  printf '[[actions]]\nlabel   = "A"\ncommand = "a"\n' > "$TMP/cfg/config.toml"
}

#-------------------------------------------------------------------------------
# --check-config
#-------------------------------------------------------------------------------
test_check_config_reports_a_valid_config() {
  valid_config
  assert_contains "$(panel --check-config)" "  ok   A -> a"
}

test_check_config_exits_zero_for_a_valid_config() {
  valid_config
  assert_status 0 panel --check-config
}

test_check_config_exits_nonzero_for_a_broken_config() {
  # 終了コードが伝わらないと、シェルからの判定（|| で分岐する使い方）が壊れる
  printf '[[actions]]\nlabel = "A"\n' > "$TMP/cfg/config.toml"
  assert_status 1 panel --check-config
}

test_check_config_uses_the_injected_config_dir() {
  valid_config
  assert_eq "$TMP/cfg/config.toml" "$(panel --check-config | head -1)"
}

test_check_config_does_not_create_a_template() {
  # 検証しに来ただけの人のディレクトリにファイルを作らない（ensure_config は
  # メニューを開く経路の担当）
  panel --check-config >/dev/null 2>&1
  [ -e "$TMP/cfg/config.toml" ] && fail "--check-config must not write a config file"
}

#-------------------------------------------------------------------------------
# --complete-dirs
#-------------------------------------------------------------------------------
test_complete_dirs_lists_child_directories() {
  mkdir -p "$TMP/tree/child"
  assert_contains "$(panel --complete-dirs "$TMP/tree/")" "child"
}

test_complete_dirs_exits_zero() {
  mkdir -p "$TMP/tree/child"
  assert_status 0 panel --complete-dirs "$TMP/tree/"
}

test_complete_dirs_emits_the_open_here_row_first() {
  mkdir -p "$TMP/tree/child"
  assert_eq "OPEN" "$(panel --complete-dirs "$TMP/tree/" | head -1 | cut -d"$TAB" -f1)"
}

test_complete_dirs_survives_a_path_that_does_not_exist() {
  # 打鍵の途中は存在しないパスになる。ここで落ちると入力欄が固まる
  assert_status 0 panel --complete-dirs "$TMP/no-such-place/at-all"
}

test_complete_dirs_accepts_an_empty_query() {
  # クエリを全消しした瞬間に呼ばれる
  assert_status 0 panel --complete-dirs ""
}

test_complete_dirs_does_not_run_the_menu() {
  # メニューへ落ちると fzf を起動しようとして、reload のたびに固まる。
  # 出力が候補の行だけであることで確認する
  mkdir -p "$TMP/tree/child"
  assert_empty "$(panel --complete-dirs "$TMP/tree/" | grep -v "^OPEN$TAB\|^UP$TAB\|^DIR$TAB" || true)"
}

run_tests
