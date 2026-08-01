#!/usr/bin/env bash
# 全テストを走らせる。CI からもここを呼ぶ（ローカルと CI で同じものを実行する）。
#
#   tests/run.sh              全部
#   tests/run.sh parse paths  名前で絞る（tests/test_<名前>.sh）
#
# 個々のファイルは単体でも実行できる:  bash tests/test_parse.sh
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
failed=0
files=""

if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    f="$DIR/test_$name.sh"
    if [ -f "$f" ]; then
      files="$files $f"
    else
      printf 'no such test file: %s\n' "$f" >&2
      exit 2
    fi
  done
else
  files="$(ls "$DIR"/test_*.sh)"
fi

printf 'bash %s (%s)\n\n' "${BASH_VERSION%%(*}" "$(uname -s)"

for f in $files; do
  bash "$f" || failed=$((failed + 1))
done

if [ "$failed" -gt 0 ]; then
  printf '\033[31m%s file(s) failed\033[0m\n' "$failed"
  exit 1
fi
printf '\033[32mall green\033[0m\n'
