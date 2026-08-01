#!/usr/bin/env bash
# herdr-control-panel 本体 — overlay パネル（herdr 0.7.4+）の中で動く。
# herdr の config.toml の [[keys.command]] から起動され、fzf のメニューで機能を選ぶ。
# スクリプト終了でパネルが閉じる。
#
# 思想:
#   このパネルが同梱するのは「ワークスペースを開く」だけ。それ以外の項目は
#   利用者が自分で足す。同梱物を最小にしておかないと、手元にしか無いツールを
#   前提にしたメニューを他人に押し付けることになるため。
#
# なぜ fzf か:
#   - マウスクリックで項目を選べる（gum はクリック非対応だった）
#   - fuzzy 絞り込みが効く
#   - --disabled + change:reload で「打つたびに候補が変わるパス入力欄」を作れる（Open Folder）
#
# ワークスペースの開き方は 2 通り:
#   - 履歴から選ぶ（過去に開いたディレクトリを $hist_file に記録している）
#   - Open Folder... で任意のパスを入力して開く（~/dev 配下に限定しない）
# ESC はひとつ前のメニューへ戻り、メインメニューで押すとパネルを閉じる。
#
# 利用者による項目の追加:
#   $HERDR_PLUGIN_CONFIG_DIR/config.toml に [[actions]] を書くと、メニューに並ぶ。
#   パネルの「Add action...」から選んでも同じファイルに追記される（手書きと同じ置き場）。
#   受け付ける記法は parse_actions() のサブセットのみで、それ以外は行番号付きで報告する。
#   設定が壊れていてもワークスペース機能は常に使えるようにしてある（パネルごと
#   起動しなくなるのが最悪の体験なので、設定エラーとコア機能を切り離す）。
#
# 依存: fzf（選択UI）, jq（herdr の JSON 応答パース）
#       find / grep / sed / sort / awk（候補の生成。いずれも POSIX 範囲で使う）
#       ※ lazygit 等は同梱しない。利用者が [[actions]] に足したものだけ検査する
# 制約: macOS 標準の bash 3.2 でも動くこと（連想配列・mapfile は使わない）
#
# SC2059（printf のフォーマットに変数を使うな）はこのファイルでは意図的。msg() が返す
# 文言そのものが "%s" を含むフォーマットで、呼び出し側が引数を埋める設計になっている
# （msg() のコメント参照）。文言と引数の対応を壊さずに個別 disable を 14 箇所へ散らすより、
# 設計として一度宣言するほうが読みやすいのでファイル単位で無効化する。
# shellcheck disable=SC2059
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"
# fzf の reload から自分自身を呼び直すため、$0 を絶対パスにしておく
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# 置き場は herdr がプラグインとして起動するときに環境変数で渡してくる。
# ただし herdr の [[keys.command]] type = "popup" のように「素のコマンド」として
# 呼ばれる経路では注入されないため、その場合は herdr 自身に問い合わせる。
# ここを XDG 既定へ直行させると、herdr が管理している設定を無視して別の場所を
# 読んでしまい、書いたはずの [[actions]] が並ばない事故になる。
cfg_dir="${HERDR_PLUGIN_CONFIG_DIR:-}"
if [ -z "$cfg_dir" ]; then
  cfg_dir="$("$herdr_bin" plugin config-dir herdr-control-panel 2>/dev/null)"
  # herdr が無い / 未導入のまま直接実行された場合の最後の受け皿
  [ -n "$cfg_dir" ] || cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-control-panel"
fi
# state の場所を教える CLI は無い（0.7.5 時点）。herdr と同じ規則で組み立てる
state_dir="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/herdr-control-panel}"
actions_file="$cfg_dir/config.toml"
lang_file="$cfg_dir/language"      # UI から切り替える値なので config.toml とは分けてある
hist_file="$state_dir/workspaces"
hist_max=50
dev_root="$HOME/dev"
TAB=$'\t'

# split パネル内に収める共通レイアウト。マウスは fzf の既定で有効（--no-mouse で無効化される側）。
fzf_opts=(
  --height=100%
  --layout=reverse
  --border=rounded
  --padding=1
  --prompt="> "
  --info=inline
)

# メニューの各行は "種別<TAB>表示<TAB>値" の 3 列。fzf には --with-nth=2 で表示列だけ見せ、
# 選択された行から種別と値を取り出す（表示文言を変えても分岐が壊れない）。
menu_opts=(
  --delimiter="$TAB"
  --with-nth=2
)

#-------------------------------------------------------------------------------
# 表示文言（i18n）
#-------------------------------------------------------------------------------
# herdr 本体は英語のみなので既定は en。連想配列が使えない（bash 3.2）ため case で引く。
# 変更は「🌐 Language」から。$lang_file に 1 行で保存する。
ui_lang="en"
if [ -f "$lang_file" ]; then
  read -r ui_lang < "$lang_file" 2>/dev/null || ui_lang="en"
  case "$ui_lang" in en|ja) : ;; *) ui_lang="en" ;; esac
fi

# 値を printf で直に出さず変数へ受けるのは、メッセージ自身が %s を含むものがあるため。
# printf のフォーマットとして扱うと、ここで %s が消費されて呼び出し側の引数が埋まらなくなる。
msg() {
  local m
  case "$ui_lang:$1" in
    *:header_main)      m='herdr control panel' ;;

    ja:item_new)        m='新規ワークスペース' ;;
    *:item_new)         m='New workspace' ;;
    ja:item_add)        m='＋ 機能を追加...' ;;
    *:item_add)         m='+ Add action...' ;;
    *:item_lang)        m='🌐 Language / 言語' ;;
    ja:item_cancel)     m='キャンセル' ;;
    *:item_cancel)      m='Cancel' ;;

    ja:header_ws)       m='ワークスペースを開く（履歴から選ぶ / 一番下で任意パス）' ;;
    *:header_ws)        m='Open a workspace (from history, or any path at the bottom)' ;;
    ja:browse)          m='Open Folder...  （任意のパスを入力して開く）' ;;
    *:browse)           m='Open Folder...  (type any path)' ;;
    ja:header_folder)   m='Open Folder — パスを入力して絞り込み / Enter で移動 / ▸ で確定（Ctrl-O でも確定）' ;;
    *:header_folder)    m='Open Folder — type to filter / Enter to descend / ▸ to confirm (or Ctrl-O)' ;;
    ja:open_here)       m='ここを開く' ;;
    *:open_here)        m='Open here' ;;

    ja:header_add)      m='追加する機能を選ぶ（設定ファイルに追記されます）' ;;
    *:header_add)       m='Pick an action to add (it will be appended to your config)' ;;
    ja:item_custom)     m='Custom...  （コマンドを自分で入力する）' ;;
    *:item_custom)      m='Custom...  (enter your own command)' ;;
    ja:not_installed)   m='未導入' ;;
    *:not_installed)    m='not installed' ;;
    ja:already_added)   m='追加済み' ;;
    *:already_added)    m='already added' ;;
    ja:prompt_label)    m='表示名: ' ;;
    *:prompt_label)     m='Label: ' ;;
    ja:prompt_command)  m='コマンド: ' ;;
    *:prompt_command)   m='Command: ' ;;
    ja:added)           m='追加しました' ;;
    *:added)            m='Added' ;;
    ja:add_hint)        m='設定ファイル: %s' ;;
    *:add_hint)         m='Config file: %s' ;;
    ja:need_install)    m='このコマンドが見つかりません。先に導入してください: %s' ;;
    *:need_install)     m='Command not found. Install it first: %s' ;;
    ja:header_lang)     m='言語を選択 / Select language' ;;
    *:header_lang)      m='Select language / 言語を選択' ;;

    ja:err_nodir)       m='ディレクトリがありません: %s' ;;
    *:err_nodir)        m='Directory not found: %s' ;;
    ja:err_ws)          m='ワークスペースの作成に失敗しました: %s' ;;
    *:err_ws)           m='Failed to create workspace: %s' ;;
    ja:err_missing)     m='不足:%s' ;;
    *:err_missing)      m='Missing:%s' ;;
    ja:err_run)         m='コマンドが見つかりません: %s' ;;
    *:err_run)          m='Command not found: %s' ;;
    ja:press_enter)     m='Enter で閉じる...' ;;
    *:press_enter)      m='Press Enter to close...' ;;

    ja:cfg_none)        m='まだ設定ファイルはありません（パネルを開くと雛形が作られます）' ;;
    *:cfg_none)         m='No config file yet (a template is created when you open the panel)' ;;
    ja:cfg_bad)         m='⚠ 設定に %s 件の問題があります（選ぶと詳細）' ;;
    *:cfg_bad)          m='⚠ %s problem(s) in your config (select to view)' ;;
    ja:cfg_header)      m='設定の問題 — %s' ;;
    *:cfg_header)       m='Config problems — %s' ;;

    # 設定エラーの本文。行番号は呼び出し側が付ける
    ja:e_incomplete)    m='label / command が揃っていません' ;;
    *:e_incomplete)     m='label and command are both required' ;;
    ja:e_table)         m='未知のテーブルです（使えるのは [[actions]] だけ）: %s' ;;
    *:e_table)          m='unknown table (only [[actions]] is allowed): %s' ;;
    ja:e_parse)         m='解釈できない行です: %s' ;;
    *:e_parse)          m='cannot parse this line: %s' ;;
    ja:e_outside)       m='[[actions]] の外にキーがあります: %s' ;;
    *:e_outside)        m='key outside of [[actions]]: %s' ;;
    ja:e_quote)         m='値はダブルクォートで囲んでください: %s' ;;
    *:e_quote)          m='value must be wrapped in double quotes: %s' ;;
    ja:e_inner)         m='値の中の " は使えません（シングルクォートを使ってください）: %s' ;;
    *:e_inner)          m='double quotes inside a value are not supported (use single quotes): %s' ;;
    ja:e_key)           m='未知のキーです（label / command / requires のみ）: %s' ;;
    *:e_key)            m='unknown key (only label / command / requires): %s' ;;

    *:*)                m="${1#*:}" ;;
  esac
  printf '%s' "$m"
}

#-------------------------------------------------------------------------------
# パス操作
#-------------------------------------------------------------------------------
short_path() {  # $HOME 配下を ~ 表記に縮める（表示用）
  case "$1" in
    "$HOME")   printf '~' ;;
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *)         printf '%s' "$1" ;;
  esac
}

expand_path() {  # 入力されたパスを絶対パスに正規化する（~ 展開・相対は $HOME 起点）
  local p="$1"
  # ここの "~" は「利用者が打った文字としての ~」にマッチさせるためのリテラル。
  # 展開されては困るので shellcheck の指摘（SC2088）は当たらない
  # shellcheck disable=SC2088
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="$HOME${p#\~}" ;;
  esac
  case "$p" in
    /*) : ;;
    "") p="$HOME/" ;;  # 全消ししたらホームの中身を出す
    *)  p="$HOME/$p" ;;
  esac
  printf '%s' "$p"
}

# 入力中のパスを「候補を探すディレクトリ (q_base)」と「入力途中の名前 (q_leaf)」に分ける。
# 末尾が / なら中身を、そうでなければ兄弟を候補にする（一般的なパス補完と同じ挙動）。
q_base=""
q_leaf=""
split_query() {
  local p
  p="$(expand_path "$1")"
  case "$p" in
    */) q_base="${p%/}"; q_leaf="" ;;
    *)  q_base="$(dirname "$p")"; q_leaf="$(basename "$p")" ;;
  esac
  [ -n "$q_base" ] || q_base="/"
}

# fzf の change:reload から呼ばれる候補生成。入力（{q}）に追従して毎回作り直される。
complete_dirs() {
  local query="$1" p target disp find_hidden
  split_query "$query"

  # 「ここを開く」の対象。打ち切ったパスが実在すればそれ、途中入力なら親ディレクトリ
  p="$(expand_path "$query")"
  p="${p%/}"
  [ -n "$p" ] || p="/"
  if [ -d "$p" ]; then target="$p"; else target="$q_base"; fi

  printf 'OPEN%s▸ %s: %s%s%s\n' "$TAB" "$(msg open_here)" "$(short_path "$target")" "$TAB" "$target"
  if [ "$q_base" != "/" ]; then
    p="$(dirname "$q_base")"
    printf 'UP%s../  (%s)%s%s\n' "$TAB" "$(short_path "$p")" "$TAB" "$p"
  fi

  # 隠しディレクトリは「.」を打ったときだけ出す（$HOME 直下がドットまみれになるのを避ける）
  case "$q_leaf" in
    .*) find_hidden=1 ;;
    *)  find_hidden=0 ;;
  esac
  # -H は「引数に指定したパスがシンボリックリンクなら辿る」。これが無いと /etc のような
  # リンク越しのディレクトリで候補が 1 件も出ない。子側のリンクは -type l で拾って後段の
  # [ -d ] で選り分ける（ディレクトリを指すリンクだけ残す）
  if [ "$find_hidden" = 1 ]; then
    find -H "$q_base" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -iname "*$q_leaf*" 2>/dev/null
  else
    find -H "$q_base" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -iname "*$q_leaf*" 2>/dev/null \
      | grep -v '/\.[^/]*$'
  fi | LC_ALL=C sort -f | awk -v leaf="$q_leaf" '
    # 前方一致を先、部分一致だけのものを後に並べる（パス補完としての自然さを優先）
    BEGIN { l = tolower(leaf); n = length(l) }
    { b = $0; sub(/.*\//, "", b)
      if (n == 0 || substr(tolower(b), 1, n) == l) head[++h] = $0; else tail[++t] = $0 }
    END { for (i = 1; i <= h; i++) print head[i]
          for (i = 1; i <= t; i++) print tail[i] }
  ' | while IFS= read -r d; do
    [ -d "$d" ] || continue  # ディレクトリを指さないリンク（壊れたリンク含む）は捨てる
    # 件数が多くなるのでサブシェル（short_path）は使わずインラインで縮める
    disp="$d"
    case "$disp" in
      "$HOME")   disp="~" ;;
      "$HOME"/*) disp="~${disp#"$HOME"}" ;;
    esac
    printf 'DIR%s%s/%s%s\n' "$TAB" "$disp" "$TAB" "$d"
  done
}

# （fzf の reload 経路 --complete-dirs は main で捌く。関数はここまでで揃っている）

#-------------------------------------------------------------------------------
# 利用者定義のアクション（$actions_file）
#-------------------------------------------------------------------------------
# 受け付ける記法は下のテンプレートに書いたサブセットだけ。TOML の全文法は解さない
# （bash に TOML パーサが無いため、フル実装は自作パーサのバグ源になる）。
# 想定外の記法は黙って無視せず、行番号を添えて報告する。
CFG_TEMPLATE_EN='# herdr-control-panel — actions
#
# Each [[actions]] block adds one item to the panel. The panel itself ships only
# with "New workspace"; everything else is yours to add here.
#
# Accepted syntax (anything else is reported as an error with its line number):
#
#   [[actions]]          start of a block (required)
#   label   = "..."      name shown in the panel   (required, double quotes)
#   command = "..."      shell command to run      (required, double quotes)
#   requires = "..."     command that must exist   (optional)
#
# Notes:
#   - If "requires" is omitted, the first word of "command" is checked instead.
#   - "command" is run by a shell, so pipes and arguments work. Use single
#     quotes inside, e.g. command = "sh -c '\''ls | less'\''"
#   - Escapes such as \" inside a value are NOT supported. Use single quotes.
#   - The language of this panel is switched from its "Language" menu entry.
#
# Example:
#
#   [[actions]]
#   label   = "Lazygit"
#   command = "lazygit"
'
CFG_TEMPLATE_JA='# herdr-control-panel — actions
#
# [[actions]] ブロック 1 つがパネルの項目 1 つになる。パネルが最初から持つのは
# 「新規ワークスペース」だけで、それ以外はここに自分で足す。
#
# 受け付ける記法は以下だけ（それ以外は行番号を添えてエラーとして報告される）:
#
#   [[actions]]          ブロックの開始（必須）
#   label   = "..."      パネルに表示する名前（必須・ダブルクォート）
#   command = "..."      実行するコマンド（必須・ダブルクォート）
#   requires = "..."     存在確認するコマンド名（任意）
#
# 補足:
#   - requires を省略した場合は command の先頭の語を確認する。
#   - command はシェルで実行されるのでパイプや引数が使える。内側では
#     シングルクォートを使うこと。例: command = "sh -c '\''ls | less'\''"
#   - 値の中の \" のようなエスケープには対応していない。シングルクォートを使うこと。
#   - このパネルの言語は「Language」の項目から切り替える。
#
# 例:
#
#   [[actions]]
#   label   = "Lazygit"
#   command = "lazygit"
'

ensure_config() {  # 初回だけテンプレートを書き出す（仕様書をファイル自身に同梱する）
  [ -f "$actions_file" ] && return 0
  mkdir -p "$cfg_dir" 2>/dev/null || return 0
  if [ "$ui_lang" = ja ]; then
    printf '%s' "$CFG_TEMPLATE_JA" > "$actions_file" 2>/dev/null || return 0
  else
    printf '%s' "$CFG_TEMPLATE_EN" > "$actions_file" 2>/dev/null || return 0
  fi
}

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# $actions_file を読み、2 種類の行を stdout に混ぜて返す:
#   ACT<TAB>label<TAB>command<TAB>requires   … 有効なアクション
#   ERR<TAB>L<行番号>: 本文                   … 解釈できなかった箇所
# 変数ではなく stdout で返すのは、呼び出し側がコマンド置換（＝サブシェル）で受けるため。
# サブシェルの中でグローバル変数へ積んでも親プロセスには戻らない。
# 戻り値は常に 0（設定が壊れていてもパネルは開けなければならない）。
parse_actions() {
  local line lineno=0 in_block=0 label="" command="" requires="" key val block_line=0

  emit_err() { printf 'ERR%sL%s: %s\n' "$TAB" "$1" "$2"; }

  flush_block() {  # ブロック 1 つ分を検証して出力する
    [ "$in_block" = 1 ] || return 0
    if [ -z "$label" ] || [ -z "$command" ]; then
      emit_err "$block_line" "$(msg e_incomplete)"
    else
      printf 'ACT%s%s%s%s%s%s\n' "$TAB" "$label" "$TAB" "$command" "$TAB" "$requires"
    fi
    label=""; command=""; requires=""
  }

  [ -f "$actions_file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="$(trim "$line")"
    case "$line" in
      ''|'#'*) continue ;;
      '[[actions]]')
        flush_block
        in_block=1
        block_line=$lineno
        continue
        ;;
      '['*)
        emit_err "$lineno" "$(printf "$(msg e_table)" "$line")"
        continue
        ;;
    esac

    case "$line" in
      *=*) : ;;
      *)
        emit_err "$lineno" "$(printf "$(msg e_parse)" "$line")"
        continue
        ;;
    esac

    key="$(trim "${line%%=*}")"
    val="$(trim "${line#*=}")"

    if [ "$in_block" != 1 ]; then
      emit_err "$lineno" "$(printf "$(msg e_outside)" "$key")"
      continue
    fi

    # 値はダブルクォート囲みのみ。中に " を含む形（エスケープ）は未対応と割り切る
    case "$val" in
      '"'*'"') val="${val#\"}"; val="${val%\"}" ;;
      *)
        emit_err "$lineno" "$(printf "$(msg e_quote)" "$key")"
        continue
        ;;
    esac
    case "$val" in
      *'"'*)
        emit_err "$lineno" "$(printf "$(msg e_inner)" "$key")"
        continue
        ;;
    esac

    case "$key" in
      label)    label="$val" ;;
      command)  command="$val" ;;
      requires) requires="$val" ;;
      *)
        emit_err "$lineno" "$(printf "$(msg e_key)" "$key")"
        ;;
    esac
  done < "$actions_file"

  flush_block
  return 0
}

# parse_actions の出力から片方の種別だけを取り出す
only_kind() { printf '%s\n' "$1" | grep "^$2$TAB" || true; }

# エラーは解析順（ブロックの完了判定が後回しになる）で出るため、読む順序に合わせて
# 行番号で並べ直す。"L12: ..." の L の次から数値として比較する
sort_errors() { sort -t: -k1.2n; }

# requires が空なら command の先頭の語を見る（大半の項目は label と command の 2 行で済む）
requirement_of() {
  local command="$1" requires="$2"
  if [ -n "$requires" ]; then printf '%s' "$requires"; else printf '%s' "${command%% *}"; fi
}

# 設定の検証だけを行う経路（--check-config）。[[actions]] を書いたあとにパネルを開かず確認できる。
# 問題があれば非ゼロを返すので、シェルからそのまま判定に使える。
check_config() {
  local parsed acts errs
  parsed="$(parse_actions)"
  acts="$(only_kind "$parsed" ACT)"
  errs="$(only_kind "$parsed" ERR | cut -d"$TAB" -f2- | sort_errors)"
  printf '%s\n' "$actions_file"
  if [ ! -f "$actions_file" ]; then
    printf '  %s\n' "$(msg cfg_none)"
    return 0
  fi
  if [ -n "$acts" ]; then
    printf '%s\n' "$acts" | while IFS="$TAB" read -r _ l c r; do
      printf '  ok   %s -> %s%s\n' "$l" "$c" "${r:+ [requires: $r]}"
    done
  fi
  if [ -n "$errs" ]; then
    printf '%s\n' "$errs" | while IFS= read -r e; do printf '  ERR  %s\n' "$e"; done
    return 1
  fi
  return 0
}

#-------------------------------------------------------------------------------
# 履歴
#-------------------------------------------------------------------------------
add_history() {  # 開いたディレクトリを先頭に積む（重複は除去、$hist_max 件で打ち切り）
  local dir="$1" tmp
  mkdir -p "$(dirname "$hist_file")" || return 0
  tmp="$hist_file.$$"
  # 末尾の `:` は必須。grep が 1 を返すと pipefail でパイプライン全体が失敗扱いになり、
  # 履歴が保存されなくなる（初回や、履歴が $dir 1 件だけのときに起きる）
  {
    printf '%s\n' "$dir"
    if [ -f "$hist_file" ]; then grep -vxF -- "$dir" "$hist_file"; fi
    :
  } | head -n "$hist_max" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then
    mv "$tmp" "$hist_file"
  else
    rm -f "$tmp"
  fi
}

list_history() {  # 存在するものだけを行フォーマットで出す
  local d disp
  [ -f "$hist_file" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    disp="$d"
    case "$disp" in
      "$HOME")   disp="~" ;;
      "$HOME"/*) disp="~${disp#"$HOME"}" ;;
    esac
    printf 'HIST%s%s%s%s\n' "$TAB" "$disp" "$TAB" "$d"
  done < "$hist_file"
}

#-------------------------------------------------------------------------------
# ワークスペース
#-------------------------------------------------------------------------------
pause_error() {  # パネルは終了と同時に閉じるので、エラーは読ませてから閉じる
  printf '%s\n' "$*" >&2
  printf '%s' "$(msg press_enter)" >&2
  read -r _ || true
}

open_workspace() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    pause_error "$(printf "$(msg err_nodir)" "$dir")"
    return 1
  fi
  if ! "$herdr_bin" workspace create --cwd "$dir" --label "$(basename "$dir")" --focus; then
    pause_error "$(printf "$(msg err_ws)" "$dir")"
    return 1
  fi
  add_history "$dir"
}

# 任意パスを選ぶ UI。fzf 自身の絞り込みは切り（--disabled）、入力をそのままパスとして扱う。
# Enter でディレクトリを降りる（クエリを差し替えて開き直す）、OPEN 行 / Ctrl-O で確定。
# 選んだパスを stdout に返す。キャンセルは非ゼロ。
pick_folder() {
  local q="$1" out st query key sel kind path target
  while :; do
    out=$(complete_dirs "$q" | fzf "${fzf_opts[@]}" "${menu_opts[@]}" \
      --disabled \
      --query="$q" \
      --print-query \
      --expect=ctrl-o \
      --prompt="path> " \
      --bind="change:reload(bash \"$self\" --complete-dirs {q})" \
      --header="$(msg header_folder)")
    st=$?
    # ESC や中断はキャンセル。--print-query があるので終了コード 1（候補なし）は続行できる
    [ "$st" -ge 130 ] && return 1

    { IFS= read -r query; IFS= read -r key; IFS= read -r sel; } <<EOF
$out
EOF
    kind="${sel%%"$TAB"*}"
    path="${sel##*"$TAB"}"

    if [ "$key" = "ctrl-o" ]; then
      target="$(expand_path "$query")"
      target="${target%/}"
      [ -n "$target" ] || target="/"
      if [ -d "$target" ]; then
        printf '%s' "$target"
        return 0
      fi
    fi

    case "$kind" in
      OPEN)   printf '%s' "$path"; return 0 ;;
      UP|DIR) q="$path/" ;;
      *)      return 1 ;;
    esac
  done
}

# 履歴 + Open Folder のメニュー。選んだパスを stdout に返す。キャンセルは非ゼロ。
choose_workspace() {
  local list sel kind path start
  # ブラウザの初期位置。~/dev があればそこから（従来どおり数キーでプロジェクトに届く）
  if [ -d "$dev_root" ]; then start="$dev_root/"; else start="$HOME/"; fi

  list=$(list_history)
  # 履歴がまだ無いときはメニューを挟まず、そのままパス入力へ
  if [ -z "$list" ]; then
    pick_folder "$start"
    return $?
  fi

  sel=$(
    printf '%s\n' "$list"
    printf 'BROWSE%s%s%s\n' "$TAB" "$(msg browse)" "$TAB"
  ) || return 1
  sel=$(printf '%s\n' "$sel" | fzf "${fzf_opts[@]}" "${menu_opts[@]}" \
        --header="$(msg header_ws)") || return 1

  kind="${sel%%"$TAB"*}"
  path="${sel##*"$TAB"}"
  case "$kind" in
    HIST)   printf '%s' "$path"; return 0 ;;
    BROWSE) pick_folder "$start"; return $? ;;
    *)      return 1 ;;
  esac
}

#-------------------------------------------------------------------------------
# 機能の追加（Add action...）
#-------------------------------------------------------------------------------
# 同梱カタログ。"表示名<TAB>コマンド<TAB>存在確認" の 3 列で、確認は
#   cmd:NAME     … PATH 上に NAME があるか
#   plugin:ID    … herdr に ID のプラグインが入っているか
# 少数の例に留めてあるのは、ここを充実させるほど各ツールの仕様変更に追従する
# 義務が増えるため。任意のコマンドは Custom... から足せる。
catalog() {
  printf 'Lazygit%slazygit%scmd:lazygit\n' "$TAB" "$TAB"
  printf 'File viewer%sherdr plugin action invoke open-file-viewer --plugin herdr-file-viewer%splugin:herdr-file-viewer\n' "$TAB" "$TAB"
  printf 'System monitor (btop)%sbtop%scmd:btop\n' "$TAB" "$TAB"
  printf 'Disk usage (ncdu)%sncdu%scmd:ncdu\n' "$TAB" "$TAB"
}

have_requirement() {  # cmd:NAME / plugin:ID / 素のコマンド名 / 空
  case "$1" in
    '')        return 0 ;;
    cmd:*)     command -v "${1#cmd:}" >/dev/null 2>&1 ;;
    plugin:*)  "$herdr_bin" plugin list 2>/dev/null | grep -qF -- "${1#plugin:}" ;;
    *)         command -v "$1" >/dev/null 2>&1 ;;
  esac
}

append_action() {  # $actions_file に 1 ブロック追記する
  local label="$1" command="$2"
  mkdir -p "$cfg_dir" 2>/dev/null || return 1
  {
    printf '\n[[actions]]\n'
    printf 'label   = "%s"\n' "$label"
    printf 'command = "%s"\n' "$command"
  } >> "$actions_file" || return 1
}

# 入力を 1 行受け取る。fzf の --print-query を入力欄として流用する（パネル内で
# read すると overlay の描画と競合するため、UI は fzf に統一している）。
ask_line() {
  local prompt="$1" out
  out=$(printf '' | fzf "${fzf_opts[@]}" --print-query --disabled --prompt="$prompt" \
        --header="$(msg header_add)" 2>/dev/null | head -1)
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

add_action_flow() {
  local sel label command req added_labels line disp
  added_labels="$(only_kind "$(parse_actions)" ACT | cut -d"$TAB" -f2)"

  sel=$(
    catalog | while IFS="$TAB" read -r label command req; do
      disp="$label"
      if printf '%s\n' "$added_labels" | grep -qxF -- "$label"; then
        disp="$disp  ($(msg already_added))"
      elif ! have_requirement "$req"; then
        disp="$disp  ($(msg not_installed))"
      fi
      printf 'CAT%s%s%s%s%s%s\n' "$TAB" "$disp" "$TAB" "$label" "$TAB" "$command"
    done
    printf 'CUSTOM%s%s%s%s\n' "$TAB" "$(msg item_custom)" "$TAB" ""
  ) || return 1
  sel=$(printf '%s\n' "$sel" | fzf "${fzf_opts[@]}" --delimiter="$TAB" --with-nth=2 \
        --header="$(msg header_add)") || return 1

  case "${sel%%"$TAB"*}" in
    CUSTOM)
      label=$(ask_line "$(msg prompt_label)") || return 1
      command=$(ask_line "$(msg prompt_command)") || return 1
      ;;
    CAT)
      # "CAT<TAB>表示<TAB>label<TAB>command" から後ろ 2 列を取る
      label=$(printf '%s' "$sel" | cut -d"$TAB" -f3)
      command=$(printf '%s' "$sel" | cut -d"$TAB" -f4-)
      ;;
    *) return 1 ;;
  esac

  [ -n "$label" ] && [ -n "$command" ] || return 1

  # 値の中の " は解釈できない記法なので、書き込む前に弾く（壊れた設定を自分で作らない）
  case "$label$command" in
    *'"'*) pause_error 'Values must not contain double quotes.'; return 1 ;;
  esac

  if ! have_requirement "${command%% *}"; then
    pause_error "$(printf "$(msg need_install)" "${command%% *}")"
  fi

  if append_action "$label" "$command"; then
    pause_error "$(msg added): $label
$(printf "$(msg add_hint)" "$actions_file")"
  fi
}

#-------------------------------------------------------------------------------
# 言語切り替え
#-------------------------------------------------------------------------------
language_flow() {
  local sel
  sel=$(
    printf 'en%sEnglish%s\n' "$TAB" "$TAB"
    printf 'ja%s日本語%s\n' "$TAB" "$TAB"
  ) || return 1
  sel=$(printf '%s\n' "$sel" | fzf "${fzf_opts[@]}" "${menu_opts[@]}" \
        --header="$(msg header_lang)") || return 1
  sel="${sel%%"$TAB"*}"
  case "$sel" in
    en|ja)
      mkdir -p "$cfg_dir" 2>/dev/null || return 1
      printf '%s\n' "$sel" > "$lang_file" 2>/dev/null || return 1
      ui_lang="$sel"
      ;;
  esac
}

#-------------------------------------------------------------------------------
# 依存チェック（無ければ案内して閉じる）
#-------------------------------------------------------------------------------
require_deps() {
  local missing="" install_hint
  command -v fzf >/dev/null 2>&1 || missing="$missing fzf"
  command -v jq  >/dev/null 2>&1 || missing="$missing jq"
  [ -n "$missing" ] || return 0
  case "$(uname -s)" in
    Darwin) install_hint="brew install$missing" ;;
    *)      install_hint="sudo apt install -y$missing" ;;
  esac
  printf "$(msg err_missing)\n  %s\n" "$missing" "$install_hint" >&2
  pause_error ""
  return 1
}

# 履歴を XDG_STATE_HOME 直下に置いていた頃のものを、herdr の STATE_DIR へ一度だけ移す。
# v0.1 の既定がそこだったのに加え、v0.2.0 までは popup 起動時のフォールバック先も
# そこだったため、環境変数の無い経路で使っていた履歴がここで引き継がれる
# （両者が同じパスに解決される環境では [ -f "$hist_file" ] が真になり、何も起きない）
migrate_legacy_history() {
  local legacy_hist="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-control-panel/workspaces"
  [ ! -f "$hist_file" ] && [ -f "$legacy_hist" ] || return 0
  mkdir -p "$(dirname "$hist_file")" 2>/dev/null && cp "$legacy_hist" "$hist_file" 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# メインメニュー
#-------------------------------------------------------------------------------
# 同梱項目は「新規ワークスペース」だけ。利用者が [[actions]] に足したものがその下に並ぶ。
# ESC はひとつ前のメニューに戻る（ここで ESC ならパネルを閉じる）。
main_menu() {
  local parsed actions cfg_errors action dir cmd
  while :; do
    parsed="$(parse_actions)"
    actions="$(only_kind "$parsed" ACT)"
    cfg_errors="$(only_kind "$parsed" ERR | cut -d"$TAB" -f2- | sort_errors)"

    action=$(
      printf 'NEW%s%s%s\n' "$TAB" "$(msg item_new)" "$TAB"
      if [ -n "$actions" ]; then
        printf '%s\n' "$actions" | while IFS="$TAB" read -r _ label command requires; do
          [ -n "$label" ] || continue
          if have_requirement "$(requirement_of "$command" "$requires")"; then
            printf 'RUN%s%s%s%s\n' "$TAB" "$label" "$TAB" "$command"
          else
            printf 'RUN%s%s  (%s)%s%s\n' "$TAB" "$label" "$(msg not_installed)" "$TAB" "$command"
          fi
        done
      fi
      printf 'ADD%s%s%s\n' "$TAB" "$(msg item_add)" "$TAB"
      printf 'LANG%s%s%s\n' "$TAB" "$(msg item_lang)" "$TAB"
      if [ -n "$cfg_errors" ]; then
        printf 'CFGERR%s%s%s\n' "$TAB" "$(printf "$(msg cfg_bad)" "$(printf '%s\n' "$cfg_errors" | wc -l | tr -d ' ')")" "$TAB"
      fi
      printf 'QUIT%s%s%s\n' "$TAB" "$(msg item_cancel)" "$TAB"
    ) || return 0
    action=$(printf '%s\n' "$action" | fzf "${fzf_opts[@]}" "${menu_opts[@]}" \
             --header="$(msg header_main)") || return 0

    case "${action%%"$TAB"*}" in
      NEW)
        dir=$(choose_workspace) || continue   # ワークスペース選択で ESC → このメニューへ
        [ -n "${dir:-}" ] || continue
        open_workspace "$dir" || return 1
        return 0
        ;;

      RUN)
        # 利用者が [[actions]] に書いたコマンド。シェルで実行する（パイプや引数を許すため）
        cmd="${action##*"$TAB"}"
        [ -n "$cmd" ] || continue
        if ! have_requirement "${cmd%% *}"; then
          pause_error "$(printf "$(msg err_run)" "${cmd%% *}")"
          continue
        fi
        exec bash -c "$cmd"
        ;;

      ADD)
        add_action_flow || true
        continue
        ;;

      LANG)
        language_flow || true
        continue
        ;;

      CFGERR)
        printf '%s\n\n%s\n' "$(printf "$(msg cfg_header)" "$actions_file")" "$cfg_errors" >&2
        pause_error ""
        continue
        ;;

      *)
        return 0
        ;;
    esac
  done
}

#-------------------------------------------------------------------------------
# エントリポイント
#-------------------------------------------------------------------------------
# 直接実行されたときだけ走らせる。source した場合は関数定義だけが読み込まれる
# （テストから個々の関数を呼べるようにするため。bash の __main__ 相当のイディオム）。
main() {
  case "${1:-}" in
    # fzf の reload から呼ばれる候補生成。メニューを出さず候補だけ吐いて終わる
    --complete-dirs) complete_dirs "${2:-}"; return 0 ;;
    --check-config)  check_config; return $? ;;
  esac

  require_deps || return 1
  ensure_config
  migrate_legacy_history
  main_menu
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
