#!/usr/bin/env bash
# 依存ゼロのテストハーネス。
#
# bats-core を使っていないのは、このプラグイン自体が「入れるのに何も要らない」ことを
# 売りにしているため。テストのためだけに利用者と無関係な依存を足すのは筋が悪い。
# ハーネス自身も bash 3.2 で動く（テスト対象と同じ制約に置く）。
#
# 使い方:
#   . "$(dirname "$0")/lib.sh"     # これで panel.sh の関数が全部呼べる状態になる
#   test_something() { assert_eq "want" "$(some_function)"; }
#   run_tests
#
# 各 test_* は独立した一時ディレクトリ $TMP を持ち、終了時に消される。

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 差し替え可能にしてあるのは、わざと壊した版を食わせて「テストが落ちること」を
# 確かめられるようにするため（テストが何も検証していない状態を防ぐ）
PANEL="${PANEL_UNDER_TEST:-$LIB_DIR/../scripts/panel.sh}"
NL='
'

# panel.sh は source した時点で cfg_dir / state_dir を確定させる。実環境
# （~/.config 配下や herdr への問い合わせ）に触らせないよう、先に砂場を渡しておく。
# 個々のテストは actions_file / hist_file を $TMP 配下へ差し替えて使う。
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hcp-sandbox.XXXXXX")"
export HERDR_PLUGIN_CONFIG_DIR="$SANDBOX/config"
export HERDR_PLUGIN_STATE_DIR="$SANDBOX/state"
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR" "$HERDR_PLUGIN_STATE_DIR"

# shellcheck source=../scripts/panel.sh
. "$PANEL"

ui_lang=en   # 文言比較を英語に固定する。ja は i18n のテストで明示的に切り替える

_pass=0
_fail=0
_current=""
_failed_now=0

_cleanup() { rm -rf "$SANDBOX" "${TMP:-}"; }
trap _cleanup EXIT

#-------------------------------------------------------------------------------
# アサーション
#-------------------------------------------------------------------------------
_show() {  # _show <ラベル> <値>  ※ 複数行の値は行頭に | を付けて並べる
  case "$2" in
    *"$NL"*)
      printf '      %s:\n' "$1"
      printf '%s\n' "$2" | sed 's/^/        | /'
      ;;
    *) printf '      %s: [%s]\n' "$1" "$2" ;;
  esac
}

_report() {  # _report <見出し> [補足行...]
  if [ "$_failed_now" = 0 ]; then
    printf '  \033[31m✗\033[0m %s\n' "$_current"
  fi
  _failed_now=1
  printf '      %s\n' "$1"
  shift
  while [ "$#" -gt 0 ]; do printf '%s\n' "$1"; shift; done
}

assert_eq() {  # assert_eq <期待> <実際> [説明]
  [ "$1" = "$2" ] && return 0
  _report "${3:-values differ}" "$(_show expected "$1")" "$(_show actual "$2")"
}

assert_contains() {  # assert_contains <対象> <部分文字列> [説明]
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  _report "${3:-substring not found}" "$(_show wanted "$2")" "$(_show haystack "$1")"
}

assert_not_contains() {
  case "$1" in
    *"$2"*) _report "${3:-substring should be absent}" "$(_show unwanted "$2")" "$(_show haystack "$1")" ;;
  esac
}

assert_status() {  # assert_status <期待する終了コード> <コマンド...>
  local want="$1" got
  shift
  "$@" >/dev/null 2>&1
  got=$?
  [ "$want" = "$got" ] && return 0
  _report "exit status differs for: $*" "$(_show expected "$want")" "$(_show actual "$got")"
}

assert_empty() {  # assert_empty <値> [説明]
  [ -z "$1" ] && return 0
  _report "${2:-expected empty}" "$(_show actual "$1")"
}

fail() { _report "$1"; }

#-------------------------------------------------------------------------------
# ランナー
#-------------------------------------------------------------------------------
# test_ で始まる関数を名前順に実行する。定義順ではないので、テスト間の順序に
# 依存した書き方はしないこと（各テストは $TMP ごと作り直される）。
run_tests() {
  local t
  printf '\033[1m%s\033[0m\n' "$(basename "$0")"
  for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
    _current="$(printf '%s' "${t#test_}" | tr '_' ' ')"
    _failed_now=0
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/hcp-case.XXXXXX")"
    if command -v setup >/dev/null 2>&1; then setup; fi
    "$t"
    rm -rf "$TMP"
    if [ "$_failed_now" = 0 ]; then
      _pass=$((_pass + 1))
      printf '  \033[32m✓\033[0m %s\n' "$_current"
    else
      _fail=$((_fail + 1))
    fi
  done
  printf '  %s passed, %s failed\n\n' "$_pass" "$_fail"
  [ "$_fail" = 0 ]
}
