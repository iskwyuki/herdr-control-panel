#!/usr/bin/env bash
# 静的チェック。動かさなくても分かる壊れ方をここで止める。
#
# 特に bash 3.2 互換は「macOS で動かすまで気づかない」種類の事故なので、構文の
# 混入を機械的に弾いておく。実際に 3.2 で走らせる確認は CI の macOS ランナーが担当。

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ROOT="$LIB_DIR/.."

all_scripts() { ls "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; }

#-------------------------------------------------------------------------------
# 構文
#-------------------------------------------------------------------------------
test_every_script_parses() {
  local f
  for f in $(all_scripts); do
    bash -n "$f" 2>/dev/null || fail "syntax error: ${f#$ROOT/}"
  done
}

test_uses_no_bash_four_only_syntax() {
  # 連想配列・mapfile・大文字小文字変換・|& は bash 4.0 以降。macOS の /bin/bash は 3.2。
  # このファイル自身はパターン定義で引っかかるので対象から外し、他のファイルでも
  # コメント行は見ない（「mapfile は使わない」という説明文で誤検出するため）
  local f hits
  for f in $(all_scripts | grep -v 'test_lint\.sh$'); do
    hits="$(grep -nE 'declare -A|local -A|mapfile |readarray |\$\{[A-Za-z_]+\^\^|\$\{[A-Za-z_]+,,|\|&|;;&' "$f" \
            | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    [ -z "$hits" ] || fail "bash 4 only syntax in ${f#$ROOT/}: $hits"
  done
}

test_every_script_uses_the_env_shebang() {
  # /bin/bash 直指定にすると、bash が別の場所にある環境で動かなくなる
  local f
  for f in $(all_scripts); do
    [ "$(head -1 "$f")" = "#!/usr/bin/env bash" ] || fail "bad shebang: ${f#$ROOT/}"
  done
}

test_entry_point_scripts_are_executable() {
  local f
  for f in "$ROOT"/scripts/*.sh; do
    [ -x "$f" ] || fail "not executable: ${f#$ROOT/}"
  done
}

#-------------------------------------------------------------------------------
# マニフェストと実体の整合
#-------------------------------------------------------------------------------
test_manifest_references_existing_scripts() {
  # herdr-plugin.toml が指すファイルが無いと、導入した人の環境で初めて失敗する
  local rel
  for rel in $(grep -o '"[^"]*\.sh"' "$ROOT/herdr-plugin.toml" | tr -d '"' | sort -u); do
    [ -f "$ROOT/$rel" ] || fail "manifest points at a missing file: $rel"
  done
}

test_manifest_declares_a_semver_version() {
  local v
  v="$(grep '^version' "$ROOT/herdr-plugin.toml" | sed 's/.*= *"\(.*\)"/\1/')"
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) fail "version is not semver: [$v]" ;;
  esac
}

test_manifest_and_readme_agree_on_the_install_target() {
  # README の導入コマンドが別のリポジトリを指していたら誰も入れられない
  assert_contains "$(cat "$ROOT/README.md")" "herdr plugin install iskwyuki/herdr-control-panel"
  assert_contains "$(cat "$ROOT/README.ja.md")" "herdr plugin install iskwyuki/herdr-control-panel"
}

test_the_plugin_id_matches_the_one_the_panel_asks_herdr_for() {
  # panel.sh は config-dir を自力で引くときに ID を直書きする。ここがずれると
  # 環境変数の無い経路だけ別の設定を読む（v0.2.0 と同じ形の事故になる）
  local id
  # [[panes]] や [[actions]] にも id があるので、最初のテーブルより前だけを見る
  id="$(sed -n '/^\[\[/q; /^id/p' "$ROOT/herdr-plugin.toml" | sed 's/.*= *"\(.*\)"/\1/')"
  assert_contains "$(cat "$ROOT/scripts/panel.sh")" "plugin config-dir $id"
}

#-------------------------------------------------------------------------------
# 静的解析（導入されていれば）
#-------------------------------------------------------------------------------
# 検査するのは配布物である scripts/ だけ。tests/ は panel.sh を source して
# そのグローバル変数を触る構造上、SC2034 / SC2154 が大量に出るので対象外にしている
# （抑制コメントで埋めるほうが読みにくい）。
test_shellcheck_is_clean() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '      (shellcheck not installed — skipped)\n'
    return 0
  fi
  local out
  out="$(shellcheck "$ROOT"/scripts/*.sh 2>&1 || true)"
  assert_empty "$out"
}

run_tests
