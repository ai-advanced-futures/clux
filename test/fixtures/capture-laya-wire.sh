#!/usr/bin/env bash
# capture-laya-wire.sh — record the wire format of the real laya-serve into
# test/fixtures/laya-wire/. fake-laya.py and the client tests use these files
# as the source of truth. Run it again after a change of the laya version.
#
#   CLUX_LAYA_PYTHON=<python that has laya> test/fixtures/capture-laya-wire.sh
#
# The first start downloads the English checkpoint when it is not in the
# Hugging Face cache.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/laya-wire"
py="${CLUX_LAYA_PYTHON:-${XDG_DATA_HOME:-$HOME/.local/share}/clux/laya/bin/python3}"
serve="$(dirname "$py")/laya-serve"
key=capture-key
work=$(mktemp -d)
port=$("$py" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
url="http://127.0.0.1:$port"

LAYA_HOST=127.0.0.1 LAYA_PORT="$port" LAYA_API_KEY="$key" LAYA_LOG_LEVEL=warning \
    LAYA_MODELS=english LAYA_MAX_CONCURRENT=1 USE_TF=0 \
    "$serve" > "$work/serve.log" 2>&1 < /dev/null &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 600); do
    curl -fsS "$url/health" > /dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || { cat "$work/serve.log" >&2; exit 1; }
    sleep .5
done

post() {
    curl -sS -X POST "$url/v1/systemone" -H "Authorization: Bearer $key" \
        -H 'Content-Type: application/json' --data-binary "@$1"
}

mkdir -p "$out"
curl -fsS "$url/health" > "$out/health.json"

cat > "$out/noul-request.json" <<'JSON'
{"state": "rm -rf ~/dev", "model": "english", "questions": {"destructive": {"type": "noul", "instructions": "Would the command delete data, overwrite files, or change the system in a way that is hard to undo?"}}}
JSON
post "$out/noul-request.json" > "$out/noul-response.json"

cat > "$out/choice-request.json" <<'JSON'
{"state": "rm -rf ~/dev", "model": "english", "questions": {"risk": {"type": "choice", "instructions": "How risky is it to run this shell command?", "criteria": {"safe": null, "caution": null, "dangerous": null}}}}
JSON
post "$out/choice-request.json" > "$out/choice-response.json"

# LAYA_MAX_CONCURRENT=1: of 16 long requests at one time, the server refuses
# each request that comes while another one is in progress. Keep one 503.
"$py" -c 'import json; print(json.dumps({"state": "word " * 400, "model": "english", "questions": {"a": {"type": "noul", "instructions": "Is this text long?"}}}))' > "$work/long.json"
pids=()
for i in $(seq 1 16); do
    curl -sS -o "$work/$i.body" -w '%{http_code}\n' -X POST "$url/v1/systemone" \
        -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
        --data-binary "@$work/long.json" > "$work/$i.status" &
    pids+=("$!")
done
wait "${pids[@]}"
for i in $(seq 1 16); do
    if [ "$(cat "$work/$i.status")" = 503 ]; then
        cp "$work/$i.body" "$out/busy-503.json"
        echo 503 > "$out/busy-503.status"
        exit 0
    fi
done
echo 'no 503 in 16 requests at one time: run the script again' >&2
exit 1
