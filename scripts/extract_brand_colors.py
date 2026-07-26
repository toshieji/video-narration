#!/usr/bin/env python3
"""既存のスライドデッキから、実際に使われている色を抽出する。

新しいスライドを既存デッキのトーンに合わせて作るとき、色を目分量で選ばずに
実物から取る。抽出した16進カラーコードを、スライド生成スクリプト
（pptxgenjs等）のパレット定義にそのまま貼り付けて使う。

使い方:
  uvx --from pillow python extract_brand_colors.py <images-dir> [--top 12] [--min-ratio 0.005]

<images-dir> は render_slides.sh でデッキを画像化したディレクトリ。
（例: render_slides.sh 既存デッキ.pptx frames/ → extract_brand_colors.py frames/）

出力: 使用頻度順の色一覧。白・ほぼ白は既定で除外する（背景色のため）。
"""
import argparse
import glob
import os
from collections import Counter


def quantize(rgb, step=8):
    """近い色をまとめる（アンチエイリアスによる微妙な差異を吸収）。"""
    return tuple((c // step) * step for c in rgb)


def is_near_white(rgb, threshold=245):
    return all(c >= threshold for c in rgb)


def is_near_black(rgb, threshold=12):
    return all(c <= threshold for c in rgb)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("images_dir", help="スライド画像のディレクトリ（render_slides.shの出力）")
    ap.add_argument("--top", type=int, default=12, help="表示する色数（既定12）")
    ap.add_argument("--min-ratio", type=float, default=0.005, help="この割合未満の色は無視（既定0.5%）")
    ap.add_argument("--include-white", action="store_true", help="白系も含める")
    ap.add_argument("--sample-step", type=int, default=4, help="何ピクセルおきに見るか（既定4。大きいほど速い）")
    ap.add_argument("--quantize-step", type=int, default=8,
                     help="色をまとめる粗さ（既定8）。小さいほど原色に近い値が出るが、"
                          "アンチエイリアスで似た色が分散する")
    args = ap.parse_args()

    from PIL import Image

    paths = sorted(glob.glob(os.path.join(args.images_dir, "*.jpg")) +
                    glob.glob(os.path.join(args.images_dir, "*.png")))
    if not paths:
        raise SystemExit(f"ERROR: {args.images_dir} に画像が見つかりません")

    counter = Counter()
    total = 0
    for p in paths:
        img = Image.open(p).convert("RGB")
        w, h = img.size
        px = img.load()
        for y in range(0, h, args.sample_step):
            for x in range(0, w, args.sample_step):
                rgb = px[x, y]
                if not args.include_white and is_near_white(rgb):
                    continue
                if is_near_black(rgb):
                    continue
                counter[quantize(rgb, args.quantize_step)] += 1
                total += 1

    if total == 0:
        raise SystemExit("ERROR: 有効なピクセルが見つかりませんでした")

    print(f"対象画像: {len(paths)}枚 / サンプル画素数: {total:,}\n")
    print(f"{'順':>2}  {'16進':<8} {'RGB':<16} {'使用率':>7}")
    print("-" * 40)
    for i, (rgb, count) in enumerate(counter.most_common(args.top * 3), start=1):
        ratio = count / total
        if ratio < args.min_ratio:
            break
        if i > args.top:
            break
        hexcode = "%02X%02X%02X" % rgb
        print(f"{i:>2}  {hexcode:<8} {str(rgb):<16} {ratio*100:>6.2f}%")

    print("\nヒント: 上位の色をスライド生成スクリプトのパレット定義に貼り付けて使う。")
    print("        面積の大きい色＝地の色・アクセント色。文字色は使用率が低めに出る。")
    print(f"        値は{args.quantize_step}刻みに丸めた近似値。原色に近づけたい場合は")
    print("        --quantize-step 2 などで細かくするか、画像編集ソフトのスポイトで確認する。")


if __name__ == "__main__":
    main()
