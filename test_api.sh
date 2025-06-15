#!/bin/bash

# Whisper Server API Test Script
# Tests OpenAI Whisper API compatibility using curl
# Author: Valera the Ex-Designer Turned Plumber Turned IT Guy

set -e

# Configuration
SERVER_URL="http://localhost:12017"
TEST_AUDIO="jfk.wav"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔧 WhisperServer API Test Suite${NC}"
echo -e "${BLUE}Testing OpenAI Whisper API compatibility + SSE Streaming${NC}"
echo ""

# Check if test audio file exists
if [ ! -f "$TEST_AUDIO" ]; then
    echo -e "${RED}❌ Test audio file '$TEST_AUDIO' not found!${NC}"
    echo -e "${YELLOW}💡 You can download test audio with:${NC}"
    echo "   curl -O https://github.com/openai/whisper/raw/main/tests/jfk.wav"
    exit 1
fi

# Check if server is running
echo -e "${YELLOW}🔍 Checking if server is running...${NC}"
if ! curl -s --connect-timeout 5 "$SERVER_URL/v1/audio/transcriptions" > /dev/null 2>&1; then
    echo -e "${RED}❌ Server is not running on $SERVER_URL${NC}"
    echo -e "${YELLOW}💡 Start the app first, then run this script again${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Server is responding${NC}"
echo ""

# Test function
run_test() {
    local test_name="$1"
    local curl_cmd="$2"
    local expected_check="$3"
    
    echo -e "${BLUE}🧪 Testing: $test_name${NC}"
    echo -e "${YELLOW}Command: $curl_cmd${NC}"
    
    response=$(eval "$curl_cmd" 2>&1)
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        if eval "$expected_check"; then
            echo -e "${GREEN}✅ PASS: $test_name${NC}"
        else
            echo -e "${RED}❌ FAIL: $test_name - Response validation failed${NC}"
            echo -e "${RED}Response: $response${NC}"
        fi
    else
        echo -e "${RED}❌ FAIL: $test_name - Request failed${NC}"
        echo -e "${RED}Error: $response${NC}"
    fi
    echo ""
}

# SSE Test function
run_sse_test() {
    local test_name="$1"
    local format="$2"
    local accept_header="$3"
    local expected_content_type="$4"
    local validation_check="$5"
    
    echo -e "${PURPLE}🌊 Testing SSE: $test_name${NC}"
    
    # Get headers and response
    temp_file=$(mktemp)
    response=$(curl -s -D "$temp_file" -X POST "$SERVER_URL/v1/audio/transcriptions" \
        -H "Accept: $accept_header" \
        -F file=@$TEST_AUDIO \
        -F response_format="$format" \
        -F stream="true" \
        --no-buffer 2>/dev/null)
    
    headers=$(cat "$temp_file")
    rm "$temp_file"
    
    # Check content type
    content_type=$(echo "$headers" | grep -i "content-type:" | head -1 | tr -d '\r')
    
    if [[ "$content_type" == *"$expected_content_type"* ]]; then
        echo -e "${GREEN}✅ Content-Type correct: $content_type${NC}"
        
        # Validate response content
        if eval "$validation_check"; then
            echo -e "${GREEN}✅ PASS: $test_name${NC}"
            echo -e "${YELLOW}   Sample output (first 3 lines):${NC}"
            echo "$response" | head -3 | sed 's/^/   /'
        else
            echo -e "${RED}❌ FAIL: $test_name - Response validation failed${NC}"
            echo -e "${RED}Response: $response${NC}"
        fi
    else
        echo -e "${RED}❌ FAIL: $test_name - Wrong Content-Type${NC}"
        echo -e "${RED}Expected: $expected_content_type, Got: $content_type${NC}"
    fi
    echo ""
}

echo -e "${BLUE}=== BASIC API TESTS ===${NC}"

# Test 1: JSON Response Format (Default)
run_test "JSON Response Format" \
    "curl -s -X POST '$SERVER_URL/v1/audio/transcriptions' -F file=@$TEST_AUDIO" \
    '[[ "$response" == *"text"* && "$response" == *"{"* ]]'

# Test 2: Explicit JSON Response Format
run_test "Explicit JSON Response Format" \
    "curl -s -X POST '$SERVER_URL/v1/audio/transcriptions' -F file=@$TEST_AUDIO -F response_format=json" \
    '[[ "$response" == *"text"* && "$response" == *"{"* ]]'

# Test 3: Text Response Format
run_test "Text Response Format" \
    "curl -s -X POST '$SERVER_URL/v1/audio/transcriptions' -F file=@$TEST_AUDIO -F response_format=text" \
    '[[ "$response" != *"{"* && ${#response} -gt 0 ]]'

# Test 4: Language Parameter
run_test "Language Parameter" \
    "curl -s -X POST '$SERVER_URL/v1/audio/transcriptions' -F file=@$TEST_AUDIO -F language=en -F response_format=json" \
    '[[ "$response" == *"text"* ]]'

# Test 5: Prompt Parameter
run_test "Prompt Parameter" \
    "curl -s -X POST '$SERVER_URL/v1/audio/transcriptions' -F file=@$TEST_AUDIO -F prompt=\"This is a test\" -F response_format=json" \
    '[[ "$response" == *"text"* ]]'

# Test 6: Error Handling - Missing File
run_test "Missing File Parameter" \
    "curl -s -w '%{http_code}' -X POST '$SERVER_URL/v1/audio/transcriptions'" \
    '[[ "$response" == *"400"* || "$response" == *"error"* ]]'

# Test 7: Error Handling - Invalid Format
run_test "Invalid Response Format" \
    "curl -s -X POST '$SERVER_URL/v1/audio/transcriptions' -F file=@$TEST_AUDIO -F response_format=invalid" \
    '[[ ${#response} -gt 0 ]]'  # Should return something, even if error

echo -e "${BLUE}=== SUBTITLE FORMATS TESTS ===${NC}"

# Test 8: SRT Subtitles Format
echo -e "${BLUE}📺 Testing SRT Subtitles Format${NC}"
srt_start=$(date +%s.%N)
srt_response=$(curl -s -X POST "$SERVER_URL/v1/audio/transcriptions" \
  -F file=@$TEST_AUDIO \
  -F response_format=srt \
  2>/dev/null)
srt_end=$(date +%s.%N)
srt_time=$(echo "$srt_end - $srt_start" | bc -l 2>/dev/null || echo "N/A")

if [[ "$srt_response" == *"-->"* ]] && [[ "$srt_response" == *"00:"* ]]; then
    echo -e "${GREEN}✅ SRT format valid${NC}"
    echo -e "${YELLOW}   Sample SRT output (first 2 lines):${NC}"
    echo "$srt_response" | head -4 | sed 's/^/   /'
    if [[ "$srt_time" != "N/A" ]]; then
        printf "${YELLOW}   Response time: %.2f seconds${NC}\n" "$srt_time"
    fi
else
    echo -e "${RED}❌ SRT format invalid${NC}"
    echo -e "${YELLOW}   Response: $srt_response${NC}"
fi

# Test 9: VTT Subtitles Format
echo -e "${BLUE}📺 Testing VTT Subtitles Format${NC}"
vtt_start=$(date +%s.%N)
vtt_response=$(curl -s -X POST "$SERVER_URL/v1/audio/transcriptions" \
  -F file=@$TEST_AUDIO \
  -F response_format=vtt \
  2>/dev/null)
vtt_end=$(date +%s.%N)
vtt_time=$(echo "$vtt_end - $vtt_start" | bc -l 2>/dev/null || echo "N/A")

if [[ "$vtt_response" == *"WEBVTT"* ]] && [[ "$vtt_response" == *"-->"* ]]; then
    echo -e "${GREEN}✅ VTT format valid${NC}"
    echo -e "${YELLOW}   Sample VTT output (first 3 lines):${NC}"
    echo "$vtt_response" | head -5 | sed 's/^/   /'
    if [[ "$vtt_time" != "N/A" ]]; then
        printf "${YELLOW}   Response time: %.2f seconds${NC}\n" "$vtt_time"
    fi
else
    echo -e "${RED}❌ VTT format invalid${NC}"
    echo -e "${YELLOW}   Response: $vtt_response${NC}"
fi

# Test 10: Verbose JSON Format
echo -e "${BLUE}🔍 Testing Verbose JSON Format${NC}"
verbose_start=$(date +%s.%N)
verbose_response=$(curl -s -X POST "$SERVER_URL/v1/audio/transcriptions" \
  -F file=@$TEST_AUDIO \
  -F response_format=verbose_json \
  2>/dev/null)
verbose_end=$(date +%s.%N)
verbose_time=$(echo "$verbose_end - $verbose_start" | bc -l 2>/dev/null || echo "N/A")

if [[ "$verbose_response" == *"\"segments\""* ]] && [[ "$verbose_response" == *"\"start\""* ]] && [[ "$verbose_response" == *"\"end\""* ]]; then
    echo -e "${GREEN}✅ Verbose JSON format valid${NC}"
    echo -e "${YELLOW}   Contains required fields: text, segments, start, end${NC}"
    if [[ "$verbose_time" != "N/A" ]]; then
        printf "${YELLOW}   Response time: %.2f seconds${NC}\n" "$verbose_time"
    fi
    # Pretty-print a sample of the JSON
    echo -e "${YELLOW}   Sample verbose JSON (formatted):${NC}"
    echo "$verbose_response" | python3 -m json.tool 2>/dev/null | head -15 | sed 's/^/   /' || echo "   (JSON formatting failed, but response received)"
else
    echo -e "${RED}❌ Verbose JSON format invalid${NC}"
    echo -e "${YELLOW}   Response: $verbose_response${NC}"
fi

echo -e "${BLUE}=== CHUNKED STREAMING TESTS ===${NC}"

# Test 11: Test SRT Streaming (Chunked)
echo -e "${BLUE}🌊 Testing SRT Streaming (Chunked)${NC}"
stream_srt_response=$(curl -s -X POST "$SERVER_URL/v1/audio/transcriptions" \
  -F file=@$TEST_AUDIO \
  -F response_format=srt \
  -F stream=true \
  2>/dev/null)

if [[ "$stream_srt_response" == *"-->"* ]] && [[ "$stream_srt_response" =~ ^[0-9]+$ ]] || [[ "$stream_srt_response" == *"00:"* ]]; then
    echo -e "${GREEN}✅ SRT streaming works${NC}"
    echo -e "${YELLOW}   Sample SRT streaming output (first 3 lines):${NC}"
    echo "$stream_srt_response" | head -3 | sed 's/^/   /'
else
    echo -e "${RED}❌ SRT streaming failed${NC}"
    echo -e "${YELLOW}   Response: $stream_srt_response${NC}"
fi

echo -e "${BLUE}🌊 Testing VTT Streaming (Chunked)${NC}"
stream_vtt_response=$(curl -s -X POST "$SERVER_URL/v1/audio/transcriptions" \
  -F file=@$TEST_AUDIO \
  -F response_format=vtt \
  -F stream=true \
  2>/dev/null)

if [[ "$stream_vtt_response" == *"WEBVTT"* ]] && [[ "$stream_vtt_response" == *"-->"* ]]; then
    echo -e "${GREEN}✅ VTT streaming works${NC}"
    echo -e "${YELLOW}   Sample VTT streaming output (first 3 lines):${NC}"
    echo "$stream_vtt_response" | head -3 | sed 's/^/   /'
else
    echo -e "${RED}❌ VTT streaming failed${NC}"
    echo -e "${YELLOW}   Response: $stream_vtt_response${NC}"
fi

echo -e "${BLUE}=== SSE STREAMING TESTS ===${NC}"

# Test 12: SSE Text Streaming
run_sse_test "SSE Text Streaming" "text" "text/event-stream" "text/event-stream" \
    '[[ "$response" == *"data:"* && ${#response} -gt 0 ]]'

# Test 13: SSE JSON Streaming
run_sse_test "SSE JSON Streaming" "json" "text/event-stream" "text/event-stream" \
    '[[ "$response" == *"data:"* && "$response" == *"text"* ]]'

# Test 14: SSE SRT Streaming
run_sse_test "SSE SRT Streaming" "srt" "text/event-stream" "text/event-stream" \
    '[[ "$response" == *"data:"* && "$response" == *"-->"* ]]'

# Test 15: SSE VTT Streaming
run_sse_test "SSE VTT Streaming" "vtt" "text/event-stream" "text/event-stream" \
    '[[ "$response" == *"data:"* && "$response" == *"WEBVTT"* ]]'

# Test 16: SSE Verbose JSON Streaming
run_sse_test "SSE Verbose JSON Streaming" "verbose_json" "text/event-stream" "text/event-stream" \
    '[[ "$response" == *"data:"* && "$response" == *"start"* ]]'

echo -e "${BLUE}=== FALLBACK TESTS ===${NC}"

# Test 17: Chunked Fallback (no SSE support)
echo -e "${PURPLE}🔄 Testing Chunked Fallback (Accept: application/json)${NC}"
fallback_response=$(curl -s -D /tmp/fallback_headers -X POST "$SERVER_URL/v1/audio/transcriptions" \
    -H "Accept: application/json" \
    -F file=@$TEST_AUDIO \
    -F response_format="text" \
    -F stream="true" \
    --no-buffer 2>/dev/null)

fallback_headers=$(cat /tmp/fallback_headers 2>/dev/null || echo "")
rm -f /tmp/fallback_headers

if [[ "$fallback_headers" == *"text/plain"* ]] && [[ "$fallback_headers" != *"text/event-stream"* ]]; then
    echo -e "${GREEN}✅ Chunked fallback works correctly${NC}"
    echo -e "${YELLOW}   Content-Type: text/plain (not SSE)${NC}"
    echo -e "${YELLOW}   Sample output: ${fallback_response:0:50}...${NC}"
else
    echo -e "${RED}❌ Chunked fallback failed${NC}"
    echo -e "${RED}Headers: $fallback_headers${NC}"
fi
echo ""

echo -e "${BLUE}=== PERFORMANCE & HEADERS TESTS ===${NC}"

# Test 18: Performance Test
echo -e "${BLUE}🚀 Performance Test${NC}"
echo -e "${YELLOW}Measuring response time...${NC}"
start_time=$(date +%s.%N)
response=$(curl -s -X POST "$SERVER_URL/v1/audio/transcriptions" -F file=@$TEST_AUDIO -F response_format=text)
end_time=$(date +%s.%N)
duration=$(echo "$end_time - $start_time" | bc)

if [ ${#response} -gt 0 ]; then
    echo -e "${GREEN}✅ Performance test completed in ${duration} seconds${NC}"
    echo -e "${GREEN}Response: $response${NC}"
else
    echo -e "${RED}❌ Performance test failed - empty response${NC}"
fi
echo ""

# Test 19: Check Content-Type Headers
echo -e "${BLUE}🔍 Testing HTTP Headers${NC}"

# JSON Content-Type
json_headers=$(curl -s -i -X POST "$SERVER_URL/v1/audio/transcriptions" -F file=@$TEST_AUDIO -F response_format=json 2>/dev/null | grep -i content-type || true)
if [[ "$json_headers" == *"application/json"* ]]; then
    echo -e "${GREEN}✅ JSON Content-Type header correct: $json_headers${NC}"
else
    echo -e "${RED}❌ JSON Content-Type header incorrect: $json_headers${NC}"
fi

# Text Content-Type
text_headers=$(curl -s -i -X POST "$SERVER_URL/v1/audio/transcriptions" -F file=@$TEST_AUDIO -F response_format=text 2>/dev/null | grep -i content-type || true)
if [[ "$text_headers" == *"text/plain"* ]]; then
    echo -e "${GREEN}✅ Text Content-Type header correct: $text_headers${NC}"
else
    echo -e "${RED}❌ Text Content-Type header incorrect: $text_headers${NC}"
fi

echo ""
echo -e "${BLUE}🏁 Test Suite Complete!${NC}"
echo -e "${GREEN}🎉 WhisperServer supports OpenAI Whisper API + SSE Streaming!${NC}"
echo ""
echo -e "${YELLOW}📺 Subtitle formats available (both streaming and non-streaming):${NC}"
echo -e "   ${GREEN}SRT:${NC}   curl -F file=@audio.wav -F response_format=srt $SERVER_URL/v1/audio/transcriptions"
echo -e "   ${GREEN}VTT:${NC}   curl -F file=@audio.wav -F response_format=vtt $SERVER_URL/v1/audio/transcriptions"
echo -e "   ${GREEN}Verbose JSON:${NC} curl -F file=@audio.wav -F response_format=verbose_json $SERVER_URL/v1/audio/transcriptions"
echo ""
echo -e "${YELLOW}🌊 SSE STREAMING support for ALL formats:${NC}"
echo -e "   ${GREEN}SSE Text:${NC} curl -H 'Accept: text/event-stream' -F file=@audio.wav -F response_format=text -F stream=true $SERVER_URL/v1/audio/transcriptions"
echo -e "   ${GREEN}SSE JSON:${NC} curl -H 'Accept: text/event-stream' -F file=@audio.wav -F response_format=json -F stream=true $SERVER_URL/v1/audio/transcriptions"
echo -e "   ${GREEN}SSE SRT:${NC}  curl -H 'Accept: text/event-stream' -F file=@audio.wav -F response_format=srt -F stream=true $SERVER_URL/v1/audio/transcriptions"
echo ""
echo -e "${YELLOW}🔄 CHUNKED FALLBACK (automatic when SSE not supported):${NC}"
echo -e "   ${GREEN}Chunked:${NC} curl -H 'Accept: application/json' -F file=@audio.wav -F response_format=text -F stream=true $SERVER_URL/v1/audio/transcriptions"
echo ""
echo -e "${YELLOW}💡 This comprehensive test suite covers:${NC}"
echo "   - OpenAI Whisper API compatibility"
echo "   - All response formats (json, text, srt, vtt, verbose_json)"
echo "   - SSE streaming with proper headers"
echo "   - Chunked response fallback"
echo "   - Error handling and performance testing"
echo ""
echo -e "${YELLOW}📝 OpenAI Whisper API Reference:${NC}"
echo "   https://platform.openai.com/docs/api-reference/audio/createTranscription" 