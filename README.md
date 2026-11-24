# video-narration プラグイン

スライド台本から、**AIナレーション音声付き動画**と**音声入りPowerPoint**を作る一連のパイプライン（台本→TTS音声生成→Whisper検証→動画組み立て→PowerPoint音声埋め込み）を、任意のエージェントから再利用できる形にまとめたもの。

WACA上級ウェブ解析士 事前課題オリエンテーション動画の制作で実践したノウハウを一般化。第三者がそのまま導入できる。

## できること

**素材づくり（既存資産がある場合）**
1. 既存の収録動画から文字起こしとスライド画像を抽出（`scripts/extract_source_video.sh`）
2. 既存デッキから使用色を抽出し、新しいスライドをトーンに合わせる（`scripts/extract_brand_colors.py`）
3. スライドを見ながら1枚ずつ質問して台本を作る（`/draft-narration-script`）

**動画づくり**
4. 台本からスライド単位のテキストを一括抽出（`scripts/split_narration.py`）
5. Gemini TTSで音声生成（`scripts/generate_tts.sh`）
6. Whisperで1クリップずつ検証（既知グリッチパターンの自動検出、`scripts/verify_narration.py`）
7. スライドを画像化（`scripts/render_slides.sh`）し、画像＋音声から動画を直接組み立て（`scripts/build_video.sh`）
8. pptxへ音声をクリック再生アイコンとして埋め込み（`scripts/embed_audio.py`）
9. 完成動画の多点レビュー（フレーム抽出＋間隔タイミングの機械検証、`scripts/review_video.sh`）

## 対応エージェント／固定要素
- **swappable（何を使ってもよい）**: パイプラインを実行するエージェント自体。各ステージはプレーンなbash/curl/ffmpeg/python-pptxで、Claude Code固有のAPIには依存しない。Gemini CLI・Codex CLI・Cursor・あるいは人間が直接ターミナルで実行してもよい。`commands/*.md`（スラッシュコマンド）はClaude Code向けの利便レイヤーに過ぎない——他のエージェントには、この`README.md`と`skills/video-narration/SKILL.md`をそのまま読ませればよい。
- **fixed（音声生成エンジン）**: Gemini の `generateContent` TTS エンドポイントが実際に声を生成する部分。プロバイダを差し替える（例: ElevenLabs、OpenAI TTS）にはスクリプトの書き換えが必要で、本プラグインのスコープ外。
- **fixed（現実的な制約）**: 検証（Stage3）で使う`mlx-whisper`はApple Silicon専用。Mac以外の環境ではStage3はそのままでは動かない。
- **fixed（外部ツール、同梱していない）**: ffmpeg / LibreOffice（`soffice`）/ poppler（`pdftoppm`）/ `uv`（`uvx`）。事前にインストールが必要。

## パイプライン

### Stage 0a: 既存動画から素材を抽出（`extract_source_video.sh`）
```
extract_source_video.sh <動画ファイル|URL> <out-dir> [--scene-threshold 0.08]
```
過去に収録した講座動画がある場合、その文字起こしとスライド画像を取り出して台本の土台にする。語り口・実際に使った事例・言い回しを引き継げる。

**注意**: 古い動画には**現在は廃止された制度の説明**が含まれていることがある（実例あり）。内容の鮮度は必ず確認すること。

### Stage 0b: 既存デッキのトーンに合わせる（`extract_brand_colors.py`）
```
uvx --from pillow python scripts/extract_brand_colors.py <images-dir> [--top 12]
```
既存デッキを`render_slides.sh`で画像化し、実際に使われている色を頻度順に抽出する。目分量で色を選ばず、実物から取ってスライド生成スクリプト（pptxgenjs等）のパレットに使う。

### Stage 0c: スライドから台本を作る（`/draft-narration-script`）
スライドを1枚ずつ見ながら、書かれていないこと（一番伝えたいこと・具体例・前後のつなぎ）だけを質問して台本を起こす。既存の文字起こしがあれば該当箇所を引用しながら進める。**一度に全部聞かず1枚ずつ**。

### Stage 1: 台本→スライド単位テキスト（`split_narration.py`）
```
python3 scripts/split_narration.py <part-script.md> <out-dir>
```
`## スライドN（ラベル）` 見出し＋フェンスコードブロックの形式のMarkdownから、`slideNN_label.txt` を一括抽出する。標準ライブラリのみ。

### Stage 2: TTS音声生成（`generate_tts.sh`）
```
generate_tts.sh <input.txt> <output.wav> [--voice NAME] [--model NAME] [--env-file PATH]
```
Gemini APIの`generateContent`を直接叩く。**声を統一したい場合は、手動生成した分も含め全クリップを同じ設定で作り直すこと**——一部だけ違う方法・違う声で作ると聞き比べたときに声が変わって聞こえる（制作時に実際に起きた問題）。

### Stage 3: 検証（`verify_narration.py`）
```
uvx --from mlx-whisper python scripts/verify_narration.py <audio.wav> <source.txt> [--threshold 0.70] [--out report.md]
```
**必ず1クリップずつ検証すること。** 長い音声（結合後の動画全体など）をWhisperに一度に通すと、無音区間や長尺化に伴って架空の文言を生成する（hallucination）ことが実際に確認されている——このスクリプトは1音声・1原稿しか受け付けない設計にすることで、この事故を構造的に防いでいる。

### Stage 4: 動画組み立て（`render_slides.sh` + `build_video.sh`）
```
render_slides.sh <deck.pptx> <images-dir> [dpi]
build_video.sh <images-dir> <audio-dir> <output.mp4> [--gap 1.5] [--work-dir DIR] [--force]
```
**PowerPoint本体の「ビデオとしてエクスポート」には頼らない**（後述のトラブルシューティング参照）。各スライドの画像を、対応する音声の実際の長さぶん表示する動画を直接組み立てる。

### Stage 5: PowerPointへの音声埋め込み（`embed_audio.py`）
```
uvx --from python-pptx python scripts/embed_audio.py <input.pptx> <audio-dir> <output.pptx>
```
クリックで再生できる音声アイコンをpptxに埋め込む。音声形式はmp3を優先し、無ければwavを使う（`generate_tts.sh`はwavを出力するため、mp3変換をしていなくてもそのまま動く）。

**Stage4（動画組み立て）とは並行した別の成果物**であり、前提ではない——クリック再生アイコンだけでは動画にはならない。

### Stage 6: 完成動画のレビュー（`review_video.sh`）
```
review_video.sh <video.mp4> --gap-expected 1.5 --expected-slides 23 \
  [--tolerance-pct 20] [--detect-min 秒] [--check-boundaries]
```
フレームを等間隔で抽出（内容の目視確認用）し、`ffmpeg -af silencedetect` で無音区間を列挙して期待値との乖離を報告する。

**`--expected-slides` を必ず渡すこと。** これが無いと「無音区間をいくつか見つけた」だけで、本当に全スライドの切替を検証できたか分からない（ナレーション中の長い間を境界と誤認していても気づけない）。渡すと検出件数とスライド数の整合まで検査する。

検出しきい値は `--gap-expected × 1.05` を既定とする。23枚の実データでは、gap=2秒に対し等倍（×1.0）だと自然な間を2件拾って25件になり、×1.05で正確に23件へ分離できた。分離できない場合は `--detect-min` で直接調整する。

## 既知の問題と対処（トラブルシューティング）

**Gemini TTSのグリッチ**（生成後は必ずStage3で検証し、異常があれば同一テキストでリトライすること。サンプリングのランダム性で解消することが多いが、まれに3〜4回リトライが必要）:
- 原稿にない「ご視聴ありがとうございました」等の定型句を末尾に付加する
- 単語・文字の異常なリピート（実例: 「本日」を70回超、「列」を数百回リピート）
- 既存フレーズを繰り返しつつ文言が変質する（実例: 同じ意味の一文が3回言い換えられる）
- 文中に無関係な文字列・数字が混入する
- 生成自体が失敗する（レスポンスに`parts`が無い＝`generate_tts.sh`がエラー終了）

**読み間違え対策**: 固有名詞・読みが割れる漢字語は、原稿ではひらがなで書く（実例: 「対になる」→「たいになる」）。TTSは漢字の読みを誤ることがある。人間向けの台本本体の漢字表記は変えず、TTSに渡すテキストだけをひらがな化する。

**Whisperの長尺音声幻覚**: 動画全体のような長い音声をWhisperに一度に通すと、実際には存在しない文言を生成することがある（制作時に確認した実例: 完全に無音の区間に対し、英単語「partnerships」が5回連続で出力された。`ffmpeg -af volumedetect` で当該区間が実際には-90dB前後の無音であることを確認して判明）。`verify_narration.py`が1クリップ単位の設計になっているのはこのため。

**TTSモデル名が404する場合**: プレビューモデルのため名前が変わることがある。`https://generativelanguage.googleapis.com/v1beta/models?key=KEY` で `tts` を含むモデル名を確認する。

**`<a:videoFile>`は「修正」しない**: python-pptxの`add_movie()`は音声ファイルでも内部的に`<a:videoFile>`要素を書き込むが、これは仕様どおり正しい（現代のPowerPointは音声・動画の埋め込みに同じ要素を使う）。過去にこれを`<a:audioFile>`へ書き換える「修正」を試みたが、実機PowerPoint for Macで検証したところ、逆に音声として認識されなくなった（再生タブが消え、ただの画像として扱われる）。`embed_audio.py`の`fix_audio_element()`はこの記録として残しているが、絶対に呼び出さないこと。

**PowerPoint「ビデオとしてエクスポート」は代替にならない**: クリック再生用の音声アイコンを埋め込んだだけのpptxをこの機能でエクスポートすると、各スライドの表示時間が実際の音声長ではなくアプリのデフォルト秒数（大抵5秒）になり、ナレーションが最後まで再生されない。この機能は「記録されたタイミング／ナレーション」メタデータ（PowerPoint本体の「スライドショーの記録」機能などで作られるもの）を必要とする。そのため本パイプラインではStage4で動画を直接組み立てる。

**ffmpegの`-shortest`は静止画ループ＋長尺音声で不正確になる**: `-loop 1`の静止画とapadでパディングした長尺音声を組み合わせた際、`-shortest`が意図した長さより一貫して余分に（実測で約1.8〜2秒）長くなるバグを単体テストで確認・再現した（5秒の短いクリップでは正確だが、約55秒のクリップで再現する長さ依存のバグ）。`build_video.sh`では`ffprobe`で実測した長さを`-t`で明示指定することで回避している。

**結合はストリームコピーでなく再エンコードする**: `ffmpeg`のconcat demuxerで`-c copy`を使うと、セグメント境界に約-56dBの微小ノイズが残ることを実測で確認した（完全な無音なら-83〜-91dB程度）。`build_video.sh`では必ず再エンコードして結合する。

## 使い方（クイックスタート）

**素材がある場合の準備（任意）**
- 既存動画から素材を取る: `scripts/extract_source_video.sh <動画|URL> material/`
- 既存デッキの色を調べる: `scripts/render_slides.sh 既存.pptx frames/` → `uvx --from pillow python scripts/extract_brand_colors.py frames/`
- 台本を起こす: `/draft-narration-script <deck.pptx> material/transcript.txt`

**動画づくり**
1. `.env.example` を `.env` にコピーし、`GEMINI_API_KEY` を設定（AI Studio右上「Get API key」）
2. `python3 scripts/split_narration.py <台本.md> <out-dir>` でスライド単位のテキストに分割
3. 各テキストに対し `scripts/generate_tts.sh <text> <wav> --env-file <.envのパス>` を実行
4. 各wavに対し `uvx --from mlx-whisper python scripts/verify_narration.py <wav> <text>` を実行、グリッチが検出されたら同じテキストでStage2をリトライ
5. `scripts/render_slides.sh <deck.pptx> <images-dir>` → `scripts/build_video.sh <images-dir> <audio-dir> <output.mp4> --gap 1.5`
6. `scripts/review_video.sh <output.mp4> --gap-expected 1.5` で全間隔を機械検証
7. （任意）`uvx --from python-pptx python scripts/embed_audio.py <deck.pptx> <audio-dir> <output.pptx>` でクリック再生版pptxも作る

## ファイル構成
```
video-narration/
  .claude-plugin/plugin.json       マニフェスト
  .env.example                     Gemini APIキー等のテンプレート
  commands/draft-narration-script.md     Stage0c: スライドから対話で台本を作る
  commands/generate-narration-audio.md   Stage1-3: 分割→TTS→検証のループ
  commands/assemble-narrated-video.md    Stage4+6: 動画組み立て＋レビュー
  skills/video-narration/SKILL.md  パイプライン全体＋落とし穴の中核ドキュメント
  scripts/extract_source_video.sh  Stage0a: 既存動画→文字起こし＋スライド画像
  scripts/extract_brand_colors.py  Stage0b: 既存デッキ→使用色の抽出
  scripts/split_narration.py       Stage1
  scripts/generate_tts.sh          Stage2
  scripts/verify_narration.py      Stage3
  scripts/render_slides.sh         Stage4a
  scripts/build_video.sh           Stage4
  scripts/embed_audio.py           Stage5
  scripts/review_video.sh          Stage6
```

## 出典・クレジット

一般社団法人ウェブ解析士協会（WACA）の上級ウェブ解析士 事前課題オリエンテーション動画制作（2026-07）で確立した手法を、汎用ツールとして切り出したもの。実際の講座コンテンツ（試験問題・台本等）は含まず、パイプラインのスクリプトとドキュメントのみを公開している。

`reviews/codex_review_20260724.md` に、公開前に受けた第三者レビュー（OpenAI Codex）の指摘と対応記録を収録。

再配布・改変時は出典を明記のこと。
