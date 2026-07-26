#!/usr/bin/env python3
"""生成したナレーション音声1件を、Whisperで文字起こしして原稿と突き合わせ検証する。

使い方（mlx-whisperをuvxでオンデマンド実行。ローカルにpipインストール不要・Mac/Apple Silicon限定）:
  uvx --from mlx-whisper python verify_narration.py <audio.wav> <source.txt> [--model NAME] [--threshold 0.70] [--out report.md]

重要: このスクリプトは音声ファイル1件・原稿1件のみを受け取る設計で、
ディレクトリ一括モードを意図的に持たせていない。長い音声（結合後の動画全体など）を
Whisperに一度に通すと、無音区間や長尺化に伴って架空の文言を生成する（hallucination）
ことが実際に確認されている。検証は必ずスライド1枚＝1クリップ単位で行うこと。

Gemini TTSで実際に確認された既知のグリッチ（検出対象）:
  - 同一フレーズの連続リピート（酷いケースでは同じ語が70回以上、数百回に及んだ例もある）
  - アクロニム等の一部が壊れて再生される（例: "LLMEO"が"LMEO"になる）
  - 原稿にない「ご視聴ありがとうございました」等の定型句が末尾に付加される
  - 原稿にない英単語・文字列が混入する
  - 生成自体の失敗（generate_tts.sh側でKeyError: 'parts'として検出）

グリッチを検出した場合は、同一の入力テキストでgenerate_tts.shを再実行すること
（TTSのサンプリングランダム性により、多くの場合リトライで解消する。頑固な場合は
3〜4回のリトライが必要になることもある）。
"""
import argparse
import difflib
import re
import sys
from pathlib import Path

STOCK_CLOSING_PHRASES = [
    "ご視聴ありがとうございました",
    "ご清聴ありがとうございました",
]


def find_repeated_phrases(text: str, min_len: int = 14, max_len: int = 120):
    """min_len文字以上の文字列が直後に繰り返されている箇所を検出する。"""
    pattern = re.compile(r"(.{%d,%d}?)\1" % (min_len, max_len))
    seen = []
    for m in pattern.finditer(text):
        phrase = m.group(1)
        if phrase not in seen:
            seen.append(phrase)
    return seen


def extract_ascii_words(text: str, min_len: int = 4):
    return set(w.lower() for w in re.findall(r"[A-Za-z]{%d,}" % min_len, text))


def transcribe(audio_path: str, model: str) -> str:
    import mlx_whisper

    result = mlx_whisper.transcribe(audio_path, path_or_hf_repo=model)
    return result["text"].strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("audio", help="検証する音声ファイル（1件のみ。wav/mp3等）")
    ap.add_argument("source_text", help="対応する原稿テキストファイル（1件のみ）")
    ap.add_argument("--model", default="mlx-community/whisper-large-v3-mlx", help="Whisperモデル（既定: large-v3）")
    ap.add_argument("--threshold", type=float, default=0.70, help="difflib類似度のしきい値（既定0.70。漢字の読み違いは正常なゆらぎとして許容）")
    ap.add_argument("--out", help="結果をMarkdownレポートとしてこのパスに書き出す（任意）")
    args = ap.parse_args()

    audio_path = Path(args.audio)
    source_path = Path(args.source_text)
    if not audio_path.is_file():
        sys.exit(f"ERROR: 音声ファイルが見つかりません: {audio_path}")
    if not source_path.is_file():
        sys.exit(f"ERROR: 原稿ファイルが見つかりません: {source_path}")

    source_text = source_path.read_text(encoding="utf-8").strip()
    print(f"==== Whisper文字起こし中: {audio_path} ====", file=sys.stderr)
    transcript = transcribe(str(audio_path), args.model)

    ratio = difflib.SequenceMatcher(None, source_text, transcript).ratio()

    flags = []

    repeats = find_repeated_phrases(transcript)
    if repeats:
        flags.append(f"文の異常リピートを検出: {repeats}")

    for phrase in STOCK_CLOSING_PHRASES:
        if phrase in transcript and phrase not in source_text:
            flags.append(f"原稿にない定型句が末尾等に付加されている疑い: 「{phrase}」")

    extra_ascii = extract_ascii_words(transcript) - extract_ascii_words(source_text)
    if extra_ascii:
        flags.append(f"原稿にない英単語が混入している疑い: {sorted(extra_ascii)}")

    ok = ratio >= args.threshold and not flags

    lines = []
    lines.append(f"# 検証結果: {audio_path.name}")
    lines.append("")
    lines.append(f"- 判定: {'✅ 問題なし' if ok else '⚠️ 要確認'}")
    lines.append(f"- 類似度: {ratio:.3f}（しきい値 {args.threshold}）")
    lines.append("")
    lines.append("## 文字起こし結果")
    lines.append("```")
    lines.append(transcript)
    lines.append("```")
    lines.append("")
    lines.append("## 原稿")
    lines.append("```")
    lines.append(source_text)
    lines.append("```")
    if flags:
        lines.append("")
        lines.append("## 検出された懸念点")
        for f in flags:
            lines.append(f"- {f}")
    report = "\n".join(lines)

    print(report)
    if args.out:
        Path(args.out).write_text(report + "\n", encoding="utf-8")
        print(f"\nレポートを書き出しました: {args.out}", file=sys.stderr)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
