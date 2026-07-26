---
name: video-narration
description: スライド台本からAIナレーション動画・音声入りPowerPointを作る。台本→Gemini TTS音声生成→Whisper検証→ffmpeg動画組み立て→pptx音声埋め込みの6ステージ。ナレーション動画・研修動画・コース動画を作りたいときに使う。
---

# video-narration — AIナレーション動画制作メソドロジー

スライド台本から、ナレーション音声付き動画とPowerPointを作る手順とルール。WACA上級ウェブ解析士の動画制作で実践したノウハウを一般化。

## 0. 入力
- **スライド台本（Part台本）**: `## スライドN（ラベル）` 見出し＋フェンスコードブロックの形式のMarkdown。1ファイルに複数スライド分のブロックを含めてよい。
- **スライドデッキ**: `.pptx`（各スライドの見た目を画像化するために使う）。
- **Gemini APIキー**（`.env`）。
- （あれば）**既存の収録動画・既存デッキ**: 台本の土台とデザインの参照元にする。

## 0.5 素材づくり（既存資産がある場合に先行する工程）

台本もスライドもゼロから作るとは限らない。過去の収録動画・既存デッキがあるなら、まずそれを素材にする。

1. **既存動画から素材を抽出**: `scripts/extract_source_video.sh <動画|URL> <out-dir>`
   文字起こし（`transcript.txt`）と、画面が切り替わった箇所のスライド画像が得られる。過去の語り口・実際に使った事例をそのまま引き継げる。
   **古い動画には廃止された制度の説明が混じっていることがある**（実例あり）。鮮度は必ず確認する。
2. **既存デッキのトーンを取る**: `scripts/render_slides.sh 既存.pptx frames/` → `uvx --from pillow python scripts/extract_brand_colors.py frames/`
   実際に使われている色が頻度順に出る。目分量で選ばず、この値をスライド生成スクリプト（pptxgenjs等）のパレットに使う。
3. **スライドから台本を起こす**: `/draft-narration-script`
   スライドを1枚ずつ見ながら、**書かれていないこと**（一番伝えたいこと・具体例・前後のつなぎ）だけを質問する。一度に全部聞かない。既存の文字起こしがあれば該当箇所を引用しながら進める。

## 1. 命名規則（全ステージ共通の契約）
`slideNN_label.<ext>` — NNは2桁ゼロ埋めのスライド番号（デッキ全体を通した通し番号）、labelは短いラベル、拡張子は`.txt`（原稿）/`.wav`/`.mp3`（音声）/`.jpg`（画像）。全スクリプトがこの番号でファイルを突き合わせる。

## 2. ワークフロー

1. **台本を分割**: `python3 scripts/split_narration.py <台本.md> <out-dir>` でスライド単位のテキストに分割。読み上げに不要なMarkdown装飾（太字等）は台本の時点で除いておく。
2. **読み間違えを事前に潰す**: 固有名詞・読みが割れる漢字語は、この時点で**原稿だけ**ひらがなに書き換える（実例: 「対になる」→「たいになる」）。人間向けの台本本体は漢字表記のまま変えない。
3. **音声生成**: 各テキストに対し `scripts/generate_tts.sh <text> <wav> --env-file <.env>` を実行。**声を統一したい場合は全クリップを同じ`.env`設定で作り直すこと**——手動生成分やAI Studio UI経由の生成が1件でも混じると聞き比べたときに声が変わって聞こえる。
4. **1クリップずつ検証**: `uvx --from mlx-whisper python scripts/verify_narration.py <wav> <text>`。**絶対に複数クリップ・長尺音声をまとめて検証しない**（Whisperが無音区間や長尺化で架空の文言を生成することがある——実例: 完全な無音区間に対し英単語「partnerships」が5回連続で出力された）。
5. **グリッチが検出されたらリトライ**: 同一の入力テキストで手順3を再実行する（自動リトライはスクリプトに内蔵していない——多くは1〜2回のリトライで解消するが、まれに3〜4回かかる。何度やっても同じグリッチが出る場合は、原稿テキスト自体に問題がある可能性を疑うこと）。
6. **スライドを画像化**: `scripts/render_slides.sh <deck.pptx> <images-dir>`。
7. **動画を直接組み立てる**: `scripts/build_video.sh <images-dir> <audio-dir> <output.mp4> --gap <秒数>`。**PowerPoint本体の「ビデオとしてエクスポート」には頼らない**——クリック再生用の音声アイコンだけでは、各スライドの表示時間が実際の音声長ではなくアプリのデフォルト秒数になってしまう。
8. **完成動画を機械検証**: `scripts/review_video.sh <output.mp4> --gap-expected <手順7と同じ秒数>`。全スライド切替の間隔をsilencedetectで列挙し、意図した間隔から外れていないか確認する。フレームも抽出されるので、内容がスライド番号と一致しているか目視確認する。
9. **（任意）pptxへの埋め込み**: `uvx --from python-pptx python scripts/embed_audio.py <deck.pptx> <audio-dir> <output.pptx>`。クリック再生できるpptxを別途配布したい場合の並行成果物（手順7の動画の代わりにはならない）。

## 3. 品質保証の原則

- **検証は必ず機械的に行う**（目視だけに頼らない）。Whisperでの文字起こし突き合わせ、silencedetectでの間隔測定、volumedetectでの無音確認——これらは全て今回のセッションで実際にバグを発見した手法そのもの。
- **1件ずつ検証する**。長い単位（複数スライド、動画全体）でまとめて検証すると、検証ツール自体（Whisper）が誤った結果を返すことがある。
- **リトライは同一入力で行う**。TTSのサンプリングランダム性による偶発的なグリッチと、原稿テキスト自体の問題（発音しづらい表現等）を区別するため。

## 4. 既知の落とし穴（詳細は `README.md` のトラブルシューティング参照）

| 症状 | 原因 | 対処 |
| :-- | :-- | :-- |
| 音声で文が繰り返される／定型句が付加される／文字列が混入する | Gemini TTSのサンプリングによる偶発的グリッチ | 同一テキストでリトライ（`generate_tts.sh`） |
| 長い音声を検証すると存在しない文言が出る | Whisperの長尺音声幻覚 | 1クリップずつ検証（`verify_narration.py`の設計そのもの） |
| PowerPointの「ビデオとしてエクスポート」でスライドが全部同じ長さになる | クリック再生アイコンには録画タイミング情報が無い | `build_video.sh`で直接動画を組み立てる |
| ffmpegで組み立てた動画のスライド切替が意図した間隔より長い（例: 2秒指定が実際4秒に） | `-shortest`が静止画ループ＋長尺音声で不正確 | `-t`で長さを明示指定（`build_video.sh`は対応済み） |
| 動画の結合部分に微小なノイズが残る | concat demuxerでのストリームコピー | 再エンコードして結合（`build_video.sh`は対応済み） |
| pptxの音声アイコンがPowerPointで認識されない（再生タブが出ない） | `<a:videoFile>`を`<a:audioFile>`に「修正」してしまった | `<a:videoFile>`のままにする（`embed_audio.py`の`fix_audio_element()`は絶対に呼ばない） |

## 関連
- 既存動画→素材抽出: `scripts/extract_source_video.sh`
- 既存デッキ→使用色抽出: `scripts/extract_brand_colors.py`
- 台本→テキスト分割: `scripts/split_narration.py`
- 音声生成: `scripts/generate_tts.sh`
- 検証: `scripts/verify_narration.py`
- 画像化: `scripts/render_slides.sh`
- 動画組み立て: `scripts/build_video.sh`
- pptx埋め込み: `scripts/embed_audio.py`
- 完成動画レビュー: `scripts/review_video.sh`
- コマンド: `/draft-narration-script`、`/generate-narration-audio`、`/assemble-narrated-video`
