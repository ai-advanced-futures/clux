#!/usr/bin/env bash
# capture-clef-wire.sh — record the wire format of the real clef_mlx.py serve
# into test/fixtures/clef-wire/. fake-clef.py and the client tests use these
# files as the source of truth. Run it again after a model change.
#
#   CLUX_CLEF_URL=http://127.0.0.1:8765 test/fixtures/capture-clef-wire.sh
#
# It starts no server: the user runs the Clef server (docs/reference.md).
# busy-503.json and busy-503.status are not captured here: clef_mlx.py serve
# gives no 503. They are the answer of a proxy in front of the server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/clef-wire"
url="${CLUX_CLEF_URL:?set CLUX_CLEF_URL to the URL of your Clef server}"
auth=()
[ -z "${CLUX_CLEF_KEY:-}" ] || auth=(-H "Authorization: Bearer $CLUX_CLEF_KEY")

post() {
    curl -sS -X POST "$url/v1/systemone" "${auth[@]}" \
        -H 'Content-Type: application/json' --data-binary "@$1"
}

mkdir -p "$out"
curl -fsS "${auth[@]}" "$url/health" > "$out/health.json"

cat > "$out/noul-request.json" <<'JSON'
{"state": "rm -rf ~/dev", "truncate": false, "questions": {"destructive": {"type": "noul", "instructions": "Would the command delete data, overwrite files, or change the system in a way that is hard to undo?"}}}
JSON
post "$out/noul-request.json" > "$out/noul-response.json"

cat > "$out/choice-request.json" <<'JSON'
{"state": "rm -rf ~/dev", "truncate": false, "questions": {"risk": {"type": "choice", "instructions": "How risky is it to run this shell command?", "criteria": {"safe": null, "caution": null, "dangerous": null}}}}
JSON
post "$out/choice-request.json" > "$out/choice-response.json"

# A state above the 16,384 tokens of Clef with "truncate": false gives 413.
python3 -c 'import json; print(json.dumps({"state": "word " * 40000, "truncate": False,
    "questions": {"a": {"type": "noul", "instructions": "Is this text long?"}}}))' > "$out/long.json"
code=$(curl -sS -o "$out/too-long-413.json" -w '%{http_code}' -X POST "$url/v1/systemone" \
    "${auth[@]}" -H 'Content-Type: application/json' --data-binary "@$out/long.json")
rm -f "$out/long.json"
[ "$code" = 413 ] || { echo "a long state gave $code, not 413" >&2; exit 1; }
