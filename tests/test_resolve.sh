#!/usr/bin/env bash
# 起動時に「どこの設定と履歴を使うか」を決める部分のテスト。
#
# これは v0.2.0 で実際に事故った箇所の回帰テスト。herdr の popup 経由で起動すると
# HERDR_PLUGIN_CONFIG_DIR が注入されず、XDG 既定へ直行していたため、herdr が管理して
# いる設定（利用者が [[actions]] を書いた先）が丸ごと無視されていた。
#
# 解決は panel.sh を読み込んだ時点で確定するので、環境ごとに別プロセスで確かめる。

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

setup() {
  mkdir -p "$TMP/bin"
  # herdr だけが無い PATH。標準のコマンド（dirname 等）は残す＝未導入の環境の再現
  NO_HERDR_PATH="$TMP/bin:/bin:/usr/bin"
}

# panel.sh を指定の環境で読み込み、変数の値を 1 つ取り出す。
# PATH を差し替えるテストがあるので bash は絶対パスで起動する
resolve() {  # resolve <変数名> <env に渡す設定...>
  local var="$1"
  shift
  env "$@" /bin/bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${!2}"' _ "$PANEL" "$var"
}

# config-dir にだけ答える偽の herdr
fake_herdr() {  # fake_herdr <答えるパス>
  printf '#!/bin/sh\n[ "$1" = plugin ] && [ "$2" = config-dir ] && printf "%%s\\n" "%s"\n' "$1" \
    > "$TMP/bin/herdr"
  chmod +x "$TMP/bin/herdr"
}

#-------------------------------------------------------------------------------
# 設定ディレクトリ
#-------------------------------------------------------------------------------
test_prefers_the_config_dir_injected_by_herdr() {
  assert_eq "/injected" "$(resolve cfg_dir HERDR_PLUGIN_CONFIG_DIR=/injected)"
}

test_asks_herdr_when_the_environment_is_missing() {
  # popup 経由（環境変数なし）で踏む経路。ここが XDG へ直行すると設定が無視される
  fake_herdr "/from-herdr"
  assert_eq "/from-herdr" \
    "$(resolve cfg_dir -u HERDR_PLUGIN_CONFIG_DIR "PATH=$TMP/bin:$PATH")"
}

test_falls_back_to_xdg_when_herdr_cannot_answer() {
  printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/herdr"
  chmod +x "$TMP/bin/herdr"
  assert_eq "/xdg/herdr-control-panel" \
    "$(resolve cfg_dir -u HERDR_PLUGIN_CONFIG_DIR XDG_CONFIG_HOME=/xdg "PATH=$TMP/bin:$PATH")"
}

test_falls_back_to_xdg_when_herdr_is_not_installed() {
  assert_eq "/xdg/herdr-control-panel" \
    "$(resolve cfg_dir -u HERDR_PLUGIN_CONFIG_DIR XDG_CONFIG_HOME=/xdg "PATH=$NO_HERDR_PATH")"
}

test_uses_the_home_default_when_xdg_is_unset() {
  assert_eq "$HOME/.config/herdr-control-panel" \
    "$(resolve cfg_dir -u HERDR_PLUGIN_CONFIG_DIR -u XDG_CONFIG_HOME "PATH=$NO_HERDR_PATH")"
}

test_does_not_call_herdr_when_the_environment_is_present() {
  # 環境変数があるのに herdr を呼ぶと、パネルを開くたびに無駄な起動が挟まる
  printf '#!/bin/sh\ntouch "%s/called"\n' "$TMP" > "$TMP/bin/herdr"
  chmod +x "$TMP/bin/herdr"
  resolve cfg_dir HERDR_PLUGIN_CONFIG_DIR=/injected "PATH=$TMP/bin:$PATH" >/dev/null
  [ -f "$TMP/called" ] && fail "herdr must not be called when the environment is set"
}

#-------------------------------------------------------------------------------
# 状態ディレクトリ（履歴の置き場）
#-------------------------------------------------------------------------------
test_prefers_the_state_dir_injected_by_herdr() {
  assert_eq "/injected" "$(resolve state_dir HERDR_PLUGIN_STATE_DIR=/injected)"
}

test_derives_the_state_dir_the_way_herdr_does() {
  # herdr は state を教える CLI を持たないので、同じ規則で組み立てる。
  # ここが herdr 側とずれると、経路によって履歴が別の場所に溜まる
  assert_eq "/xdg/herdr/plugins/herdr-control-panel" \
    "$(resolve state_dir -u HERDR_PLUGIN_STATE_DIR XDG_STATE_HOME=/xdg)"
}

test_uses_the_home_default_for_state_when_xdg_is_unset() {
  assert_eq "$HOME/.local/state/herdr/plugins/herdr-control-panel" \
    "$(resolve state_dir -u HERDR_PLUGIN_STATE_DIR -u XDG_STATE_HOME)"
}

#-------------------------------------------------------------------------------
# 派生するファイル名
#-------------------------------------------------------------------------------
test_puts_the_config_file_inside_the_config_dir() {
  assert_eq "/injected/config.toml" "$(resolve config_file HERDR_PLUGIN_CONFIG_DIR=/injected)"
}

test_keeps_the_language_file_beside_the_config() {
  # UI から切り替える値なので config.toml とは別ファイルにしてある
  assert_eq "/injected/language" "$(resolve lang_file HERDR_PLUGIN_CONFIG_DIR=/injected)"
}

test_puts_the_history_inside_the_state_dir() {
  assert_eq "/injected/workspaces" "$(resolve hist_file HERDR_PLUGIN_STATE_DIR=/injected)"
}

#-------------------------------------------------------------------------------
# 言語
#-------------------------------------------------------------------------------
test_defaults_to_english() {
  assert_eq "en" "$(resolve ui_lang "HERDR_PLUGIN_CONFIG_DIR=$TMP/empty")"
}

test_reads_the_saved_language() {
  mkdir -p "$TMP/cfg"
  printf 'ja\n' > "$TMP/cfg/language"
  assert_eq "ja" "$(resolve ui_lang "HERDR_PLUGIN_CONFIG_DIR=$TMP/cfg")"
}

test_ignores_an_unknown_language() {
  mkdir -p "$TMP/cfg"
  printf 'klingon\n' > "$TMP/cfg/language"
  assert_eq "en" "$(resolve ui_lang "HERDR_PLUGIN_CONFIG_DIR=$TMP/cfg")"
}

test_ignores_an_empty_language_file() {
  mkdir -p "$TMP/cfg"
  : > "$TMP/cfg/language"
  assert_eq "en" "$(resolve ui_lang "HERDR_PLUGIN_CONFIG_DIR=$TMP/cfg")"
}

run_tests
