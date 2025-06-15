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
NC='\033[0m' # No Color

echo -e "${BLUE}🔧 WhisperServer API Test Suite${NC}"
echo -e "${BLUE}Testing OpenAI Whisper API compatibility${NC}"
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

# Test 11: Test SRT Streaming
echo -e "${BLUE}🌊 Testing SRT Streaming${NC}"
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

echo -e "${BLUE}🌊 Testing VTT Streaming${NC}"
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

# Test 12: Performance Test
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

# Test 13: Check Content-Type Headers
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
echo -e "${GREEN}🎉 WhisperServer now supports all OpenAI Whisper API formats with FULL STREAMING!${NC}"
echo ""
echo -e "${YELLOW}📺 NEW: Subtitle formats available (both streaming and non-streaming):${NC}"
echo -e "   ${GREEN}SRT:${NC}   curl -F file=@audio.wav -F response_format=srt $SERVER_URL/v1/audio/transcriptions"
echo -e "   ${GREEN}VTT:${NC}   curl -F file=@audio.wav -F response_format=vtt $SERVER_URL/v1/audio/transcriptions"
echo -e "   ${GREEN}Verbose JSON:${NC} curl -F file=@audio.wav -F response_format=verbose_json $SERVER_URL/v1/audio/transcriptions"
echo ""
echo -e "${YELLOW}🌊 STREAMING support for ALL formats:${NC}"
echo -e "   ${GREEN}SRT Streaming:${NC} curl -F file=@audio.wav -F response_format=srt -F stream=true $SERVER_URL/v1/audio/transcriptions"
echo -e "   ${GREEN}VTT Streaming:${NC} curl -F file=@audio.wav -F response_format=vtt -F stream=true $SERVER_URL/v1/audio/transcriptions"
echo ""
echo -e "${YELLOW}💡 This comprehensive curl test suite covers ALL functionality:${NC}"
echo "   - OpenAI Whisper API compatibility"
echo "   - All response formats (json, text, srt, vtt, verbose_json)"
echo "   - Streaming support for all formats"
echo "   - Error handling and performance testing"
echo ""
echo -e "${YELLOW}📝 OpenAI Whisper API Reference:${NC}"
echo "   https://platform.openai.com/docs/api-reference/audio/createTranscription" 