---
description: スライド画像＋ナレーション音声から動画を組み立て、多点レビューする
argument-hint: <deck.pptx> <audio-dir> <output.mp4> [間隔秒数=1.5]
---

`video-narration` スキルの手順に従って、完成した音声からナレーション動画を組み立てる。

引数: $ARGUMENTS
- 第1引数: スライドデッキ（`.pptx`）
- 第2引数: 音声ディレクトリ（`slideNN_*.wav`または`.mp3`が揃っていること。`/generate-narration-audio`で作った出力）
- 第3引数: 出力する動画ファイルのパス
- 第4引数（省略可）: スライド間の間隔（秒）。既定1.5秒

手順:
1. `skills/video-narration/SKILL.md` の「既知の落とし穴」を確認する（特に`-shortest`とストリームコピー結合の問題——`build_video.sh`は対応済みだが、なぜその実装になっているかを理解しておく）。
2. `scripts/render_slides.sh <deck.pptx> <images-dir>` でスライドを画像化する。
3. 画像側のスライド数と音声側のファイル数が一致しているか確認する（一致しなければ`build_video.sh`がエラーで教えてくれるので、欠けているスライドを`/generate-narration-audio`で埋める）。
4. `scripts/build_video.sh <images-dir> <audio-dir> <output.mp4> --gap <間隔秒数>` で動画を組み立てる。
5. `scripts/review_video.sh <output.mp4> --gap-expected <手順4と同じ間隔秒数> --check-boundaries` を実行し、
   - 抽出されたフレーム画像を実際に開いて、スライド番号と内容が一致しているか確認する（このコマンド自身は画像の中身を判断できないため、必ず目視すること）
   - 間隔の乖離レポートを確認し、`⚠️`が出ている箇所があれば原因を調査する（多くの場合は元の音声ファイル自体に問題がある）
6. 総合判定が`FAIL`の場合は、原因を特定して該当スライドの音声を作り直すか、`--gap`や`--tolerance-pct`の妥当性を見直してから再度4に戻る。
7. （任意）`uvx --from python-pptx python scripts/embed_audio.py <deck.pptx> <audio-dir> <output.pptx>` でクリック再生版pptxも作る。

**動画が完成しても、人間による最終確認（実際に再生して聴く）を推奨する旨を必ず伝えること。** このコマンドの検証は機械的なもの（タイミング・無音判定）であり、音声の自然さや内容の正しさそのものを保証するものではない。
