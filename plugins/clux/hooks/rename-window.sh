#!/usr/bin/env bash

# Smart tmux window naming via OpenAI Responses API
# Called on UserPromptSubmit — classifies the prompt into a single verb
# and renames the tmux window accordingly.
#
# Requires: jq, curl
# Debug log: /tmp/clux.log (only when CLUX_DEBUG=1)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/../scripts/helpers.sh"

DEBUG_LOG="/tmp/clux.log"
CLUX_DEBUG="${CLUX_DEBUG:-0}"

# --- Logging (file logging only when debug is enabled) ---

debug_msg() {
    if [ "$CLUX_DEBUG" = "1" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEBUG_LOG"
        tmux display-message "DEBUG: $1" 2>/dev/null
    fi
}

error_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$DEBUG_LOG"
    tmux display-message "CLUX ERROR: $1" 2>/dev/null
}

# --- Early exit guards (fast path, no API calls) ---

[ "$NOTIFY_SMART_TITLE" = "off" ] && exit 0
[ -z "$TMUX" ] && exit 0

if [ -z "$CLUX_OPENAI_API_KEY" ]; then
    error_msg "CLUX_OPENAI_API_KEY not set"
    exit 0
fi

if ! command -v jq &>/dev/null; then
    error_msg "jq is required but not installed"
    exit 0
fi

# Parse JSON from stdin
[ -t 0 ] && exit 0

INPUT=$(head -c 8192)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

[ -z "$PROMPT" ] && exit 0

# Skip very short prompts (unless slash command)
if [ ${#PROMPT} -le 10 ] && [[ "$PROMPT" != /* ]]; then
    exit 0
fi

debug_msg "Prompt: ${#PROMPT} chars — ${PROMPT:0:50}..."

# --- Background the API call so the hook returns immediately ---
(
    OPENAI_MODEL="${CLUX_OPENAI_MODEL:-gpt-5-nano}"
    OPENAI_TIMEOUT="${CLUX_OPENAI_TIMEOUT:-10}"

    debug_msg "Model: $OPENAI_MODEL"

    ALLOWED_VERBS="snooping wrenching poking hammering scribbling tidying squashing grilling yeeting fiddling scheming doodling herding polishing forging dissecting squeezing gluing rigging blasting"

    # Truncate prompt to 500 chars — enough context to classify
    TRUNCATED_PROMPT="${PROMPT:0:500}"

    # Build JSON payload with structured outputs
    JSON_PAYLOAD=$(jq -n \
        --arg model "$OPENAI_MODEL" \
        --arg instructions "Classify this developer prompt into ONE verb that best describes the activity. Pick from: $ALLOWED_VERBS. Return ONLY the verb." \
        --arg input "$TRUNCATED_PROMPT" \
        --arg verbs "$ALLOWED_VERBS" \
        '{
            model: $model,
            instructions: $instructions,
            input: $input,
            max_output_tokens: 50,
            store: false,
            reasoning: { effort: "minimal" },
            text: {
                format: {
                    type: "json_schema",
                    name: "verb_classification",
                    strict: true,
                    schema: {
                        type: "object",
                        properties: {
                            verb: {
                                type: "string",
                                description: "Single lowercase verb from the allowed list",
                                enum: ($verbs | split(" "))
                            }
                        },
                        required: ["verb"],
                        additionalProperties: false
                    }
                }
            }
        }')

    # Call OpenAI Responses API (hide key from ps via config stdin)
    RESPONSE=$(curl -s \
        --connect-timeout 5 \
        --max-time "$OPENAI_TIMEOUT" \
        -H "Content-Type: application/json" \
        -H @- \
        -d "$JSON_PAYLOAD" \
        https://api.openai.com/v1/responses \
        <<< "Authorization: Bearer $CLUX_OPENAI_API_KEY" 2>/dev/null)

    CURL_EXIT=$?
    if [ "$CURL_EXIT" -ne 0 ]; then
        error_msg "curl failed (exit $CURL_EXIT)"
        exit 1
    fi

    if [ -z "$RESPONSE" ]; then
        error_msg "Empty response from API"
        exit 1
    fi

    debug_msg "API response: ${#RESPONSE} bytes"

    # Check for errors using jq (reliable across whitespace variations)
    API_STATUS=$(printf '%s' "$RESPONSE" | jq -r '.status // empty' 2>/dev/null)
    API_ERROR=$(printf '%s' "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)

    if [ -n "$API_ERROR" ]; then
        error_msg "API error: $API_ERROR"
        exit 1
    fi

    if [ "$API_STATUS" != "completed" ]; then
        error_msg "API status: $API_STATUS (expected completed)"
        exit 1
    fi

    # Extract verb from structured output
    NAME=$(printf '%s' "$RESPONSE" | jq -r '
        .output[]
        | select(.type == "message")
        | .content[]
        | select(.type == "output_text")
        | .text
    ' 2>/dev/null | head -1 | jq -r '.verb // empty' 2>/dev/null)

    debug_msg "Extracted verb: '$NAME'"

    # Validate with graceful fallback
    NAME=$(printf '%s' "$NAME" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    if [ -n "$NAME" ] && [ ${#NAME} -le 20 ] && [[ "$NAME" =~ ^[a-z]+$ ]]; then
        if echo "$ALLOWED_VERBS" | grep -qw "$NAME"; then
            debug_msg "Verb in allowed list: $NAME"
        else
            debug_msg "Verb not in list but acceptable: $NAME"
        fi
    else
        debug_msg "Invalid or empty verb '$NAME', falling back to 'working'"
        NAME="working"
    fi

    # Handle window name collisions
    EXISTING=$(tmux list-windows -F '#{window_name}' 2>/dev/null | grep -c "^${NAME}\(-[0-9]*\)\?$")

    if [ "$EXISTING" -gt 0 ]; then
        NAME="${NAME}-${EXISTING}"
        debug_msg "Collision: renamed to $NAME"
    fi

    # Rename the tmux window
    if tmux rename-window -t "$TMUX_PANE" "$NAME" 2>/dev/null; then
        tmux set-window-option -t "$TMUX_PANE" automatic-rename off 2>/dev/null
        debug_msg "Window renamed to: $NAME"
    else
        error_msg "Failed to rename window"
        exit 1
    fi
) &

exit 0
