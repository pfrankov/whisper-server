#!/bin/bash

# Whisper Server API Test Script
# Strengthened validations for Whisper/Fluid providers

set -euo pipefail

SERVER_URL="http://localhost:12017"
TEST_AUDIO="jfk.wav"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_JSON_PATH="$SCRIPT_DIR/WhisperServer/Models.json"
FLUID_SOURCE_PATH="$SCRIPT_DIR/WhisperServer/FluidTranscriptionService.swift"

WHISPER_MODELS=()
if [ -f "$MODELS_JSON_PATH" ]; then
    export MODELS_JSON_PATH
    while IFS= read -r line; do
        [ -n "$line" ] && WHISPER_MODELS+=("$line")
    done < <(
        python3 - <<'PY'
import json, os
path = os.environ.get("MODELS_JSON_PATH")
if not path or not os.path.exists(path):
    raise SystemExit
with open(path, "r", encoding="utf-8") as handle:
    try:
        data = json.load(handle)
    except Exception:
        raise SystemExit
for model in data:
    mid = model.get("id")
    if mid:
        print(mid)
PY
    )
    unset MODELS_JSON_PATH
fi

if [ -n "${WHISPER_MODELS_OVERRIDE:-}" ]; then
    IFS=',' read -r -a WHISPER_MODELS <<< "$WHISPER_MODELS_OVERRIDE"
fi

if [ ${#WHISPER_MODELS[@]} -eq 0 ]; then
    WHISPER_MODELS=("tiny-q5_1")
fi

FLUID_MODELS=()
if [ -f "$FLUID_SOURCE_PATH" ]; then
    export FLUID_SOURCE_PATH
    while IFS= read -r line; do
        [ -n "$line" ] && FLUID_MODELS+=("$line")
    done < <(
        python3 - <<'PY'
import os, re
path = os.environ.get("FLUID_SOURCE_PATH")
if not path or not os.path.exists(path):
    raise SystemExit
with open(path, 'r', encoding='utf-8') as handle:
    contents = handle.read()

pattern = re.compile(r'ModelDescriptor\(\s*id:\s*"([^"]+)"', re.DOTALL)
seen = set()
for model_id in pattern.findall(contents):
    if model_id not in seen:
        print(model_id)
        seen.add(model_id)
PY
    )
    unset FLUID_SOURCE_PATH
fi

if [ -n "${FLUID_MODELS_OVERRIDE:-}" ]; then
    IFS=',' read -r -a FLUID_MODELS <<< "$FLUID_MODELS_OVERRIDE"
fi

TEST_FAILURES=0
LAST_BODY=""
LAST_STATUS=""
LAST_HEADERS=""
CURL_ERROR=""

render_command() {
    local cmd="curl"
    for arg in "$@"; do
        local escaped=${arg//"/\\"}
        cmd+=" \"$escaped\""
    done
    printf '%s' "$cmd"
}

record_pass() {
    printf "%b✅ PASS:%b %s\n" "$GREEN" "$NC" "$1"
}

record_fail() {
    TEST_FAILURES=1
    printf "%b❌ FAIL:%b %s\n" "$RED" "$NC" "$1"
    if [ -n "$2" ]; then
        printf "   %s\n" "$2"
    fi
}

run_curl_basic() {
    set +e
    local response
    response=$(curl -sS -w '\n%{http_code}' "$@" 2>&1)
    local exit_code=$?
    set -e
    if [ $exit_code -ne 0 ]; then
        CURL_ERROR="$response"
        LAST_BODY=""
        LAST_STATUS=""
        return 1
    fi
    LAST_STATUS="${response##*$'\n'}"
    LAST_BODY="${response%$'\n'$LAST_STATUS}"
    CURL_ERROR=""
    return 0
}

run_curl_with_headers() {
    local header_file
    header_file=$(mktemp)
    set +e
    local response
    response=$(curl -sS -D "$header_file" -w '\n%{http_code}' "$@" 2>&1)
    local exit_code=$?
    set -e
    if [ $exit_code -ne 0 ]; then
        CURL_ERROR="$response"
        LAST_BODY=""
        LAST_STATUS=""
        LAST_HEADERS=""
        rm -f "$header_file"
        return 1
    fi
    LAST_STATUS="${response##*$'\n'}"
    LAST_BODY="${response%$'\n'$LAST_STATUS}"
    LAST_HEADERS=$(tr -d '\r' < "$header_file")
    CURL_ERROR=""
    rm -f "$header_file"
    return 0
}

validate_json_text() {
    BODY="$LAST_BODY" python3 - <<'PY'
import json, os, sys
body = os.environ.get("BODY", "")
try:
    data = json.loads(body)
except Exception as exc:
    print(f"JSON decode failed: {exc}", file=sys.stderr)
    sys.exit(1)
text = data.get("text")
if not isinstance(text, str) or not text.strip():
    print("Field 'text' missing or empty", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
}

validate_text_plain() {
    local trimmed
    trimmed=$(printf '%s' "$LAST_BODY" | tr -d '\r')
    if [ -z "${trimmed//[[:space:]]/}" ]; then
        printf 'Plain text body is empty\n' >&2
        return 1
    fi
    if [[ $trimmed == \{* ]]; then
        printf 'Plain text response unexpectedly looks like JSON\n' >&2
        return 1
    fi
    return 0
}

validate_verbose_json() {
    BODY="$LAST_BODY" python3 - <<'PY'
import json, os, sys
body = os.environ.get("BODY", "")
try:
    data = json.loads(body)
except Exception as exc:
    print(f"Verbose JSON decode failed: {exc}", file=sys.stderr)
    sys.exit(1)
if "text" not in data or not isinstance(data["text"], str):
    print("Verbose JSON missing 'text' field", file=sys.stderr)
    sys.exit(1)
segments = data.get("segments")
if not isinstance(segments, list) or not segments:
    print("Verbose JSON missing non-empty 'segments' array", file=sys.stderr)
    sys.exit(1)
for idx, seg in enumerate(segments):
    if not isinstance(seg, dict):
        print(f"Segment {idx} is not an object", file=sys.stderr)
        sys.exit(1)
    for key in ("start", "end", "text"):
        if key not in seg:
            print(f"Segment {idx} missing '{key}'", file=sys.stderr)
            sys.exit(1)
    if not isinstance(seg["text"], str) or not seg["text"].strip():
        print(f"Segment {idx} has empty text", file=sys.stderr)
        sys.exit(1)
sys.exit(0)
PY
}

validate_json_error() {
    BODY="$LAST_BODY" python3 - <<'PY'
import json, os, sys
body = os.environ.get("BODY", "")
try:
    data = json.loads(body)
except Exception as exc:
    print(f"Error JSON decode failed: {exc}", file=sys.stderr)
    sys.exit(1)

err = data.get("error")
reason = data.get("reason")
if isinstance(err, str) and err.strip():
    sys.exit(0)
if isinstance(err, bool) and err:
    if isinstance(reason, str) and reason.strip():
        sys.exit(0)
    print("Error response missing non-empty 'reason'", file=sys.stderr)
    sys.exit(1)
print("Error response missing 'error' field", file=sys.stderr)
sys.exit(1)
PY
}

validate_srt_plain() {
    if [[ $LAST_BODY != *"-->"* ]]; then
        printf 'SRT body missing timestamp separator\n' >&2
        return 1
    fi
    if [[ $LAST_BODY != *"00:"* ]]; then
        printf 'SRT body missing hours marker\n' >&2
        return 1
    fi
    return 0
}

validate_vtt_plain() {
    if [[ $LAST_BODY != WEBVTT* ]]; then
        printf 'VTT body missing WEBVTT header\n' >&2
        return 1
    fi
    if [[ $LAST_BODY != *"-->"* ]]; then
        printf 'VTT body missing timestamp separator\n' >&2
        return 1
    fi
    return 0
}

validate_chunked_text() {
    local content="$LAST_BODY"
    if [ -z "${content//[[:space:]]/}" ]; then
        printf 'Chunked fallback body is empty\n' >&2
        return 1
    fi
    if [[ $content == *"event:"* ]] || [[ $content == *"data:"* ]]; then
        printf 'Chunked fallback unexpectedly contains SSE framing\n' >&2
        return 1
    fi
    return 0
}

validate_sse_stream() {
    local expected="$1"
    BODY="$LAST_BODY" python3 - "$expected" <<'PY'
import json, os, sys
body = os.environ.get("BODY", "")
expected = sys.argv[1]
if not body.endswith("\n"):
    print("SSE body must end with newline", file=sys.stderr)
    sys.exit(1)
lines = body.splitlines()
if not lines or lines[0].strip() != ':ok':
    print("SSE missing ':ok' prelude", file=sys.stderr)
    sys.exit(1)
if len(lines) < 3 or lines[1] != "":
    print("SSE prelude missing blank line", file=sys.stderr)
    sys.exit(1)
found_end = False
data_lines = []
for line in lines[2:]:
    if not line:
        continue
    if line.startswith('event: end'):
        found_end = True
        continue
    if found_end:
        if line != 'data: ':
            print("Unexpected content after end event", file=sys.stderr)
            sys.exit(1)
    else:
        if not line.startswith('data: '):
            print(f"Unexpected line before end event: {line}", file=sys.stderr)
            sys.exit(1)
        data_lines.append(line[6:])
if not found_end:
    print("SSE missing end event", file=sys.stderr)
    sys.exit(1)
filtered = [payload for payload in data_lines if payload.strip()]
if not filtered:
    print("SSE stream contains no meaningful data events", file=sys.stderr)
    sys.exit(1)
if expected == 'text':
    for idx, payload in enumerate(filtered):
        if payload.lstrip().startswith('{'):
            print("Text SSE payload unexpectedly JSON", file=sys.stderr)
            sys.exit(1)
elif expected == 'json':
    for payload in filtered:
        try:
            obj = json.loads(payload)
        except Exception as exc:
            print(f"JSON SSE payload decode failed: {exc}", file=sys.stderr)
            sys.exit(1)
        if 'text' not in obj:
            print("JSON SSE payload missing 'text'", file=sys.stderr)
            sys.exit(1)
elif expected == 'srt':
    joined = "\n".join(filtered)
    if '-->' not in joined:
        print("SRT SSE payload missing timestamp", file=sys.stderr)
        sys.exit(1)
elif expected == 'vtt':
    if not filtered[0].startswith('WEBVTT'):
        print("VTT SSE payload missing WEBVTT header", file=sys.stderr)
        sys.exit(1)
    if not any('-->' in payload for payload in filtered):
        print("VTT SSE payload missing timestamp", file=sys.stderr)
        sys.exit(1)
elif expected == 'verbose_json':
    for payload in filtered:
        try:
            obj = json.loads(payload)
        except Exception as exc:
            print(f"Verbose JSON SSE decode failed: {exc}", file=sys.stderr)
            sys.exit(1)
        for key in ('start', 'end', 'text'):
            if key not in obj:
                print(f"Verbose JSON SSE missing '{key}'", file=sys.stderr)
                sys.exit(1)
else:
    print(f"Unknown SSE expectation '{expected}'", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
}

validate_sse_text() { validate_sse_stream "text"; }
validate_sse_json() { validate_sse_stream "json"; }
validate_sse_srt() { validate_sse_stream "srt"; }
validate_sse_vtt() { validate_sse_stream "vtt"; }
validate_sse_verbose() { validate_sse_stream "verbose_json"; }

validate_model_list() {
    local whisper_expected=""
    local fluid_expected=""
    if declare -p WHISPER_MODELS >/dev/null 2>&1 && [ ${#WHISPER_MODELS[@]} -gt 0 ]; then
        whisper_expected=$(printf '%s\n' "${WHISPER_MODELS[@]}")
    fi
    if declare -p FLUID_MODELS >/dev/null 2>&1 && [ ${#FLUID_MODELS[@]} -gt 0 ]; then
        fluid_expected=$(printf '%s\n' "${FLUID_MODELS[@]}")
    fi
    BODY="$LAST_BODY" WHISPER_EXPECTED="$whisper_expected" FLUID_EXPECTED="$fluid_expected" python3 - <<'PY'
import json, os, sys

body = os.environ.get("BODY", "")
if not body:
    print("Empty body", file=sys.stderr)
    sys.exit(1)

try:
    payload = json.loads(body)
except Exception as exc:  # noqa: BLE001
    print(f"JSON decode failed: {exc}", file=sys.stderr)
    sys.exit(1)

if payload.get("object") != "list":
    print("Root object must be 'list'", file=sys.stderr)
    sys.exit(1)

data = payload.get("data")
if not isinstance(data, list) or not data:
    print("'data' must be a non-empty array", file=sys.stderr)
    sys.exit(1)

whisper_expected = [line.strip() for line in os.environ.get("WHISPER_EXPECTED", "").splitlines() if line.strip()]
fluid_expected = [line.strip() for line in os.environ.get("FLUID_EXPECTED", "").splitlines() if line.strip()]

providers = {entry.get("provider") for entry in data if isinstance(entry, dict)}
if "whisper" not in providers:
    print("Whisper provider missing from model list", file=sys.stderr)
    sys.exit(1)

if fluid_expected and "fluid" not in providers:
    print("Fluid provider missing from model list", file=sys.stderr)
    sys.exit(1)

def ensure_models(expected, provider):
    for model_id in expected:
        if not any(isinstance(entry, dict) and entry.get("id") == model_id and entry.get("provider") == provider for entry in data):
            print(f"Model '{model_id}' for provider '{provider}' not present", file=sys.stderr)
            sys.exit(1)

ensure_models(whisper_expected, "whisper")
ensure_models(fluid_expected, "fluid")

for entry in data:
    if not isinstance(entry, dict):
        print("Model entry is not an object", file=sys.stderr)
        sys.exit(1)
    for key in ("id", "object", "provider", "type"):
        if key not in entry:
            print(f"Model entry missing '{key}'", file=sys.stderr)
            sys.exit(1)
    if entry.get("object") != "model":
        print("Model entry must have object == 'model'", file=sys.stderr)
        sys.exit(1)
    if entry.get("type") != "audio.transcription":
        print("Model entry must have type 'audio.transcription'", file=sys.stderr)
        sys.exit(1)

sys.exit(0)
PY
}

ensure_content_type() {
    local expected="$1"
    local headers="$LAST_HEADERS"
    if [[ $headers != *"Content-Type: ${expected}"* ]]; then
        printf 'Expected Content-Type %s but got:\n%s\n' "$expected" "$headers" >&2
        return 1
    fi
    return 0
}

ensure_not_sse_header() {
    if [[ $LAST_HEADERS == *"text/event-stream"* ]]; then
        printf 'Expected non-SSE response but got text/event-stream\n' >&2
        return 1
    fi
    return 0
}

run_http_test() {
    local name="$1"
    local expected_status="$2"
    local validator="$3"
    shift 3
    local command
    command=$(render_command "$@")
    echo -e "${BLUE}🧪 Testing: $name${NC}"
    echo -e "${YELLOW}Command: $command${NC}"
    if ! run_curl_basic "$@"; then
        record_fail "$name" "curl failed: $CURL_ERROR"
        echo ""
        return
    fi
    if [ "$LAST_STATUS" != "$expected_status" ]; then
        record_fail "$name" "Expected HTTP $expected_status, got $LAST_STATUS"
        echo ""
        return
    fi
    if ! $validator; then
        record_fail "$name" "Body validation failed"
        echo "   Response: $LAST_BODY"
        echo ""
        return
    fi
    record_pass "$name"
    echo ""
}

run_http_test_with_headers() {
    local name="$1"
    local expected_status="$2"
    local validator="$3"
    local expected_ct="$4"
    shift 4
    local command
    command=$(render_command "$@")
    echo -e "${BLUE}🧪 Testing: $name${NC}"
    echo -e "${YELLOW}Command: $command${NC}"
    if ! run_curl_with_headers "$@"; then
        record_fail "$name" "curl failed: $CURL_ERROR"
        echo ""
        return
    fi
    if [ "$LAST_STATUS" != "$expected_status" ]; then
        record_fail "$name" "Expected HTTP $expected_status, got $LAST_STATUS"
        echo ""
        return
    fi
    if ! ensure_content_type "$expected_ct"; then
        record_fail "$name" "Unexpected Content-Type"
        echo "   Headers: $LAST_HEADERS"
        echo ""
        return
    fi
    if ! $validator; then
        record_fail "$name" "Body validation failed"
        echo "   Response: $LAST_BODY"
        echo ""
        return
    fi
    record_pass "$name"
    echo ""
}

run_chunked_test() {
    local name="$1"
    local expected_ct="$2"
    local validator="$3"
    shift 3
    local command
    command=$(render_command "$@")
    echo -e "${BLUE}🌊 Testing: $name${NC}"
    echo -e "${YELLOW}Command: $command${NC}"
    if ! run_curl_with_headers "$@"; then
        record_fail "$name" "curl failed: $CURL_ERROR"
        echo ""
        return
    fi
    if [ "$LAST_STATUS" != "200" ]; then
        record_fail "$name" "Expected HTTP 200, got $LAST_STATUS"
        echo ""
        return
    fi
    if ! ensure_content_type "$expected_ct"; then
        record_fail "$name" "Unexpected Content-Type"
        echo "   Headers: $LAST_HEADERS"
        echo ""
        return
    fi
    if ! ensure_not_sse_header; then
        record_fail "$name" "Received SSE headers"
        echo "   Headers: $LAST_HEADERS"
        echo ""
        return
    fi
    if ! $validator; then
        record_fail "$name" "Body validation failed"
        echo "   Response: $LAST_BODY"
        echo ""
        return
    fi
    record_pass "$name"
    echo ""
}

run_sse_test() {
    local name="$1"
    local validator="$2"
    shift 2
    local command
    command=$(render_command "$@")
    echo -e "${PURPLE}🌊 Testing SSE: $name${NC}"
    echo -e "${YELLOW}Command: $command${NC}"
    if ! run_curl_with_headers "$@"; then
        record_fail "$name" "curl failed: $CURL_ERROR"
        echo ""
        return
    fi
    if [ "$LAST_STATUS" != "200" ]; then
        record_fail "$name" "Expected HTTP 200, got $LAST_STATUS"
        echo ""
        return
    fi
    if [[ $LAST_HEADERS != *"Content-Type: text/event-stream"* ]]; then
        record_fail "$name" "Missing text/event-stream header"
        echo "   Headers: $LAST_HEADERS"
        echo ""
        return
    fi
    if ! $validator; then
        record_fail "$name" "SSE payload validation failed"
        echo "   Response (first lines):"
        printf '   %s\n' "$(printf '%s' "$LAST_BODY" | head -n 6)"
        echo ""
        return
    fi
    record_pass "$name"
    echo ""
}

run_models_listing_test() {
    local name="Model catalog"
    echo -e "${BLUE}🧾 Testing: $name${NC}"
    local command
    command=$(render_command -X GET "$SERVER_URL/v1/models")
    echo -e "${YELLOW}Command: $command${NC}"
    if ! run_curl_basic -X GET "$SERVER_URL/v1/models"; then
        record_fail "$name" "curl failed: $CURL_ERROR"
        echo ""
        return
    fi
    if [ "$LAST_STATUS" != "200" ]; then
        record_fail "$name" "Expected HTTP 200, got $LAST_STATUS"
        echo "   Response: $LAST_BODY"
        echo ""
        return
    fi
    if ! validate_model_list; then
        record_fail "$name" "Model listing validation failed"
        echo "   Response: $LAST_BODY"
        echo ""
        return
    fi
    record_pass "$name"
    echo ""
}

check_server_ready() {
    if [ ! -f "$TEST_AUDIO" ]; then
        printf "%b❌ Test audio file '%s' not found!%b\n" "$RED" "$TEST_AUDIO" "$NC"
        printf "%b💡 Download with:%b curl -O https://github.com/openai/whisper/raw/main/tests/jfk.wav\n" "$YELLOW" "$NC"
        exit 1
    fi

    printf "%b🔍 Checking if server is running...%b\n" "$YELLOW" "$NC"
    if ! curl -s --connect-timeout 5 "$SERVER_URL/v1/audio/transcriptions" > /dev/null 2>&1; then
        printf "%b❌ Server is not running on %s%b\n" "$RED" "$SERVER_URL" "$NC"
        printf "%b💡 Start the app first, then run this script again%b\n" "$YELLOW" "$NC"
        exit 1
    fi
    printf "%b✅ Server is responding%b\n\n" "$GREEN" "$NC"
}

print_banner() {
    printf "%b🔧 WhisperServer API Test Suite%b\n" "$BLUE" "$NC"
    printf "%bTesting OpenAI Whisper API compatibility + SSE Streaming%b\n" "$BLUE" "$NC"
    if [ ${#WHISPER_MODELS[@]} -gt 0 ]; then
        printf "%b📦 Whisper models under test: %s%b\n" "$YELLOW" "${WHISPER_MODELS[*]}" "$NC"
    fi
    if [ ${#FLUID_MODELS[@]} -gt 0 ]; then
        printf "%b💧 Fluid models under test: %s%b\n" "$YELLOW" "${FLUID_MODELS[*]}" "$NC"
    fi
    echo ""
}

run_whisper_suite() {
    local CURRENT_MODEL="$1"
    printf "%b==============================%b\n" "$BLUE" "$NC"
    printf "%b🧬 WHISPER MODEL UNDER TEST: %s%b\n" "$BLUE" "$CURRENT_MODEL" "$NC"
    printf "%b==============================%b\n\n" "$BLUE" "$NC"

    run_http_test "JSON Response" 200 validate_json_text \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "model=$CURRENT_MODEL"

    run_http_test "JSON Response (explicit)" 200 validate_json_text \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=json" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Plain text response" 200 validate_text_plain \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=text" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Language parameter" 200 validate_json_text \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "language=en" \
        -F "response_format=json" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Prompt parameter" 200 validate_json_text \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "prompt=This is a test" \
        -F "response_format=json" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Missing file error" 400 validate_json_error \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Invalid format error" 400 validate_json_error \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=invalid" \
        -F "model=$CURRENT_MODEL"

    run_http_test_with_headers "SRT format" 200 validate_srt_plain "application/x-subrip" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=srt" \
        -F "model=$CURRENT_MODEL"

    run_http_test_with_headers "VTT format" 200 validate_vtt_plain "text/vtt" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=vtt" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Verbose JSON format" 200 validate_verbose_json \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=verbose_json" \
        -F "model=$CURRENT_MODEL"

    run_chunked_test "Chunked SRT streaming" "application/x-subrip" validate_srt_plain \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=srt" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_chunked_test "Chunked VTT streaming" "text/vtt" validate_vtt_plain \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=vtt" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_sse_test "SSE Text" validate_sse_text \
        -H "Accept: text/event-stream" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=text" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_sse_test "SSE JSON" validate_sse_json \
        -H "Accept: text/event-stream" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=json" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_sse_test "SSE SRT" validate_sse_srt \
        -H "Accept: text/event-stream" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=srt" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_sse_test "SSE VTT" validate_sse_vtt \
        -H "Accept: text/event-stream" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=vtt" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_sse_test "SSE Verbose JSON" validate_sse_verbose \
        -H "Accept: text/event-stream" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=verbose_json" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_chunked_test "Chunked text fallback" "text/plain; charset=utf-8" validate_chunked_text \
        -H "Accept: application/json" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=text" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    echo -e "${BLUE}🚀 Performance Test${NC}"
    echo -e "${YELLOW}Measuring response time...${NC}"
    local start end duration
    start=$(date +%s.%N)
    if run_curl_basic -X POST "$SERVER_URL/v1/audio/transcriptions" -F "file=@$TEST_AUDIO" -F "response_format=text" -F "model=$CURRENT_MODEL"; then
        end=$(date +%s.%N)
        duration=$(START_TIME="$start" END_TIME="$end" python3 - <<'PY'
import os
start=float(os.environ["START_TIME"])
end=float(os.environ["END_TIME"])
print(f"{end-start:.3f}")
PY
)
        printf "%b✅ Performance test completed in %s seconds%b\n" "$GREEN" "$duration" "$NC"
        printf "%bResponse:%b %s\n" "$GREEN" "$NC" "$LAST_BODY"
    else
        record_fail "Performance Test" "curl failed: $CURL_ERROR"
    fi
    echo ""

    run_http_test_with_headers "JSON headers" 200 validate_json_text "application/json" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=json" \
        -F "model=$CURRENT_MODEL"

    run_http_test_with_headers "Text headers" 200 validate_text_plain "text/plain; charset=utf-8" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=text" \
        -F "model=$CURRENT_MODEL"
}

run_fluid_suite() {
    local CURRENT_MODEL="$1"
    printf "%b==============================%b\n" "$BLUE" "$NC"
    printf "%b💧 FLUID MODEL UNDER TEST: %s%b\n" "$BLUE" "$CURRENT_MODEL" "$NC"
    printf "%b==============================%b\n\n" "$BLUE" "$NC"

    run_http_test "Fluid JSON Response" 200 validate_json_text \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Fluid JSON (explicit)" 200 validate_json_text \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=json" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Fluid text response" 200 validate_text_plain \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=text" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Fluid language parameter" 200 validate_json_text \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "language=en" \
        -F "response_format=json" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Fluid prompt parameter" 200 validate_json_text \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "prompt=This is a test" \
        -F "response_format=json" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Fluid missing file" 400 validate_json_error \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "model=$CURRENT_MODEL"

    run_http_test "Fluid invalid format" 400 validate_json_error \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=invalid" \
        -F "model=$CURRENT_MODEL"

    run_sse_test "Fluid SSE Text" validate_sse_text \
        -H "Accept: text/event-stream" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=text" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_sse_test "Fluid SSE JSON" validate_sse_json \
        -H "Accept: text/event-stream" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=json" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_chunked_test "Fluid chunked fallback" "text/plain; charset=utf-8" validate_chunked_text \
        -H "Accept: application/json" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=text" \
        -F "stream=true" \
        -F "model=$CURRENT_MODEL"

    run_http_test_with_headers "Fluid JSON headers" 200 validate_json_text "application/json" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=json" \
        -F "model=$CURRENT_MODEL"

    run_http_test_with_headers "Fluid text headers" 200 validate_text_plain "text/plain; charset=utf-8" \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "response_format=text" \
        -F "model=$CURRENT_MODEL"
}

run_negative_tests() {
    printf "%b=== NEGATIVE CASES ===%b\n" "$BLUE" "$NC"
    run_http_test "Unknown model" 400 validate_json_error \
        -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -F "file=@$TEST_AUDIO" \
        -F "model=definitely-not-real"
    echo ""
}

summarize() {
    if [ $TEST_FAILURES -eq 0 ]; then
        printf "%b🏁 Test Suite Complete!%b\n" "$BLUE" "$NC"
        printf "%b🎉 WhisperServer responses validated across providers%b\n" "$GREEN" "$NC"
        exit 0
    else
        printf "%b⚠️  Test suite completed with failures%b\n" "$YELLOW" "$NC"
        exit 1
    fi
}

print_banner
check_server_ready
run_models_listing_test

if [ ${#FLUID_MODELS[@]} -gt 0 ]; then
    for model in "${FLUID_MODELS[@]}"; do
        run_fluid_suite "$model"
    done
fi

for model in "${WHISPER_MODELS[@]}"; do
    run_whisper_suite "$model"
done


run_negative_tests
summarize
