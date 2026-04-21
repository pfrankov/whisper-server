#!/bin/bash

# WhisperServer LAN + API key middleware tests.
# Standalone, does not source test_api.sh.
#
# What this script does:
#   1. Detects the Mac's primary LAN IPv4 address.
#   2. Probes http://<LAN-IP>:12017/v1/models without a token to classify mode:
#        - unreachable  → "Expose on Local Network" is off → stops with a hint.
#        - 200          → auth is disabled, runs the "open LAN" subset.
#        - 401          → auth is required, runs the "locked LAN" subset.
#   3. Always re-verifies that loopback (127.0.0.1) bypasses auth regardless of mode.
#
# Prerequisites:
#   - The app is running.
#   - "Expose on Local Network" is enabled from the menu bar.
#   - jfk.wav is present next to this script (same layout as test_api.sh).
#   - When "Require API Key" is on, pass the token via WHISPER_API_KEY=ws-...
#     (Menu → Copy API Key).

set -euo pipefail

SERVER_URL="http://localhost:12017"
PORT="12017"
TEST_AUDIO="jfk.wav"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TEST_FAILURES=0
LAST_BODY=""
LAST_STATUS=""
CURL_ERROR=""

record_pass() {
    printf "%b✅ PASS:%b %s\n" "$GREEN" "$NC" "$1"
}

record_fail() {
    TEST_FAILURES=1
    printf "%b❌ FAIL:%b %s\n" "$RED" "$NC" "$1"
    if [ $# -gt 1 ] && [ -n "${2:-}" ]; then
        printf "   %s\n" "$2"
    fi
}

render_command() {
    local cmd="curl"
    for arg in "$@"; do
        cmd+=" \"${arg//\"/\\\"}\""
    done
    printf '%s' "$cmd"
}

run_curl() {
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

# --- Lightweight validators -------------------------------------------------

validate_model_list() {
    BODY="$LAST_BODY" python3 - <<'PY'
import json, os, sys
body = os.environ.get("BODY", "")
try:
    data = json.loads(body)
except Exception as exc:  # noqa: BLE001
    print(f"JSON decode failed: {exc}", file=sys.stderr)
    sys.exit(1)
if data.get("object") != "list":
    print("Root object must be 'list'", file=sys.stderr)
    sys.exit(1)
items = data.get("data")
if not isinstance(items, list) or not items:
    print("'data' must be a non-empty array", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
}

validate_json_text() {
    BODY="$LAST_BODY" python3 - <<'PY'
import json, os, sys
body = os.environ.get("BODY", "")
try:
    data = json.loads(body)
except Exception as exc:  # noqa: BLE001
    print(f"JSON decode failed: {exc}", file=sys.stderr)
    sys.exit(1)
text = data.get("text")
if not isinstance(text, str) or not text.strip():
    print("'text' field missing or empty", file=sys.stderr)
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
except Exception as exc:  # noqa: BLE001
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

# --- Runner -----------------------------------------------------------------

run_http_test() {
    local name="$1"
    local expected_status="$2"
    local validator="$3"
    shift 3
    local command
    command=$(render_command "$@")
    printf "%b🧪 %s%b\n" "$BLUE" "$name" "$NC"
    printf "%b   %s%b\n" "$YELLOW" "$command" "$NC"
    if ! run_curl "$@"; then
        record_fail "$name" "curl failed: $CURL_ERROR"
        echo ""
        return
    fi
    if [ "$LAST_STATUS" != "$expected_status" ]; then
        record_fail "$name" "Expected HTTP $expected_status, got $LAST_STATUS"
        [ -n "$LAST_BODY" ] && printf "   Body: %s\n" "$LAST_BODY"
        echo ""
        return
    fi
    if ! $validator; then
        record_fail "$name" "Body validation failed"
        [ -n "$LAST_BODY" ] && printf "   Body: %s\n" "$LAST_BODY"
        echo ""
        return
    fi
    record_pass "$name"
    echo ""
}

# --- LAN discovery ----------------------------------------------------------

detect_lan_ip() {
    local ip
    for iface in en0 en1 en2 en3 en4 en5; do
        ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
        if [ -n "$ip" ]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

probe_status() {
    local url="$1"
    set +e
    local code
    code=$(curl -sS --connect-timeout 3 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
    local exit_code=$?
    set -e
    if [ $exit_code -ne 0 ]; then
        printf 'unreachable'
        return
    fi
    printf '%s' "$code"
}

# --- Preflight --------------------------------------------------------------

preflight() {
    if [ ! -f "$TEST_AUDIO" ]; then
        printf "%b❌ Test audio '%s' not found next to this script.%b\n" "$RED" "$TEST_AUDIO" "$NC"
        printf "   Download with: curl -O https://github.com/openai/whisper/raw/main/tests/jfk.wav\n"
        exit 1
    fi

    printf "%b🔍 Checking server on %s...%b\n" "$YELLOW" "$SERVER_URL" "$NC"
    if ! curl -s --connect-timeout 5 "$SERVER_URL/v1/models" > /dev/null 2>&1; then
        printf "%b❌ Server not responding on %s — start the app first.%b\n" "$RED" "$SERVER_URL" "$NC"
        exit 1
    fi
    printf "%b✅ Server responding%b\n\n" "$GREEN" "$NC"
}

# --- Main -------------------------------------------------------------------

main() {
    printf "%b============================================%b\n" "$BLUE" "$NC"
    printf "%b🌐 WhisperServer LAN + API Key test suite%b\n" "$BLUE" "$NC"
    printf "%b============================================%b\n\n" "$BLUE" "$NC"

    preflight

    local lan_ip
    if ! lan_ip=$(detect_lan_ip); then
        printf "%b⚠️  No LAN interface with IPv4 detected (en0..en5).%b\n" "$YELLOW" "$NC"
        printf "   Connect to a network and retry.\n"
        exit 0
    fi

    local lan_url="http://${lan_ip}:${PORT}"
    printf "%b🔍 LAN endpoint: %s%b\n" "$YELLOW" "$lan_url" "$NC"

    local probe
    probe=$(probe_status "$lan_url/v1/models")

    if [ "$probe" = "unreachable" ]; then
        printf "%b⚠️  %s is unreachable — 'Expose on Local Network' appears to be off.%b\n" "$YELLOW" "$lan_url" "$NC"
        printf "   Enable it from the menu bar and re-run.\n"
        exit 0
    fi

    # Loopback should always bypass auth — critical regression check.
    printf "\n%b── Loopback bypass ──%b\n" "$BLUE" "$NC"
    run_http_test "Loopback GET without header → 200" 200 validate_model_list \
        -X GET "$SERVER_URL/v1/models"
    run_http_test "Loopback GET with bogus header → 200" 200 validate_model_list \
        -H "Authorization: Bearer ws-ignored-on-loopback" \
        -X GET "$SERVER_URL/v1/models"

    case "$probe" in
        200)
            printf "\n%b── LAN, auth OFF ──%b\n" "$GREEN" "$NC"
            run_http_test "LAN GET without header → 200" 200 validate_model_list \
                -X GET "$lan_url/v1/models"
            run_http_test "LAN GET with ignored header → 200" 200 validate_model_list \
                -H "Authorization: Bearer ws-anything" \
                -X GET "$lan_url/v1/models"
            run_http_test "LAN POST transcription without header → 200" 200 validate_json_text \
                -X POST "$lan_url/v1/audio/transcriptions" \
                -F "file=@$TEST_AUDIO" \
                -F "response_format=json"
            ;;
        401)
            printf "\n%b── LAN, auth REQUIRED ──%b\n" "$YELLOW" "$NC"
            run_http_test "LAN GET without header → 401" 401 validate_json_error \
                -X GET "$lan_url/v1/models"
            run_http_test "LAN GET with wrong token → 401" 401 validate_json_error \
                -H "Authorization: Bearer ws-definitely-wrong" \
                -X GET "$lan_url/v1/models"

            if [ -n "${WHISPER_API_KEY:-}" ]; then
                run_http_test "LAN GET with valid token → 200" 200 validate_model_list \
                    -H "Authorization: Bearer $WHISPER_API_KEY" \
                    -X GET "$lan_url/v1/models"
                run_http_test "LAN POST transcription with valid token → 200" 200 validate_json_text \
                    -H "Authorization: Bearer $WHISPER_API_KEY" \
                    -X POST "$lan_url/v1/audio/transcriptions" \
                    -F "file=@$TEST_AUDIO" \
                    -F "response_format=json"
            else
                printf "%b⚠️  WHISPER_API_KEY not set — skipping valid-token cases.%b\n" "$YELLOW" "$NC"
                printf "   Copy the key from the menu bar (Copy API Key) and re-run:\n"
                printf "     WHISPER_API_KEY=ws-... ./test_api_lan.sh\n\n"
            fi
            ;;
        *)
            record_fail "LAN probe" "Unexpected status '$probe' from $lan_url/v1/models"
            ;;
    esac

    printf "%b============================================%b\n" "$BLUE" "$NC"
    if [ $TEST_FAILURES -eq 0 ]; then
        printf "%b🎉 LAN test suite passed%b\n" "$GREEN" "$NC"
        exit 0
    else
        printf "%b⚠️  LAN test suite had failures%b\n" "$YELLOW" "$NC"
        exit 1
    fi
}

main "$@"
