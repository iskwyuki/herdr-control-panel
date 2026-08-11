# herdr-control-panel

[![test](https://github.com/iskwyuki/herdr-control-panel/actions/workflows/test.yml/badge.svg)](https://github.com/iskwyuki/herdr-control-panel/actions/workflows/test.yml)

キーひとつ、パネルひとつ。ワークスペースを履歴または任意のパスから開き、忘れたショートカットを引き、
同じメニューに自分の項目を足せる。

[herdr](https://herdr.dev) のプラグイン。bash と fzf だけで動き、ビルドは要らない。

English README: [README.md](README.md)

```
┌──────────────────────────────────────────────┐
│ herdr control panel                          │
│                                              │
│ > 新規ワークスペース                          │
│   Lazygit                                    │
│   File viewer                                │
│   ⌨ ショートカット一覧                        │
│   ＋ 機能を追加...                            │
│   🌐 Language / 言語                          │
│   キャンセル                                  │
└──────────────────────────────────────────────┘
```

## 動機

ターミナルマルチプレクサで新しいワークスペースを開くにはパスを打つ必要があり、パスを打つということは
補完も履歴も効かず、打ち間違いはペインが消えたあとに気づくということでもある。一方で、新しくツールを
繋ぐたびに専用のキーバインドが欲しくなるが、`prefix+`なんだっけ、は 5 個も超えると破綻する。

このプラグインは N 個のキーバインドをひとつに畳む。押すと fuzzy で絞り込めるメニューが出る。
そこには、過去に開いた場所を覚えていて打つそばからパスを補完するワークスペース選択と、
あなたがここに置くと決めたものが並ぶ。

## 導入

```sh
herdr plugin install iskwyuki/herdr-control-panel
```

`~/.config/herdr/config.toml` でキーにバインドする:

```toml
[[keys.command]]
key = "prefix+space"
description = "open control panel"
type = "shell"
command = "herdr plugin action invoke open-control-panel --plugin herdr-control-panel"
```

パネルは右側の split ペインとして開く。下側に出したい場合や全面 overlay にしたい場合は
`scripts/open-control-panel.sh` の `--direction` / `--placement` を変更する。

**必要なもの:** herdr 0.7.0+、[fzf](https://github.com/junegunn/fzf)、[jq](https://jqlang.github.io/jq/)、bash。
Linux と macOS に対応。

### フローティング小窓（popup）で開く

herdr の `type = "popup"` を使うとペインではなく小窓で開けるが、popup が実行するのは素のシェル
コマンドで、プラグインの環境変数（`HERDR_PLUGIN_CONFIG_DIR` / `HERDR_PLUGIN_STATE_DIR`）は
注入されず、プラグインがどこに入ったかも分からない。そこで導入先を解決する小さなラッパーを
用意して、そちらを指す:

```sh
#!/usr/bin/env bash
root="$(herdr plugin list --json | jq -r '.result.plugins[] | select(.plugin_id=="herdr-control-panel").plugin_root')"
exec bash "$root/scripts/panel.sh"
```

```toml
[[keys.command]]
key = "prefix+space"
type = "popup"
command = "herdr-panel"   # 上のラッパー（PATH 上に置く）
width = "50%"
height = "60%"
```

パスを実行時に解決するのは省略できない。`herdr plugin install` の導入先はディレクトリ名に
コミットハッシュが入るため、更新のたびに変わるからだ。設定と履歴はペイン経由と共有される。
環境変数が無い場合、パネルは config の場所を herdr に問い合わせ、state は herdr と同じ規則で
組み立てる。

## ワークスペースを開く

「新規ワークスペース」を選ぶと 2 通りの開き方が出る。

- **履歴** — 過去に開いたディレクトリが新しい順に並ぶ。プラグインの state ディレクトリに
  1 行 1 パスで保存され、最大 50 件。消えたディレクトリは表示されない
- **Open Folder...** — 開く場所に制限はない。fzf のクエリ欄がそのままパス入力欄になっていて、
  1 文字打つたびに候補が作り直される

| 操作 | 動き |
|---|---|
| 文字を打つ | そのパス配下の候補に追従する。`~` 展開と相対パス（`$HOME` 起点）に対応。前方一致が先に並ぶ |
| `Enter` | 選択がディレクトリなら 1 階層降りる。先頭の `▸ ここを開く` を選べばそこで確定 |
| `Ctrl-O` | 入力中のパスが実在すればその場で確定する |
| `ESC` | ひとつ前のメニューへ戻る（メインメニューで押すとパネルを閉じる） |

隠しディレクトリは `.` を打ったときだけ候補に出る。履歴が空のときはメニューを挟まず Open Folder が
直接開く。初期位置は `~/dev`（無ければ `$HOME`）。

## ショートカットを引く

「⌨ ショートカット一覧」は herdr のキーバインドを並べる。他の画面と同じく見出しでまとまり、
入力で絞り込める:

```
── herdr
  ctrl+b            Prefix
  prefix+n          Next tab
  prefix+shift+tab  Cycle pane previous
  ...

── herdr (custom commands)
  prefix+space      open control panel
```

この一覧は手で保守していない。既定値は `herdr --default-config`、上書きは
`~/.config/herdr/config.toml` の `[keys]`、最後のセクションは同じファイルの `[[keys.command]]` から
取る。割り当てを外したものは出ない。一覧を同梱すると、herdr が既定をひとつ変えた日から黙って
嘘をつき始める。herdr に聞いていればそうはならない。

一方、herdr の外にあるもの — 端末エミュレータやウィンドウマネージャのキー — はパネルからは
分からない。プラグイン自身の `config.toml` に書く:

```toml
[[keys]]
section     = "WezTerm"      # まとめる見出し。任意
key         = "Alt+l"
description = "ドメイン一覧ランチャー"
```

`--list-keys` を渡すとパネルを開かずに同じ一覧を印字する。fzf の無いヘッドレス環境でも読める。

## 項目を足す

プラグインの config ディレクトリにある `config.toml` に書く
（パスは `herdr plugin config-dir herdr-control-panel` で表示できる）:

```toml
[[actions]]
label   = "Lazygit"
command = "lazygit"          # シェルで実行されるのでパイプや引数が使える
# requires = "lazygit"       # 任意。省略時は command の先頭の語を存在確認する
```

受け付ける語彙は `[[actions]]` がこの 3 キー、`[[keys]]` が `key` / `description` / `section` だけ。
逸脱は黙って無視せず**行番号を添えて報告する**。
値の中にダブルクォートは書けないので、内側はシングルクォートを使う。

パネルの「＋ 機能を追加...」から選んでも**同じファイルに追記される**ので、UI と手書きで
置き場が食い違うことはない。未導入のコマンドはメニューに `(未導入)` と注記され、実行前に止まる。

パネルを開かずに検証できる:

```sh
bash "$(herdr plugin list --json | jq -r '.result.plugins[] | select(.plugin_id=="herdr-control-panel").plugin_root')/scripts/panel.sh" --check-config
```

パネル自身の表示言語（英語 / 日本語。既定は英語）は、このファイルではなく `🌐 Language` の項目から
切り替える。

## 設計メモ

**同梱する項目をひとつに絞ってある。** パネルは lazygit やファイルビューア、システムモニタを置くのに
向いた場所だが、そのどれもが「あなたの環境にそのツールが入っている」という賭けになる。同梱すると、
入れた人の環境で無言で失敗するメニュー項目を配ることになる。だから配布物には、確実に動くと言い切れる
項目 — herdr 自身の上に成り立つもの — だけを入れてある。それ以外は 2 行のブロックで足せる。

**設定が壊れてもパネルは壊れない。** 設定エラーとコア機能は意図的に切り離してある。`config.toml` が
壊れていると `⚠ N 件の問題` という項目が現れ、選べば内容を読めるが、その間も「新規ワークスペース」は
動き続ける。キーにバインドされたパネルにとって最悪の結末は、そもそも開かなくなることだ。

**TOML パーサではなく TOML のサブセット。** bash に TOML パーサは無く、まともなものを bash で書けば
バグの温床になる。そこで、文書化されたサブセット — `[[actions]]` と `[[keys]]`、ダブルクォート囲みの値、
エスケープなし — だけを受け付け、外れたものはすべて行番号つきのエラーにした。
初回に書き出されるテンプレートが、その仕様をファイル自身に同梱している。

**herdr の設定は読むが、評価しない。** ショートカット一覧は `~/.config/herdr/config.toml` を同じ
小さなパーサで読むが、読めない行は報告せず黙って飛ばす。あのファイルは herdr のものであって、
パネルが「あなたの herdr 設定は間違っている」と言う立場にはない。同時に「何を設定行と見なすか」には
慎重でなければならない。`herdr --default-config` は全項目がコメントアウトされた雛形で、
`# type = "shell" runs detached in the background.` のような散文も、緩く読めばキーバインドとして
成立してしまう（実際に成立し、`Type → shell` という存在しない項目が一覧に出た）。

**自作 TUI ではなく fzf。** マウスクリックを扱え（gum は扱えなかった）、fuzzy 絞り込みが最初から効き、
`--disabled` と `change:reload` を組み合わせるとクエリ欄が「打つたびに補完し直すパス入力欄」になる。
Open Folder のブラウザはこの一手でできている。

**bash 3.2 互換。** macOS の `/bin/bash` はいまだに 3.2 系で、GUI アプリから起動された端末には
Homebrew の bash 5 が `PATH` に無いことがある。連想配列も `mapfile` も使っていない。

## 開発

```sh
tests/run.sh                # 全部
tests/run.sh parse paths    # tests/test_parse.sh と tests/test_paths.sh だけ
bash tests/test_parse.sh    # 1 ファイルを単体で
```

テストフレームワークの導入は要らない。ハーネスは素の bash 1 ファイルで、パネル本体と同じく
3.2 で動く。CI は同じスクリプトを Linux と macOS で `/bin/bash` から実行するので、macOS 側が
このプラグインの下限である 3.2 をそのまま検証することになる。

`panel.sh` は `source` しても安全にしてある（直接実行したときだけ `main` が走り、source では
関数定義だけが読まれる）。そのためテストは UI を操作せず、`parse_config` や `complete_dirs`、
`add_history` を直接呼ぶ。パネルが自分のために持っているサブコマンド（設定検証の `--check-config`、
ショートカット一覧の `--list-keys`、fzf の reload 用 `--complete-dirs`）は、そのまま統合テストの
入口として使っている。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
