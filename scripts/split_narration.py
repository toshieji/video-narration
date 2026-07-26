#!/usr/bin/env python3
"""Part台本（読み上げ原稿）Markdownから、スライド単位の読み上げテキストを一括抽出する。

対象フォーマット（本パイプライン全体の共通ルール）:
  ## スライドN（ラベル）
  （説明文や注記の行があってもよい）
  ```
  読み上げるテキスト本文...
  ```

各スライドのコードブロックの中身を `slideNN_label.txt` として書き出す。
NNは2桁ゼロ埋め、labelはラベル文字列から空白・スラッシュを除いたもの。

使い方:
  python3 split_narration.py <part-script.md> <out-dir>

依存: 標準ライブラリのみ（追加インストール不要）。
"""
import argparse
import re
import sys
from pathlib import Path

HEADER_RE = re.compile(
    r"^##\s*スライド(?P<num>\d+)\s*[（(](?P<label>[^）)]*)[）)]",
    re.MULTILINE,
)
FENCE_RE = re.compile(r"```\n(?P<body>.*?)\n```", re.DOTALL)


def sanitize_label(label: str) -> str:
    label = label.strip()
    label = re.sub(r"[\\/\s]+", "", label)
    return label or "slide"


def extract_blocks(text: str):
    """(slide_num, label, body) のリストを返す。各見出しの直後、次の見出しが
    始まるまでの範囲から最初のフェンスコードブロックを探す。"""
    headers = list(HEADER_RE.finditer(text))
    blocks = []
    for i, m in enumerate(headers):
        start = m.end()
        end = headers[i + 1].start() if i + 1 < len(headers) else len(text)
        section = text[start:end]
        fence = FENCE_RE.search(section)
        if not fence:
            print(
                f"WARNING: スライド{m.group('num')}（{m.group('label')}）に"
                f"コードブロックが見つかりません。スキップします。",
                file=sys.stderr,
            )
            continue
        blocks.append((int(m.group("num")), m.group("label"), fence.group("body").strip()))
    return blocks


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("part_script", type=Path, help="Part台本（読み上げ原稿）.mdファイル")
    ap.add_argument("out_dir", type=Path, help="出力先ディレクトリ（slideNN_label.txtを書き出す）")
    args = ap.parse_args()

    if not args.part_script.is_file():
        sys.exit(f"ERROR: {args.part_script} が見つかりません")

    text = args.part_script.read_text(encoding="utf-8")
    blocks = extract_blocks(text)

    if not blocks:
        sys.exit("ERROR: スライドブロックが1つも見つかりませんでした。フォーマットを確認してください。")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for num, label, body in blocks:
        out_path = args.out_dir / f"slide{num:02d}_{sanitize_label(label)}.txt"
        out_path.write_text(body + "\n", encoding="utf-8")
        print(f"slide{num:02d}: {len(body)}文字 -> {out_path}")

    print(f"\n完了: {len(blocks)}件 -> {args.out_dir}")


if __name__ == "__main__":
    main()
