#!/usr/bin/env bash
# 既存の講座動画から、台本づくりの素材を抽出する（文字起こし＋スライド画像）。
# 過去に収録した動画がある場合、その語り口・事例・言い回しを新しい台本に活かすために使う。
#
# 使い方: extract_source_video.sh <動画ファイル|URL> <out-dir> [--scene-threshold 0.08] [--lang ja]
# 例:     extract_source_video.sh https://vimeo.com/123456789 material/lecture1/
#         extract_source_video.sh recorded.mp4 material/lecture1/
#
# 出力:
#   <out-dir>/source.<ext>       ダウンロードした動画（URL指定時のみ）
#   <out-dir>/transcript.txt     文字起こし（台本の素材にする）
#   <out-dir>/transcript.srt     タイムコード付き文字起こし
#   <out-dir>/slides/slide_NNN.png  画面が切り替わった箇所の静止画
#
# 依存: yt-dlp（URL指定時のみ）/ ffmpeg / uvx（mlx-whisper用・Apple Silicon限定）
set -euo pipefail

SCENE_THRESHOLD="0.08"
LANG_CODE="ja"
WHISPER_MODEL="mlx-community/whisper-large-v3-mlx"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scene-threshold) SCENE_THRESHOLD="$2"; shift 2 ;;
    --lang) LANG_CODE="$2"; shift 2 ;;
    --model) WHISPER_MODEL="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

SOURCE="${1:?動画ファイルまたはURLを指定してください}"
OUT_DIR="${2:?出力先ディレクトリを指定してください}"

mkdir -p "$OUT_DIR/slides"

# ---- 1/3 動画の準備 ----
echo "==== [1/3] 動画の準備 ===="
if [[ -f "$SOURCE" ]]; then
  VIDEO="$SOURCE"
  echo "  ローカルファイルを使用: $VIDEO"
else
  if ls "$OUT_DIR"/source.* >/dev/null 2>&1; then
    VIDEO="$(ls "$OUT_DIR"/source.* | head -1)"
    echo "  ダウンロード済み: $VIDEO"
  else
    echo "  ダウンロード中: $SOURCE"
    # 認証が必要な配信サービス（Vimeo等）では --cookies-from-browser が要る場合がある
    yt-dlp -o "$OUT_DIR/source.%(ext)s" "$SOURCE" \
      || yt-dlp --cookies-from-browser chrome -o "$OUT_DIR/source.%(ext)s" "$SOURCE"
    VIDEO="$(ls "$OUT_DIR"/source.* | head -1)"
  fi
fi

# ---- 2/3 文字起こし ----
echo "==== [2/3] 文字起こし（$WHISPER_MODEL / $LANG_CODE）===="
if [[ -f "$OUT_DIR/transcript.txt" ]]; then
  echo "  transcript.txt が既にあります — スキップ"
else
  uvx --from mlx-whisper mlx_whisper "$VIDEO" \
    --model "$WHISPER_MODEL" --language "$LANG_CODE" \
    --output-name transcript --output-format txt,srt --output-dir "$OUT_DIR"
fi
echo "  行数: $(wc -l < "$OUT_DIR/transcript.txt" | tr -d ' ')"

# ---- 3/3 スライド画像の抽出 ----
echo "==== [3/3] スライド画像の抽出（シーン変化 > $SCENE_THRESHOLD）===="
rm -f "$OUT_DIR"/slides/*.png
ffmpeg -hide_banner -loglevel error -i "$VIDEO" \
  -vf "select='gt(scene,$SCENE_THRESHOLD)'" -vsync vfr \
  "$OUT_DIR/slides/slide_%03d.png"
N="$(ls "$OUT_DIR"/slides/*.png 2>/dev/null | wc -l | tr -d ' ')"
echo "  抽出枚数: $N"
if [[ "$N" -eq 0 ]]; then
  echo "  ヒント: 0枚なら --scene-threshold を下げる（例 0.04）。多すぎるなら上げる。"
fi

echo "==== 完了: $OUT_DIR ===="
