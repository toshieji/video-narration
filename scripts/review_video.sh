#!/usr/bin/env bash
# 完成した動画を多点レビューする：①フレーム抽出（内容確認用）②スライド間隔の
# タイミング検証（silencedetectで全間隔を機械的に列挙し期待値と比較）③任意で
# 境界前後の音量チェック（ストリームコピー結合が残す微小ノイズの検出用）。
#
# 使い方: review_video.sh <video.mp4> [--frames N(既定6)] [--gap-expected SECONDS] \
#           [--tolerance-pct 20] [--out-dir DIR(既定 ./review)] [--check-boundaries]
#
# --gap-expected を指定すると、build_video.shに渡した --gap と同じ値を使うことで
# 「スライド切替の間隔が意図通りか」を自動判定できる（このスクリプトは、実際に
# ffmpegの-shortestオプションが静止画ループ＋長尺音声で不正確になるバグを
# 発見したのと同じ手法＝silencedetectでの間隔の機械的な列挙、を汎用化したもの）。
#
# 依存: ffmpeg / ffprobe / python3
set -euo pipefail

FRAMES=6
GAP_EXPECTED=""
TOLERANCE_PCT=20
OUT_DIR="./review"
CHECK_BOUNDARIES=0
DETECT_MIN_OVERRIDE=""
EXPECTED_SLIDES=""
POSITIONAL=()
# 値を取るオプションで値が省略された場合、set -u によるシェル内部エラーではなく
# 分かりやすいメッセージを出す
need_value() {
  if [[ "$2" -lt 2 ]]; then
    echo "ERROR: $1 には値が必要です" >&2
    exit 1
  fi
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --frames) need_value "$1" $#; FRAMES="$2"; shift 2 ;;
    --gap-expected) need_value "$1" $#; GAP_EXPECTED="$2"; shift 2 ;;
    --tolerance-pct) need_value "$1" $#; TOLERANCE_PCT="$2"; shift 2 ;;
    --out-dir) need_value "$1" $#; OUT_DIR="$2"; shift 2 ;;
    --check-boundaries) CHECK_BOUNDARIES=1; shift ;;
    --detect-min) need_value "$1" $#; DETECT_MIN_OVERRIDE="$2"; shift 2 ;;
    --expected-slides) need_value "$1" $#; EXPECTED_SLIDES="$2"; shift 2 ;;
    --*) echo "ERROR: 未知のオプション: $1" >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

VIDEO="${1:?動画ファイルを指定してください}"
if [[ ! -f "$VIDEO" ]]; then
  echo "ERROR: $VIDEO が見つかりません" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO")
echo "==== 動画の長さ: ${DURATION}秒 ===="

echo ""
echo "==== ①フレーム抽出（${FRAMES}箇所、内容目視確認用） ===="
# 値はsys.argv経由で渡す（パスに引用符が含まれるとPythonソースが壊れるため）
python3 - "$DURATION" "$FRAMES" "$OUT_DIR" "$VIDEO" <<'PYEOF'
import subprocess, sys
duration, frames, out_dir, video = float(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
for i in range(frames):
    t = duration * (i + 0.5) / frames
    out = f'{out_dir}/frame_{i+1:02d}_t{t:.0f}s.jpg'
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-ss', str(t), '-i', video,
                    '-frames:v', '1', out], check=True)
    print(f'  {out}')
PYEOF
echo "（これらの画像を開いて、想定したスライド内容と一致しているか確認してください）"

echo ""
echo "==== ②スライド切替間隔の検証（silencedetect） ===="
if [[ -n "$DETECT_MIN_OVERRIDE" ]]; then
  DETECT_MIN="$DETECT_MIN_OVERRIDE"
elif [[ -n "$GAP_EXPECTED" ]]; then
  # スライド切替の意図した間隔をわずかに上回る値を検出しきい値にする。
  # ナレーション中の自然な間は実測でおおむね1.5秒以下だが、gapに近い長さの
  # ものもあり、gapちょうど（×1.0）では両者が混ざる。23枚の実データでは
  # gap=2秒に対し ×1.0 で25件（自然な間を2件誤検出）、×1.05 で正確に23件に
  # 分離できた。分離できない場合は --detect-min で直接調整する。
  DETECT_MIN=$(python3 -c "print(max(1.0, float('$GAP_EXPECTED') * 1.05))")
else
  DETECT_MIN=1.5
fi
echo "（無音の検出しきい値: ${DETECT_MIN}秒以上）"

ffmpeg -i "$VIDEO" -af "silencedetect=noise=-35dB:d=${DETECT_MIN}" -f null - 2>"$OUT_DIR/silencedetect_raw.log" || true

GAP_STATUS=$(python3 - "$OUT_DIR/silencedetect_raw.log" "$GAP_EXPECTED" "$TOLERANCE_PCT" "$EXPECTED_SLIDES" <<'PYEOF'
import re, sys
log_path, gap_expected, tolerance_pct, expected_slides = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
text = open(log_path).read()
starts = re.findall(r'silence_start:\s*([\d.]+)', text)
ends_durs = re.findall(r'silence_end:\s*([\d.]+)\s*\|\s*silence_duration:\s*([\d.]+)', text)
entries = [(float(s), float(e), float(d)) for s, (e, d) in zip(starts, ends_durs)]

failed = False

if not entries:
    print('検出された間隔: 0件（--gap-expectedやノイズしきい値を見直してください）')
    print('STATUS:FAIL')
    sys.exit()

print(f'検出された間隔: {len(entries)}件')
bad = 0
for s, e, d in entries:
    line = f'  t={s:8.2f}s  長さ={d:.2f}s'
    if gap_expected:
        ge = float(gap_expected)
        diff_pct = abs(d - ge) / ge * 100
        if diff_pct > tolerance_pct:
            line += f'  ⚠️ 期待値{ge}秒から{diff_pct:.0f}%乖離'
            bad += 1
        else:
            line += '  ✅'
    print(line)

if gap_expected:
    print(f'\n{bad}/{len(entries)}件が許容範囲(±{tolerance_pct}%)を超過')
    if bad > 0:
        failed = True

# 件数の検証。--expected-slides が渡された場合のみ実施。
# これが無いと「無音区間をいくつか見つけた」だけで、本当に全スライドの
# 切替を検証できたのかが分からない（ナレーション中の長い間を境界と
# 誤認したり、逆に本来の境界が閾値未満で消えていても気づけない）。
if expected_slides:
    n = int(expected_slides)
    # 各スライド末尾にgapが入るため、最終スライド分を含めてスライド数と一致するのが期待値。
    # ただし最終gapが動画末尾で切れる実装もあるため n-1 も許容する。
    if len(entries) not in (n, n - 1):
        print(f'\n⚠️ 検出件数{len(entries)}件が、スライド数{n}から想定される'
              f'件数（{n-1}または{n}）と一致しません。')
        print('   ナレーション中の長い間を境界と誤認しているか、本来の切替が')
        print('   検出しきい値未満になっている可能性があります。--detect-min を調整してください。')
        failed = True
    else:
        print(f'\n✅ 検出件数{len(entries)}件はスライド数{n}と整合しています')
else:
    print('\n注意: --expected-slides 未指定のため、"全ての切替を検証できたか" は未確認です。')
    print('      検出された無音区間が全て切替であるとは限りません。')

print('STATUS:FAIL' if failed else 'STATUS:OK')
PYEOF
)

echo "$GAP_STATUS" | grep -v '^STATUS:'
FINAL_STATUS=$(echo "$GAP_STATUS" | grep '^STATUS:' | cut -d: -f2)

if [[ "$CHECK_BOUNDARIES" -eq 1 ]]; then
  echo ""
  echo "==== ③境界前後の音量チェック（ストリームコピー結合ノイズの検出） ===="
  python3 -c "
import re, subprocess
text = open('$OUT_DIR/silencedetect_raw.log').read()
starts = re.findall(r'silence_start:\s*([\d.]+)', text)
ends_durs = re.findall(r'silence_end:\s*([\d.]+)\s*\|\s*silence_duration:\s*([\d.]+)', text)
entries = [(float(s), float(e)) for s, (e, d) in zip(starts, ends_durs)]

def volume(t, dur=0.3):
    r = subprocess.run(['ffmpeg', '-y', '-ss', str(max(0, t)), '-t', str(dur), '-i', '$VIDEO',
                         '-af', 'volumedetect', '-f', 'null', '-'],
                        capture_output=True, text=True)
    m = re.search(r'max_volume:\s*(-?[\d.]+)\s*dB', r.stderr)
    return m.group(1) if m else 'N/A'

for s, e in entries[:10]:
    # 無音区間の内側（開始0.1秒後）＝ほぼ無音のはず。区間終了直後＝もう発話しているはず。
    inside = volume(s + 0.1)
    after = volume(e + 0.05)
    print(f'  区間 t={s:.2f}〜{e:.2f}s: 区間内max_volume={inside}dB（無音のはず・-40dB以下が目安） / 区間直後max_volume={after}dB（発話しているはず）')
"
fi

echo ""
echo "==== 総合判定: ${FINAL_STATUS} ===="
[[ "$FINAL_STATUS" == "OK" ]]
