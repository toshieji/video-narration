#!/usr/bin/env bash
# Gemini API (Google AI Studio と同じSpeech Generation機能) を直接叩いてナレーション音声を生成する。
# 使い方: generate_tts.sh <入力テキストファイル> <出力wavファイル> [--voice NAME] [--model NAME] [--env-file PATH]
# 例:     generate_tts.sh slide04_限界2.txt audio/slide04_限界2.wav
#
# 事前準備:
#   1. .env.example を .env にコピーし、GEMINI_API_KEY を設定（AI Studio右上「Get API key」）
#   2. GEMINI_TTS_VOICE を、AI Studioで試聴して選んだ声の名前に合わせる
#      （声を統一したい場合、手動生成分も含め全クリップを同じ .env で作り直すこと。
#       一部だけ違う方法・違う声で作ると聞き比べたときに声が変わって聞こえる）
#
# .env の探し方（優先順）: --env-file 指定 > 呼び出し元カレントディレクトリの ./.env > エラー
#   （このスクリプト自身の置き場所とは無関係。プラグインとして別プロジェクトに
#    配置される想定のため、各コースの作業ディレクトリ側の .env を見る）
#
# 注意: モデル名・レスポンス形式はプレビュー機能のため変更されることがある。
#       404になったら https://generativelanguage.googleapis.com/v1beta/models?key=KEY
#       で "tts" を含むモデル名を確認すること。
#       初回は必ず1件だけ試し、Whisperで検証してから量産すること（verify_narration.py）。
set -euo pipefail

ENV_FILE=""
CLI_VOICE=""
CLI_MODEL=""
POSITIONAL=()
need_value() {
  if [[ "$2" -lt 2 ]]; then
    echo "ERROR: $1 には値が必要です" >&2
    exit 1
  fi
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) need_value "$1" $#; ENV_FILE="$2"; shift 2 ;;
    --voice) need_value "$1" $#; CLI_VOICE="$2"; shift 2 ;;
    --model) need_value "$1" $#; CLI_MODEL="$2"; shift 2 ;;
    --*) echo "ERROR: 未知のオプション: $1" >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

TEXT_FILE="${1:?入力テキストファイルを指定してください}"
OUT_WAV="${2:?出力wavファイルパスを指定してください（例: audio/slide04_限界2.wav）}"

if [[ -z "$ENV_FILE" ]]; then
  ENV_FILE="./.env"
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE がありません。.env.example をコピーして GEMINI_API_KEY を設定するか、--env-file でパスを指定してください。" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${GEMINI_API_KEY:?GEMINI_API_KEY が未設定（$ENV_FILE を確認）}"
GEMINI_TTS_VOICE="${CLI_VOICE:-${GEMINI_TTS_VOICE:-Puck}}"
GEMINI_TTS_MODEL="${CLI_MODEL:-${GEMINI_TTS_MODEL:-gemini-3.1-flash-tts-preview}}"

if [[ ! -f "$TEXT_FILE" ]]; then
  echo "ERROR: $TEXT_FILE が見つかりません。" >&2
  exit 1
fi
if [[ ! -s "$TEXT_FILE" ]] || ! grep -q '[^[:space:]]' "$TEXT_FILE"; then
  echo "ERROR: $TEXT_FILE が空です（空白のみを含む場合も同様）。" >&2
  exit 1
fi

PY="${PYTHON:-python3}"

TMP_JSON="$(mktemp)"
TMP_RESP="$(mktemp)"
TMP_PCM="$(mktemp)"
trap 'rm -f "$TMP_JSON" "$TMP_RESP" "$TMP_PCM"' EXIT

# テキストとvoice名をJSONとして安全に組み立てる。
# 値はsys.argv経由で渡す（Pythonソースへ直接展開すると、引用符を含む値で
# 構文エラーやコード注入になるため）
"$PY" - "$TEXT_FILE" "$GEMINI_TTS_VOICE" > "$TMP_JSON" <<'PYEOF'
import json, sys
text = open(sys.argv[1], encoding='utf-8').read()
voice = sys.argv[2]
payload = {
    'contents': [{'parts': [{'text': text}]}],
    'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {'voiceConfig': {'prebuiltVoiceConfig': {'voiceName': voice}}}
    }
}
print(json.dumps(payload, ensure_ascii=False))
PYEOF

echo "==== Gemini API 呼び出し中（model=$GEMINI_TTS_MODEL, voice=$GEMINI_TTS_VOICE）===="
# APIキーはURLではなくヘッダで渡す（URLだとプロセス一覧やログに残りうる）。
# タイムアウトとリトライを設定し、通信断で無期限待機しないようにする。
HTTP_CODE=$(curl -sS -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_TTS_MODEL}:generateContent" \
  -H "Content-Type: application/json" \
  -H "x-goog-api-key: ${GEMINI_API_KEY}" \
  --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 3 \
  -w '%{http_code}' -o "$TMP_RESP" \
  -d @"$TMP_JSON") || {
    echo "ERROR: API呼び出しに失敗しました（ネットワーク断・タイムアウト等）" >&2
    exit 1
  }

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Gemini API がHTTP $HTTP_CODE を返しました" >&2
  case "$HTTP_CODE" in
    400) echo "  リクエスト不正。モデル名が正しいか確認してください。" >&2 ;;
    401|403) echo "  認証エラー。GEMINI_API_KEY を確認してください。" >&2 ;;
    404) echo "  モデルが見つかりません。次で有効なモデル名を確認してください:" >&2
         echo "  curl -H 'x-goog-api-key: \$GEMINI_API_KEY' https://generativelanguage.googleapis.com/v1beta/models" >&2 ;;
    429) echo "  レート制限。しばらく待って再実行してください。" >&2 ;;
    5*) echo "  サーバ側エラー。時間をおいて再実行してください。" >&2 ;;
  esac
  head -c 2000 "$TMP_RESP" >&2
  echo >&2
  exit 1
fi

# base64音声データを抽出してデコード（生PCM 24kHz 16bit mono想定）
"$PY" - "$TMP_RESP" "$TMP_PCM" <<'PYEOF'
import json, base64, sys
try:
    d = json.load(open(sys.argv[1]))
except json.JSONDecodeError:
    sys.exit('ERROR: APIレスポンスがJSONとして解析できません（HTMLエラーページの可能性）')
if 'error' in d:
    sys.exit(f"ERROR: Gemini API: {d['error'].get('message', d['error'])}")
try:
    part = d['candidates'][0]['content']['parts'][0]['inlineData']
except (KeyError, IndexError):
    sys.exit('ERROR: レスポンスに音声データがありません（生成失敗）。'
             '同じテキストでリトライしてください。')
open(sys.argv[2], 'wb').write(base64.b64decode(part['data']))
print('mimeType:', part.get('mimeType'))
PYEOF

mkdir -p "$(dirname "$OUT_WAV")"
ffmpeg -y -loglevel error -f s16le -ar 24000 -ac 1 -i "$TMP_PCM" "$OUT_WAV"
echo "==== 完了: $OUT_WAV ===="
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 "$OUT_WAV"
