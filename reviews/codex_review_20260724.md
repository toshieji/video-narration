結論として、現状は「作者・事情を知る担当者なら使える」が、「第三者がREADMEだけで導入して最初の1本を確実に作れる汎用パッケージ」には達していません。特に、ステージ間の命名契約、番号欠落、PowerPoint埋め込み、引数検証にリリース前の修正が必要です。

なお、依頼文では「7本」とありますが、実際の対象は9本あります。

## 致命的

### 1. PowerPoint埋め込みがクイックスタートどおりには動かない

- [README.md:121](README.md:121) は、TTSで生成した音声ディレクトリをそのまま `embed_audio.py` に渡せるように読めます。
- [generate_tts.sh:108](scripts/generate_tts.sh:108) が生成する既定形式はWAVです。
- 一方、[embed_audio.py:86](scripts/embed_audio.py:86) の既定は `--audio-ext mp3`、[embed_audio.py:98](scripts/embed_audio.py:98) はMP3がなければ終了します。
- WAVを明示しても、[embed_audio.py:123](scripts/embed_audio.py:123) が常に `mime_type="audio/mpeg"` を指定するため、WAVをMPEG音声として埋め込みます。

つまりREADMEの最短手順ではStage 5が失敗します。`generate-narration-audio.md` にはMP3変換がありますが、README/SKILLの利用者には保証されません。

修正案は、WAV/MP3を自動判定してMIMEを切り替えるか、Stage 2でMP3も必ず生成し、READMEに明記することです。

### 2. スライド番号の欠落を検出せず、誤った動画を正常終了させる

[build_video.sh:65-95](scripts/build_video.sh:65) は、存在する画像番号だけを収集し、その番号に音声があるかしか確認しません。

例えば以下は成功します。

```text
images/slide01.jpg
images/slide03.jpg
audio/slide01_a.wav
audio/slide03_c.wav
```

`slide02` がなくても2枚の動画として生成されます。SKILLの「デッキ全体を通した通し番号」「全スクリプトが番号で突き合わせる」という契約を満たしません。

少なくとも以下が必要です。

- 番号が1から連続していることを検査
- 同じ番号に複数候補がないことを検査
- 可能ならデッキのスライド数との一致を検査

### 3. 番号の前方一致により別スライドを誤対応する

[build_video.sh:85-86](scripts/build_video.sh:85) と [build_video.sh:102-103](scripts/build_video.sh:102) のパターンは `slide${padded}*` です。

例えば `slide01.jpg` がなく `slide010_title.jpg` がある場合、スライド1の候補としてスライド10を拾う可能性があります。100枚以上では `slide10*` と `slide100*` も衝突します。

番号の直後を `_` または拡張子に限定する正規表現ベースの列挙が必要です。

### 4. レビュー結果が「全スライド間隔の検証」になっていない

[README.md:82](README.md:82) と [SKILL.md:40](skills/video-narration/SKILL.md:40) は「全スライド切替の間隔」を検証すると説明しています。

しかし [review_video.sh:75-109](scripts/review_video.sh:75) は単に長い無音をすべて抽出しており、

- 検出件数が `スライド数 - 1` か確認しない
- ナレーション中の自然な長い間をスライド境界と誤認する
- 最終スライド末尾のgapも境界として扱いうる
- 本来のgapが閾値未満になって消えても、他の自然無音があればOKになりうる

という問題があります。

動画またはビルド時のセグメント境界情報をレビューへ渡さない限り、「全境界を検証した」という判定はできません。現状の `STATUS:OK` は強すぎます。

## 要修正

### 第三者導入・ドキュメント

#### 5. 依存ツールのインストール説明不足は、汎用パッケージとしてはリリースブロッカー

[README.md:25-26](README.md:25) は依存名を列挙するだけです。

初見利用者には少なくとも以下が不明です。

- macOSでの `brew install ffmpeg libreoffice poppler uv yt-dlp`
- Linuxでのパッケージ名とLibreOffice CLI
- `uvx` が `uv` に含まれること
- `curl`、`python3`、`ffprobe` も必要なこと
- バージョン要件
- Apple Silicon以外でStage 3をどう代替・スキップするか
- PATHに `soffice` がない場合の対応
- 依存確認コマンド

専門家向け内部ツールなら許容できますが、「他コース担当者がそのまま導入」という目標では要修正です。`scripts/check_dependencies.sh` のようなpreflightも必要です。

#### 6. READMEだけでは最初の入力台本を正しく作りにくい

[README.md:51](README.md:51) は形式を一文で説明しますが、コピー可能な完全サンプルがありません。

特に実装は以下を要求します。

- 見出しが `## スライドN（ラベル）`
- フェンス開始直後が改行
- フェンスに言語指定がない
- 本文末尾直後に改行して閉じる

最小の `examples/sample-script.md`、サンプル出力名、1～2枚を一括処理するコマンド例が必要です。

#### 7. `.env` は基本形のみで、第三者向け説明として不足

[README.md:115](README.md:115) と [.env.example:1-12](.env.example:1) には次がありません。

- Google AI Studioへの正式なURL
- APIキー取得に必要なアカウント・利用条件
- API/課金・クォータエラーの説明
- `.env` をどのディレクトリに置くかの具体例
- キーをログ・Issueへ貼らない注意
- `.env` がshellコードとして読み込まれること

なお `.env` はリポジトリの `.gitignore` 対象になっており、その点は適切です。

#### 8. 「任意のエージェントで使える」とClaude固有手順が混在

[README.md:23](README.md:23) は任意エージェント対応を掲げますが、[README.md:112](README.md:112) や [SKILL.md:25](skills/video-narration/SKILL.md:25) は `/draft-narration-script` を通常工程として記載しています。

Claude Code以外ではどう代替するか、コマンド文書をプロンプトとして渡すのか、人間が台本を作るのかが明確ではありません。

### Shell共通

#### 9. 値付きオプションの値省略がすべて未処理

以下はいずれも、例えば末尾に `--gap` だけを渡すと `set -u` による `unbound variable` で落ちます。

- [extract_source_video.sh:24-26](scripts/extract_source_video.sh:24)
- [generate_tts.sh:28-30](scripts/generate_tts.sh:28)
- [build_video.sh:27-31](scripts/build_video.sh:27)
- [review_video.sh:26-31](scripts/review_video.sh:26)

利用者には「どのオプションの値がないか」ではなくシェル内部エラーが表示されます。各ケースで `[[ $# -ge 2 ]]` を確認すべきです。

#### 10. 未知のオプションを位置引数として受け入れる

同じ引数パーサーの `*) POSITIONAL+=("$1")` により、`--gpa 2` のようなtypoを拒否しません。結果として引数の順序がずれ、無関係なファイルを入力として扱います。

`--*` は明示エラー、必要なら `--` 以降だけ位置引数、とすべきです。また余分な位置引数も拒否されません。

### `split_narration.py`

#### 11. CRLF、言語付きコードフェンスに弱い

[split_narration.py:28](scripts/split_narration.py:28) は厳密に ```` ```\n ```` を要求します。

以下はスキップされます。

```markdown
```text
本文
```
```

WindowsのCRLFファイルもマッチしません。第三者利用では `\r?\n` と任意のフェンス言語に対応すべきです。

#### 12. 空本文・番号重複・番号飛びを許す

[split_narration.py:54](scripts/split_narration.py:54) は空本文もblockとして採用します。[split_narration.py:75-76](scripts/split_narration.py:75) は同番号・同ラベルがあると無警告で上書きします。

`1,3` の番号飛び、同じ番号の重複、空本文をエラーにすべきです。

#### 13. ファイル名サニタイズが不足

[split_narration.py:31-34](scripts/split_narration.py:31) は空白、`\`、`/` しか除去しません。

ラベルに `:`, `*`, `?`, 引用符、制御文字などが入るとWindowsで作れない、後続のシェルやPython埋め込みで壊れるファイル名になります。

### `generate_tts.sh`

#### 14. shell形式ではない一般的なdotenvを `source` している

[generate_tts.sh:47](scripts/generate_tts.sh:47) は `.env` をshellとして実行します。

例えば以下は安全なdotenvとして見かけますが、shellでは壊れます。

```dotenv
GEMINI_TTS_VOICE=My Voice
```

また、第三者から受け取った `.env` にコマンドがあれば実行されます。「dotenv parser」ではなく「信頼済みshellファイル」であることを明記するか、安全にキーだけ解析すべきです。

#### 15. Pythonコードへの直接補間で引用符を含む値が壊れる

[generate_tts.sh:66-78](scripts/generate_tts.sh:66) はvoice名をPythonソースへ直接展開しています。voiceに `'''` 等が入れば構文エラーまたはコード注入になります。

[generate_tts.sh:87-105](scripts/generate_tts.sh:87) も一時パスをPythonソースへ埋め込んでいます。引数または環境変数経由で渡すべきです。

#### 16. HTTPエラーと不正レスポンスの扱いが不十分

[generate_tts.sh:81-84](scripts/generate_tts.sh:81) の `curl` は `--fail-with-body`、タイムアウト、リトライを指定していません。

- 429/500でもcurl自体は成功扱い
- HTMLエラーの場合、後段でJSON例外
- 通信が止まると無期限待機
- APIキーがURL queryに入り、プロセス一覧等から見える可能性

API固有エラーを構造化して表示する必要があります。

#### 17. 空原稿をAPIへ送る

[generate_tts.sh:52-65](scripts/generate_tts.sh:52) はファイルの存在しか確認しません。0バイトまたは空白のみの原稿も送信します。

### `extract_source_video.sh`

#### 18. ローカルファイルのtypoをURLとして扱う

[extract_source_video.sh:39-50](scripts/extract_source_video.sh:39) はファイルでなければすべて `yt-dlp` に渡します。

`lectrue.mp4` のようなtypoもURL扱いになり、原因が分かりにくいエラーになります。URLスキームを検査すべきです。

#### 19. 既存の別URLのダウンロード結果を無条件再利用する

[extract_source_video.sh:43-45](scripts/extract_source_video.sh:43) は `out-dir/source.*` が一つでもあれば、今回指定したURLと無関係でも再利用します。

同じ出力ディレクトリで別動画を指定すると、古い動画の文字起こし・画像を正常に生成します。URLまたは入力の識別情報を保存して照合すべきです。

#### 20. シーン画像を先に破壊してから再生成する

[extract_source_video.sh:68](scripts/extract_source_video.sh:68) は既存PNGを消してからffmpegを実行します。ffmpegが失敗すると以前の正常出力も失われます。

一時ディレクトリへ生成し、成功後に置換する方が安全です。

### `render_slides.sh`

#### 21. `.pptx` 以外の任意ファイルをLibreOfficeへ渡す

[render_slides.sh:22-35](scripts/render_slides.sh:22) は小文字 `.pdf` 以外をすべてPPTX扱いします。

`.txt`、`.jpg`、`.PDF`、拡張子なしもLibreOfficeへ渡されます。文書の契約どおり `.pptx`/`.pdf` を明示検証すべきです。

#### 22. 出力先に古いスライド画像が残る

[render_slides.sh:48](scripts/render_slides.sh:48) は生成画像をコピーするだけです。

以前10枚のデッキを出力したディレクトリへ8枚のデッキを再出力すると、`slide09.jpg` と `slide10.jpg` が残り、`build_video.sh` は10枚として扱います。

### `build_video.sh`

#### 23. `--work-dir` 再利用時、変更済み入力を無視する

[build_video.sh:106-109](scripts/build_video.sh:106) はセグメントが存在すれば、音声・画像・gap・FPS・解像度が変わっていても再利用します。

利用者が音声を修正して再実行しても、`--force` を忘れると古い音声の動画が完成します。mtimeまたは入力ハッシュ・設定manifestによる無効化が必要です。

#### 24. 複数候補を無警告で1件だけ選ぶ

[build_video.sh:85-86](scripts/build_video.sh:85) は、同番号のWAV/MP3や複数ラベルがあっても `head -1` で選びます。どれが選ばれるかはファイル列挙順に依存します。

重複はエラーにすべきです。

#### 25. 数値引数を検証していない

`--gap -1`、`--fps 0`、`--resolution abc` などを受け入れ、Pythonやffmpeg内部の分かりにくいエラーになります。数値範囲を事前検証すべきです。

### `verify_narration.py`

#### 26. 空音声・空原稿、しきい値範囲を検査しない

[verify_narration.py:66-75](scripts/verify_narration.py:66) は存在だけを確認します。

- 0バイト音声
- 空原稿
- `--threshold -1`
- `--threshold 2`

を受け入れます。`--out` の親ディレクトリも [verify_narration.py:118-120](scripts/verify_narration.py:118) では作りません。

#### 27. リピート検出の説明と実装範囲が一致しない

[verify_narration.py:35-43](scripts/verify_narration.py:35) が検出するのは「14～120文字の同一部分文字列が直後に2回続く場合」だけです。

見逃す例：

- 間に読点や空白が入る
- Whisperが各反復で一文字ずつ誤認する
- 同じ意味の言い換え反復
- 離れた位置での反復
- 反復単位が長すぎる

READMEの「既知グリッチパターンの自動検出」は、もう少し限定的に説明すべきです。

#### 28. 英単語混入検出は誤検知しやすい

[verify_narration.py:46-47](scripts/verify_narration.py:46) と [verify_narration.py:89-91](scripts/verify_narration.py:89) は、原稿にない4文字以上のASCII語をすべて異常扱いします。

日本語原稿の「エーアイ」をWhisperが `AI` とする場合は短いため見逃し、固有名詞を英語綴りで正常認識した場合は誤検知します。これはFAIL条件ではなく「要レビュー」の補助情報にする方が妥当です。

### `review_video.sh`

#### 29. 引用符を含むパスでPythonコードが壊れる

[review_video.sh:50-59](scripts/review_video.sh:50)、[review_video.sh:77-109](scripts/review_video.sh:77)、[review_video.sh:117-136](scripts/review_video.sh:117) はパスや数値をPythonソースへ直接埋め込みます。

日本語・通常のスペースは概ね通りますが、例えば動画名が `teacher's video.mp4` ならPython構文エラーになります。値は `sys.argv` 経由で渡すべきです。

#### 30. `--frames 0`、`--gap-expected 0` 等を検証しない

[review_video.sh:50-58](scripts/review_video.sh:50) では `--frames 0` が除算エラー、[review_video.sh:97](scripts/review_video.sh:97) では `--gap-expected 0` がゼロ除算になります。

### `embed_audio.py`

#### 31. 重複音声を無警告で上書きする

[embed_audio.py:89-95](scripts/embed_audio.py:89) で、同じ番号の音声が複数あると後のファイルが無警告で採用されます。

#### 32. 出力先ディレクトリを作らない

[embed_audio.py:127](scripts/embed_audio.py:127) は `dist/output.pptx` の `dist` がなければ失敗します。

#### 33. アイコン寸法の範囲を検証しない

負の `--icon-size`、スライドより大きいサイズ、負の `--inset` が通り、不正な位置・寸法になります。

## 改善提案

### 34. `verify_narration.py` の1ファイル設計自体は妥当。ただしバッチランナーを別に持つべき

1回のWhisper呼び出しを1クリップに限定する判断は妥当です。問題は「1ファイルAPI」と「利用者が1件ずつ手作業すること」を同一視している点です。

例えば次の二層構造が適切です。

- `verify_narration.py`: 現状どおり1ペアを検査
- `verify_all.py audio-dir text-dir`: 番号を対応付け、各クリップを個別プロセスで順番に検査し、集計レポートを生成

これなら長尺Whisperを避けながら使い勝手を改善できます。

### 35. `--gap 1.5` は普遍的な既定値として根拠が弱い

[build_video.sh:17](scripts/build_video.sh:17) の1.5秒は、落ち着いた研修動画では妥当な場合がありますが、短いスライドでは間延びし、テンポの速い動画では長すぎます。

また、現在は最終スライドにも同じgapを追加します。以下を検討すべきです。

- 既定を1.0秒程度にする、または明示指定必須
- `--final-gap` を分離
- コース用途別の推奨値を文書化
- 冒頭無音除去後の試聴で決める

### 36. macOS依存はmlx-whisper以外にも運用上残っている

コード上の主要な明示依存はmlx-whisperですが、実運用では次があります。

- [extract_source_video.sh:50](scripts/extract_source_video.sh:50) がChromeのcookie storeを暗黙に利用
- LibreOfficeの `soffice` のPATHはOS・導入方法により異なる
- `python3` が存在しない、または古い環境がある
- `uvx --from ... python` の挙動をuvの対応バージョンに固定していない
- `mlx-whisper` 非対応環境にCPU/CUDA Whisperへの切替口がない

`PYTHON` はgenerate_ttsだけが尊重し、build/reviewは直接 `python3` を呼んでいるため一貫していません。

### 37. 禁止事項3点は現在の実装では守られている

この点は問題ありません。

- `-shortest`: [build_video.sh:122-133](scripts/build_video.sh:122) は `-t` を使用
- ストリームコピー: [build_video.sh:139-145](scripts/build_video.sh:139) は映像・音声を再エンコード
- `<a:videoFile>`書き換え: `fix_audio_element()` は [embed_audio.py:37](scripts/embed_audio.py:37) に定義されるだけで呼ばれていない

ただし「絶対に呼ばない関数」を配布コードに残すのは将来の誤用リスクです。ドキュメントまたはテストfixtureへ移し、実行コードから削除する方が安全です。

## 優先順位

リリース前に最低限直す順序は以下です。

1. ファイル命名・番号連続性・重複検査を共通化
2. WAV/MP3と`embed_audio.py`の契約を統一
3. `review_video.sh`のOK判定を境界情報ベースへ変更
4. shell引数パーサーの値省略・未知オプション対応
5. stale出力・`--work-dir`キャッシュの無効化
6. 依存インストール、preflight、完全な最小サンプルを追加
7. Pythonへの文字列直接補間をすべて引数渡しへ変更
8. クリップ単位を維持した一括TTS・一括検証ランナーを追加

現段階でREADMEを読んだ初見利用者が「動画MP4だけ」を作れる可能性はありますが、入力形式や依存を自力で補完できる技術者に限られます。MP4・検証・音声入りPPTXまでを一貫して確実に生成する第三者向けパッケージとしては、まだ要修正です。
---

# 対応記録（2026-07-24）

## 修正済み

| # | 指摘 | 対応 |
| :-- | :-- | :-- |
| 1 | WAV/MP3の契約不整合でクイックスタートが動かない | `embed_audio.py`をmp3優先・wavフォールバックの自動判定にし、MIMEタイプも拡張子に応じて切替。wavのみの入力で動作確認済み |
| 2 | スライド番号の飛びを検出しない | `build_video.sh`に1からの連番検査を追加。欠番を列挙してエラー終了することを実測確認 |
| 3 | 前方一致で別スライドを誤対応（slide01→slide010） | 番号直後を`_`か`.`に限定する正規表現照合に変更。拡張子は指定順に優先（wav/mp3両方ある場合は重複扱いしない） |
| 4 | レビューが「全間隔の検証」になっていない | `--expected-slides`を追加し、検出件数とスライド数の整合を検査。未指定時は「未確認」と明示。検出しきい値の既定を×0.85→×1.05に修正（実データで25件→23件に正しく分離） |
| 9 | 値付きオプションの値省略が未処理 | `need_value()`で検証し、シェル内部エラーでなく明示メッセージを出す（generate_tts / build_video / review_video） |
| 10 | 未知のオプションを位置引数として受け入れる | `--*`を明示エラーに |
| 15 | Pythonソースへの直接補間 | `generate_tts.sh`・`review_video.sh`とも`sys.argv`／heredoc経由に変更 |
| 16 | HTTPエラーの扱いが不十分 | `--connect-timeout`/`--max-time`/`--retry`を追加。HTTPコード別のメッセージを出力。APIキーをURLからヘッダへ移動 |
| 17 | 空原稿をAPIへ送る | 空・空白のみを事前に検出してエラー |
| 32 | 出力先ディレクトリを作らない | `embed_audio.py`で親ディレクトリを自動作成 |
| — | （レビュー外で発見）出力パスを相対指定すると結合時に壊れる | 結合前に絶対パスへ解決 |
| — | （レビュー外で発見）bash 3.2で`${arr[-1]}`が動かない | 添字計算に変更（macOS標準bash対応） |

## 未対応（既知の制約として記録）

以下は妥当な指摘だが、現時点では未対応。利用者が増えた段階で対応する。

- **#5 依存ツールのインストール手順**：READMEに列挙のみ。`check_dependencies.sh`のようなpreflightは未整備
- **#6 台本の完全サンプル**：`examples/sample-script.md`が無い
- **#11-13 `split_narration.py`の堅牢性**：CRLF・言語付きコードフェンス・空本文・番号重複・ファイル名サニタイズ
- **#14 `.env`をshellとして`source`している**：値に空白があると壊れる。信頼済みファイルである前提
- **#18-22 `extract_source_video.sh`/`render_slides.sh`の入力検証・stale出力**
- **#23 `--work-dir`再利用時に入力変更を検知しない**：`--force`を忘れると古い音声のまま完成する
- **#25/#30/#33 数値引数の範囲検証**
- **#27/#28 グリッチ検出ヒューリスティックの限界**：見逃し・誤検知あり。READMEの「自動検出」は限定的に理解すること
- **#34 一括検証ランナー**：1件ずつの設計は維持しつつ、番号を突き合わせて順次実行する`verify_all.py`があると使い勝手が良い
- **#36 macOS依存**：`PYTHON`環境変数を`generate_tts.sh`のみが尊重しており一貫していない

なお **#37（禁止事項3点が実装で守られているか）はCodexも「問題なし」と確認**。
