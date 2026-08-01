#!/usr/bin/env bash
# コントロールパネルを split（画面の一部のパネル）として開く launcher。
# herdr のアクション/キーバインドは「コマンドを実行する」だけなので、
# ここから herdr CLI を叩いて [[panes]] の control-panel を split として開く。
# ※ placement に popup は指定できない（CLI・socket API とも overlay|split|tab|zoomed のみ）。
#    overlay は全画面を覆うため、作業ペインを残せる split を採用。
#    --direction right = 右側にパネル（down にすれば下側に出る）。
# ($HERDR_BIN_PATH は herdr が注入。無ければ PATH 上の herdr にフォールバック)
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

exec "$herdr_bin" plugin pane open \
  --plugin herdr-control-panel \
  --entrypoint control-panel \
  --placement split \
  --direction right \
  --focus
