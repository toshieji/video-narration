---
description: 台本からナレーション音声を一括生成・検証する（分割→TTS→Whisper検証→リトライのループ）
argument-hint: <part-script.md> <out-dir> <.env のパス>
---

`video-narration` スキルの手順に従って、台本からナレーション音声を生成・検証する。

引数: $ARGUMENTS
- 第1引数: Part台本（読み上げ原稿）のMarkdownファイル
- 第2引数: 出力先ディレクトリ（テキスト・音声ファイルをここに書き出す）
- 第3引数: `.env`のパス（`GEMINI_API_KEY`等が設定済みのもの。無ければ`.env.example`をコピーして作成を促す）

手順:
1. `skills/video-narration/SKILL.md` を読み、命名規則と品質保証の原則を把握する。
2. `python3 scripts/split_narration.py <part-script.md> <out-dir>` でスライド単位のテキストに分割する。
3. 分割したテキストを読み、固有名詞・読みが割れる漢字語があればひらがな表記に書き換える（人間向けの台本本体は変えず、分割後のテキストファイルのみ変更）。
4. 各テキストファイルに対して順に:
   a. `scripts/generate_tts.sh <text> <out-dir>/<同名>.wav --env-file <.envのパス>` で音声生成
   b. `uvx --from mlx-whisper python scripts/verify_narration.py <wav> <text>` で検証
   c. グリッチが検出された（非ゼロ終了）場合は、同一テキストでaに戻ってリトライする（最大4回程度を目安に。何度やっても同じ問題が出る場合は原稿テキスト自体を疑い、人間に報告する）
   d. 検証OKになったら次のテキストファイルへ進む
5. wavが揃ったら、`ffmpeg -i <wav> -codec:a libmp3lame -b:a 96k -ac 1 <mp3>` でmp3にも変換しておく（Stage5の pptx 埋め込みや軽量配布用）。
6. 全件の生成・検証結果（各スライドで何回リトライが必要だったか等）をサマリ報告する。

**声の統一に注意**: 一部のクリップだけ手動生成やAI Studio UI経由になっていないか確認する。混在すると聞き比べたときに声が変わって聞こえる。もし混在していたら、全クリップを同じ`.env`設定で作り直すことを提案する。
