#!/usr/bin/env bats
# clef-fixtures.bats — the wire captures of the real clef_mlx.py serve are the
# source of truth for fake-clef.py and the client tests (spec section 13).

load test_helper

WIRE="$REPO_ROOT/test/fixtures/clef-wire"

@test "the captures hold health, a noul answer, a choice answer, a 503 and a 413" {
    run python3 - "$WIRE" <<'PY'
import json, os, sys
w = sys.argv[1]
def load(name):
    with open(os.path.join(w, name), encoding="utf-8") as f:
        return json.load(f)
noul = load("noul-response.json")
assert {"answers", "usage"} <= set(noul), sorted(noul)
a = noul["answers"]["destructive"]
assert a["type"] == "noul" and 0.0 <= float(a["noul"]) <= 1.0
assert isinstance(noul["usage"]["input_tokens"], int)
choice = load("choice-response.json")
r = choice["answers"]["risk"]
assert r["type"] == "choice" and r["choice"] in r["probabilities"]
assert set(r["probabilities"]) == {"safe", "caution", "dangerous"}
for name in ("noul-request.json", "choice-request.json"):
    body = load(name)
    assert body["truncate"] is False, name
    assert "model" not in body, name
assert load("noul-request.json")["questions"]["destructive"]["type"] == "noul"
assert load("choice-request.json")["questions"]["risk"]["type"] == "choice"
assert "detail" in load("busy-503.json")
assert "maximum context length exceeded" in load("too-long-413.json")["detail"]
with open(os.path.join(w, "busy-503.status"), encoding="utf-8") as f:
    assert f.read().strip() == "503"
assert isinstance(load("health.json"), dict)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the fake server answers 413 for a long state with truncate false, and logs each request" {
    start_fake_clef '{"too_long": 20}'
    run python3 - "$CLUX_CLEF_URL" "$CLUX_CLEF_KEY" <<'PY'
import json, sys, urllib.error, urllib.request
url, key = sys.argv[1:3]
def post(body):
    request = urllib.request.Request(url + "/v1/systemone", data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=5) as answer:
            return 200, json.loads(answer.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())
questions = {"secret": {"type": "noul", "instructions": "Secret?"}}
long_state = "x" * 40
code, body = post({"state": long_state, "questions": questions, "truncate": False})
assert code == 413, (code, body)
assert "maximum context length exceeded" in body["detail"], body
# With no truncate field the server cuts and answers.
assert post({"state": long_state, "questions": questions})[0] == 200
assert post({"state": "x", "questions": questions, "truncate": False})[0] == 200
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(fake_clef_requests truncate | sort -u | tr '\n' ' ')" = 'false null ' ] \
        || { fake_clef_requests truncate; false; }
}

@test "the fake server answers in the captured wire format" {
    start_fake_clef '{"answers": {"destructive": 0.85, "risk": "caution"}}'
    run python3 - "$WIRE" "$CLUX_CLEF_URL" "$CLUX_CLEF_KEY" <<'PY'
import json, os, sys, urllib.request
wire, url, key = sys.argv[1:4]
def load(name):
    with open(os.path.join(wire, name), encoding="utf-8") as f:
        return json.load(f)
def post(body):
    req = urllib.request.Request(url + "/v1/systemone", data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())
def keys(value):
    return sorted(value)
with urllib.request.urlopen(url + "/health", timeout=5) as r:
    assert json.loads(r.read())["status"] == "ok"
real, fake = load("noul-response.json"), post(load("noul-request.json"))
assert keys(fake) == keys(real), (keys(fake), keys(real))
assert keys(fake["usage"]) == keys(real["usage"])
assert keys(fake["answers"]["destructive"]) == keys(real["answers"]["destructive"])
assert fake["answers"]["destructive"]["noul"] == 0.85
real, fake = load("choice-response.json"), post(load("choice-request.json"))
assert keys(fake["answers"]["risk"]) == keys(real["answers"]["risk"])
assert keys(fake["answers"]["risk"]["probabilities"]) == keys(real["answers"]["risk"]["probabilities"])
assert fake["answers"]["risk"]["choice"] == "caution"
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the fake server applies rules, a status queue and a request log" {
    start_fake_clef '{"status": [503], "rules": [
        {"equals": "hunter2", "answers": {"secret": 0.18}},
        {"contains": "cut", "min_lines": 2, "input_tokens": 512},
        {"contains": "LONG", "min_length": 10, "input_tokens": 512},
        {"asks": "prompt_injection", "fail": 500}]}'
    run python3 - "$CLUX_CLEF_URL" "$CLUX_CLEF_KEY" <<'PY'
import json, sys, urllib.error, urllib.request
url, key = sys.argv[1:3]
secret = {"secret": {"type": "noul", "instructions": "Secret?"}}
def post(state, questions=secret):
    req = urllib.request.Request(url + "/v1/systemone",
        data=json.dumps({"state": state, "questions": questions}).encode(),
        headers={"Authorization": "Bearer " + key}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return 200, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, None
assert post("x")[0] == 503
code, body = post("hunter2")
assert code == 200 and body["answers"]["secret"]["noul"] == 0.18
assert post("cut\ncut")[1]["usage"]["input_tokens"] == 512
assert post("cut")[1]["usage"]["input_tokens"] < 512
assert post("LONG and long")[1]["usage"]["input_tokens"] == 512
assert post("LONG")[1]["usage"]["input_tokens"] < 512
two = dict(secret, other={"type": "noul", "instructions": "?"})
assert post("cut\ncut", two)[1]["usage"]["input_tokens"] == 1024
assert post("x", {"prompt_injection": {"type": "noul", "instructions": "?"}})[0] == 500
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(fake_clef_states secret | head -n 2)" = $'"x"\n"hunter2"' ]
}

@test "the fake server refuses a wrong key and answers health with no key" {
    start_fake_clef '{}'
    run curl -s -o /dev/null -w '%{http_code}' -X POST "$CLUX_CLEF_URL/v1/systemone" \
        -H 'Authorization: Bearer wrong' -d '{}'
    [ "$output" = 401 ]
    run curl -fsS "$CLUX_CLEF_URL/health"
    [ "$status" -eq 0 ]
}
