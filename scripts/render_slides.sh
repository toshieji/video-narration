#!/usr/bin/env bash
# スライド(.pptxまたは.pdf)を1枚ずつJPEG画像に変換する（slideNN.jpg命名に正規化）。
# 使い方: render_slides.sh <deck.pptx|deck.pdf> <out-dir> [dpi]
# 例:     render_slides.sh deck.pptx frames/ 150
#
# 依存: LibreOffice（soffice）、poppler（pdftoppm）
set -euo pipefail

DECK="${1:?入力ファイル(.pptxまたは.pdf)を指定してください}"
OUT_DIR="${2:?出力先ディレクトリを指定してください}"
DPI="${3:-150}"

if [[ ! -f "$DECK" ]]; then
  echo "ERROR: $DECK が見つかりません" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

case "$DECK" in
  *.pdf)
    PDF="$DECK"
    ;;
  *)
    echo "==== pptx→PDF変換中 (LibreOffice) ===="
    soffice --headless --convert-to pdf --outdir "$WORK_DIR" "$DECK" >/dev/null
    BASENAME="$(basename "${DECK%.*}")"
    PDF="$WORK_DIR/$BASENAME.pdf"
    if [[ ! -f "$PDF" ]]; then
      echo "ERROR: PDF変換に失敗しました（$PDF が生成されませんでした）" >&2
      exit 1
    fi
    ;;
esac

echo "==== PDF→JPEG変換中 (dpi=$DPI) ===="
pdftoppm -jpeg -r "$DPI" "$PDF" "$WORK_DIR/page"

# poppler出力のページ番号桁数は総ページ数依存（page-1.jpg / page-01.jpgなど揺れる）ため、
# 実ファイル名から番号を読み取り、slideNN.jpg（2桁ゼロ埋め）に正規化して書き出す
COUNT=0
for f in "$WORK_DIR"/page-*.jpg; do
  [[ -f "$f" ]] || continue
  num="$(basename "$f" .jpg | sed -E 's/^page-0*//')"
  padded="$(printf "%02d" "$num")"
  cp "$f" "$OUT_DIR/slide${padded}.jpg"
  COUNT=$((COUNT + 1))
done

if [[ "$COUNT" -eq 0 ]]; then
  echo "ERROR: 画像が1枚も生成されませんでした" >&2
  exit 1
fi

echo "==== 完了: ${COUNT}枚 -> $OUT_DIR ===="
