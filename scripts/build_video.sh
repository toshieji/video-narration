#!/usr/bin/env bash
# スライド画像＋ナレーション音声から、ナレーション付き動画を直接組み立てる。
# PowerPointの「ビデオとしてエクスポート」機能には頼らない——それは「記録されたタイミング／
# ナレーション」メタデータが無いと使えず、単にaddしただけの音声アイコンでは
# スライドが実際の音声の長さを無視してアプリのデフォルト（大抵5秒）で切り替わってしまう。
# ここでは各スライドの実際の音声長を計測し、明示的な長さ指定で組み立てる。
#
# 使い方: build_video.sh <images-dir> <audio-dir> <output.mp4> \
#           [--gap SECONDS(既定1.5)] [--resolution 1920x1080] [--fps 30] \
#           [--audio-bitrate 192k] [--work-dir DIR] [--keep-work-dir] [--force]
#
# 入力の命名規則: images-dir/slideNN*.jpg, audio-dir/slideNN*.(wav|mp3) をNNで突き合わせる。
#
# 依存: ffmpeg / ffprobe
set -euo pipefail

GAP="1.5"
RESOLUTION="1920x1080"
FPS="30"
AUDIO_BITRATE="192k"
WORK_DIR=""
KEEP_WORK_DIR=0
FORCE=0
POSITIONAL=()
need_value() {
  if [[ "$2" -lt 2 ]]; then
    echo "ERROR: $1 には値が必要です" >&2
    exit 1
  fi
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gap) need_value "$1" $#; GAP="$2"; shift 2 ;;
    --resolution) need_value "$1" $#; RESOLUTION="$2"; shift 2 ;;
    --fps) need_value "$1" $#; FPS="$2"; shift 2 ;;
    --audio-bitrate) need_value "$1" $#; AUDIO_BITRATE="$2"; shift 2 ;;
    --work-dir) need_value "$1" $#; WORK_DIR="$2"; shift 2 ;;
    --keep-work-dir) KEEP_WORK_DIR=1; shift ;;
    --force) FORCE=1; shift ;;
    --*) echo "ERROR: 未知のオプション: $1" >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

IMAGES_DIR="${1:?images-dir（slideNN.jpg等が入ったディレクトリ）を指定してください}"
AUDIO_DIR="${2:?audio-dir（slideNN.wav等が入ったディレクトリ）を指定してください}"
OUTPUT_MP4="${3:?出力mp4のパスを指定してください}"

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d)"
  CLEANUP_WORK_DIR=1
else
  mkdir -p "$WORK_DIR"
  CLEANUP_WORK_DIR=0
fi
mkdir -p "$WORK_DIR/trimmed" "$WORK_DIR/segments"

cleanup() {
  # 自動生成した一時ディレクトリのみ既定で削除する。--work-dir を明示指定した場合は
  # （--force での差分ビルド再利用を想定し）既定で残す。--keep-work-dir は一時ディレクトリ
  # 側の挙動を上書きする。
  if [[ "$CLEANUP_WORK_DIR" -eq 1 && "$KEEP_WORK_DIR" -eq 0 ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

RES_W="${RESOLUTION%x*}"
RES_H="${RESOLUTION#*x}"

# 指定番号のファイルを1件だけ返す（番号の直後は "_" か "." のみ許可）。
# 前方一致だと slide01* が slide010_*.jpg を拾ってしまうため、正規表現で絞る。
#
# 拡張子は引数の指定順に優先する（例 "wav|mp3" なら同じスライドにwavとmp3が
# 両方あってもwavを使う。同一音声の別形式であって重複ではないため）。
# 同じ拡張子で複数該当した場合は、どれが選ばれるか不定になるためエラーにする。
find_one() {
  local dir="$1" num="$2" exts="$3" label="$4"
  local padded ext matches
  padded="$(printf "%02d" "$num")"

  local IFS='|'
  local ext_list=($exts)
  unset IFS

  for ext in "${ext_list[@]}"; do
    matches=()
    local f base
    for f in "$dir"/*; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      if [[ "$base" =~ ^slide0*${num}(_[^/]*)?\.${ext}$ ]]; then
        matches+=("$f")
      fi
    done
    if [[ "${#matches[@]}" -gt 1 ]]; then
      echo "ERROR: スライド${padded}の${label}（.${ext}）が複数あります:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      exit 1
    fi
    if [[ "${#matches[@]}" -eq 1 ]]; then
      printf '%s' "${matches[0]}"
      return 0
    fi
  done
  return 1
}

# スライド番号を画像側から収集
NUMS=()
for f in "$IMAGES_DIR"/slide*.jpg; do
  [[ -f "$f" ]] || continue
  n="$(basename "$f" .jpg | sed -E 's/^slide0*([0-9]+).*/\1/')"
  NUMS+=("$n")
done
if [[ "${#NUMS[@]}" -eq 0 ]]; then
  echo "ERROR: $IMAGES_DIR に slideNN*.jpg が見つかりません" >&2
  exit 1
fi
# ソート・重複除去
IFS=$'\n' SORTED_NUMS=($(printf '%s\n' "${NUMS[@]}" | sort -n -u)); unset IFS

# 番号が1から連番になっているか検査。
# 飛びがあると「欠けたまま正常終了」して不完全な動画ができてしまう。
EXPECTED=1
GAPS=()
for n in "${SORTED_NUMS[@]}"; do
  while [[ "$EXPECTED" -lt "$n" ]]; do
    GAPS+=("$EXPECTED")
    EXPECTED=$((EXPECTED + 1))
  done
  EXPECTED=$((n + 1))
done
if [[ "${#GAPS[@]}" -gt 0 ]]; then
  echo "ERROR: スライド番号が連番になっていません。欠番: ${GAPS[*]}" >&2
  echo "       （意図的に一部だけ作る場合は、連番になるよう番号を振り直してください）" >&2
  exit 1
fi

# 負のインデックス（[-1]）はbash 3.2（macOS標準）で使えないため添字で取る
LAST_NUM="${SORTED_NUMS[$((${#SORTED_NUMS[@]} - 1))]}"
echo "==== ${#SORTED_NUMS[@]}枚のスライドを検出（1〜${LAST_NUM}の連番）===="

# 画像・音声の対応チェック（欠けがあれば即エラー）
MISSING=()
for n in "${SORTED_NUMS[@]}"; do
  padded="$(printf "%02d" "$n")"
  img="$(find_one "$IMAGES_DIR" "$n" "jpg|jpeg|png" "画像" || true)"
  aud="$(find_one "$AUDIO_DIR" "$n" "wav|mp3|m4a" "音声" || true)"
  if [[ -z "$img" || -z "$aud" ]]; then
    MISSING+=("slide${padded}: image=${img:-なし} audio=${aud:-なし}")
  fi
done
if [[ "${#MISSING[@]}" -gt 0 ]]; then
  echo "ERROR: 画像/音声が揃っていないスライドがあります:" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  exit 1
fi

CONCAT_LIST="$WORK_DIR/concat_list.txt"
> "$CONCAT_LIST"

for n in "${SORTED_NUMS[@]}"; do
  padded="$(printf "%02d" "$n")"
  img="$(find_one "$IMAGES_DIR" "$n" "jpg|jpeg|png" "画像")"
  aud="$(find_one "$AUDIO_DIR" "$n" "wav|mp3|m4a" "音声")"
  seg="$WORK_DIR/segments/seg${padded}.mp4"

  if [[ -f "$seg" && "$FORCE" -eq 0 ]]; then
    echo "skip（既存）: seg${padded}.mp4"
    echo "file 'segments/seg${padded}.mp4'" >> "$CONCAT_LIST"
    continue
  fi

  trimmed="$WORK_DIR/trimmed/slide${padded}.mp3"
  # 冒頭無音の除去（Gemini TTSクリップは0.3〜0.9秒程度の無音が先頭に付くことがあり、
  # これを残したままだとスライド切替直後に間延びして聞こえる）
  ffmpeg -y -loglevel error -i "$aud" \
    -af "silenceremove=start_periods=1:start_duration=0.05:start_threshold=-40dB:detection=peak" \
    "$trimmed"

  adur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$trimmed")
  total=$(python3 -c "print(float('$adur') + float('$GAP'))")

  # 重要: ここで -shortest は使わない。
  # 静止画ループ(-loop 1)＋長尺音声(apadでパディング)の組み合わせでは、-shortestが
  # 意図した長さより毎回一貫して余分に（実測で約1.8〜2秒）長くなることを単体テストで
  # 確認済み（5秒の短いクリップでは正確だが、約55秒のクリップでは再現するduration依存の
  # バグ）。かわりに ffprobe で実測した長さを -t で明示指定する。
  ffmpeg -y -loglevel error -loop 1 -i "$img" -i "$trimmed" \
    -filter_complex "[1:a]apad=pad_dur=${GAP}[a]" \
    -map 0:v -map "[a]" \
    -c:v libx264 -tune stillimage -pix_fmt yuv420p \
    -vf "scale=${RES_W}:${RES_H}:force_original_aspect_ratio=decrease,pad=${RES_W}:${RES_H}:(ow-iw)/2:(oh-ih)/2" \
    -c:a aac -b:a "$AUDIO_BITRATE" -t "$total" -r "$FPS" \
    "$seg"

  echo "done: seg${padded}.mp4 (音声=${adur}s 合計=${total}s)"
  echo "file 'segments/seg${padded}.mp4'" >> "$CONCAT_LIST"
done

echo "==== 結合中（再エンコード） ===="
# 出力先を絶対パスに解決してから cd する（concatリストが作業ディレクトリ相対のため
# cd が必要だが、出力パスが相対指定だと解決先がずれる）
OUT_PARENT="$(cd "$(dirname "$OUTPUT_MP4")" && pwd)"
OUTPUT_ABS="$OUT_PARENT/$(basename "$OUTPUT_MP4")"

# 重要: concat demuxer で -c copy（ストリームコピー）すると、セグメント境界に
# 約-56dBの微小ノイズが残ることを実測で確認済み（完全な無音は-83〜-91dB程度）。
# 必ず再エンコードして結合すること。
(cd "$WORK_DIR" && ffmpeg -y -loglevel error -f concat -safe 0 -i concat_list.txt \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a "$AUDIO_BITRATE" \
  "$OUTPUT_ABS")

OUTPUT_MP4="$OUTPUT_ABS"

echo "==== 完了: $OUTPUT_MP4 ===="
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 "$OUTPUT_MP4"

if [[ "$KEEP_WORK_DIR" -eq 1 ]]; then
  echo "作業ディレクトリを保持: $WORK_DIR"
fi
