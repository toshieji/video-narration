"""pptxの各スライドに、対応するナレーション音声をクリック再生アイコンとして埋め込む。
Google Slides APIには音声挿入機能が無いため、ローカルpptxをpython-pptxで直接編集する。

使い方:
  uvx --from python-pptx python embed_audio.py <input.pptx> <audio-dir> <output.pptx> \
      [--position bottom-right] [--icon-size 0.4] [--inset 0.15] [--audio-ext mp3]

入力の命名規則: audio-dir/slideNN_*.<audio-ext> をスライド番号NNで対応付ける。

重要な注意（実機PowerPoint検証済みの知見）:
  - python-pptxの add_movie() は、音声ファイルであっても内部的に OOXML の
    <a:videoFile> 要素を書き込む。これは一見誤りに見えるが、実は**これが正しい**。
    現代のPowerPointは音声・動画の埋め込みに同じ <a:videoFile> / relationships-video
    を使う仕様になっている。
  - 過去に <a:videoFile> を <a:audioFile>（DrawingMLスキーマ上は存在する要素）へ
    書き換える「修正」を試みたが、実機PowerPoint for Macで検証したところ、
    音声専用の「再生」タブ・コントロールが表示されなくなり、単なる画像として
    扱われる状態に**悪化**した。そのため fix_audio_element() は記録として
    残しているが、絶対に呼び出さないこと。
  - PowerPoint本体の「ビデオとしてエクスポート」機能は、このスクリプトで埋め込んだ
    クリック再生アイコンだけでは正しく機能しない（各スライドの表示時間を実際の
    音声の長さに自動で合わせてくれない＝アプリのデフォルト秒数で切り替わってしまう）。
    ナレーション動画そのものを作る場合は、代わりに build_video.sh で直接mp4を
    組み立てること。このスクリプトはあくまで「クリックで再生できるpptx」を
    別途配布したい場合の並行した成果物であり、動画作成の前提ではない。
"""
import argparse
import glob
import os
import re
import zipfile

from pptx import Presentation
from pptx.util import Inches


def fix_audio_element(pptx_path):
    """【使用しないこと】add_movie()が書き込む<a:videoFile>/relationships-videoを
    <a:audioFile>/relationships-audioに書き換える。実機PowerPoint for Macで
    検証した結果、これを行うと音声として認識されなくなる（再生タブが消え、
    ただの画像として扱われる）ことが確認済み。「やってはいけないことの記録」
    として関数定義のみ残す。"""
    tmp_path = pptx_path + ".tmp"
    with zipfile.ZipFile(pptx_path, "r") as zin:
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                data = zin.read(item.filename)
                if re.match(r"ppt/slides/slide\d+\.xml$", item.filename):
                    data = data.replace(b"<a:videoFile r:link=", b"<a:audioFile r:link=")
                elif re.match(r"ppt/slides/_rels/slide\d+\.xml\.rels$", item.filename):
                    data = data.replace(
                        b'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/video"',
                        b'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/audio"',
                    )
                zout.writestr(item, data)
    os.replace(tmp_path, pptx_path)


def compute_position(slide_width, slide_height, icon_size_emu, inset_emu, position):
    if position == "bottom-right":
        left = slide_width - icon_size_emu - inset_emu
        top = slide_height - icon_size_emu - inset_emu
    elif position == "bottom-left":
        left = inset_emu
        top = slide_height - icon_size_emu - inset_emu
    elif position == "top-right":
        left = slide_width - icon_size_emu - inset_emu
        top = inset_emu
    elif position == "top-left":
        left = inset_emu
        top = inset_emu
    else:
        raise ValueError(f"未知の --position: {position}")
    return left, top


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input_pptx")
    ap.add_argument("audio_dir")
    ap.add_argument("output_pptx")
    ap.add_argument("--position", default="bottom-right",
                     choices=["bottom-right", "bottom-left", "top-right", "top-left"])
    ap.add_argument("--icon-size", type=float, default=0.4, help="アイコンの一辺（インチ、既定0.4）")
    ap.add_argument("--inset", type=float, default=0.15, help="スライド端からの余白（インチ、既定0.15）")
    ap.add_argument("--audio-ext", default=None,
                     help="音声ファイルの拡張子（既定: mp3を優先し、無ければwavを自動使用）")
    args = ap.parse_args()

    # 拡張子ごとのMIMEタイプ。add_movie()に正しい値を渡さないとPowerPointが再生できない
    MIME_BY_EXT = {"mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4"}

    if args.audio_ext:
        exts = [args.audio_ext.lstrip(".").lower()]
    else:
        # generate_tts.sh はwavを出力し、mp3は任意の後段変換。両方に対応する
        exts = ["mp3", "wav"]

    audio_map = {}
    used_ext = None
    for ext in exts:
        files = sorted(glob.glob(os.path.join(args.audio_dir, f"slide*.{ext}")))
        found = {}
        for f in files:
            m = re.match(r"slide(\d+)_", os.path.basename(f))
            if not m:
                continue
            num = int(m.group(1))
            if num in found:
                raise SystemExit(
                    f"ERROR: スライド{num}の音声が複数あります: "
                    f"{os.path.basename(found[num])} と {os.path.basename(f)}"
                )
            found[num] = f
        if found:
            audio_map = found
            used_ext = ext
            break

    if not audio_map:
        pattern = " または ".join(f"slideNN_*.{e}" for e in exts)
        raise SystemExit(f"ERROR: {args.audio_dir} に {pattern} が見つかりません")

    mime_type = MIME_BY_EXT.get(used_ext)
    if not mime_type:
        raise SystemExit(
            f"ERROR: 拡張子 .{used_ext} のMIMEタイプが不明です。"
            f"対応: {', '.join(MIME_BY_EXT)}"
        )
    print(f"音声形式: .{used_ext}（{mime_type}）")

    prs = Presentation(args.input_pptx)
    n_slides = len(prs.slides)

    missing = [n for n in range(1, n_slides + 1) if n not in audio_map]
    extra = [n for n in audio_map if n > n_slides]
    if missing:
        raise SystemExit(f"ERROR: 音声ファイルが見つからないスライド: {missing}")
    if extra:
        print(f"WARNING: スライド数({n_slides})を超える番号の音声ファイルがあります（無視します）: {extra}")

    icon_size_emu = Inches(args.icon_size)
    inset_emu = Inches(args.inset)

    for i, slide in enumerate(prs.slides, start=1):
        audio_path = audio_map[i]
        left, top = compute_position(prs.slide_width, prs.slide_height, icon_size_emu, inset_emu, args.position)
        slide.shapes.add_movie(
            audio_path,
            left,
            top,
            icon_size_emu,
            icon_size_emu,
            mime_type=mime_type,
        )
        print(f"slide {i:02d}: {os.path.basename(audio_path)} を埋め込み")

    out_parent = os.path.dirname(os.path.abspath(args.output_pptx))
    os.makedirs(out_parent, exist_ok=True)
    prs.save(args.output_pptx)
    print(f"\n完了: {args.output_pptx}")


if __name__ == "__main__":
    main()
