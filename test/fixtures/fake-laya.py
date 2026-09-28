#!/usr/bin/env python3
"""fake-laya.py: a stand-in for laya-serve in the clux tests.

GET /health and POST /v1/systemone answer in the wire format that
test/fixtures/capture-laya-wire.sh captured from laya-serve 0.3.21. The
captures in test/fixtures/laya-wire/ are the templates, so they stay the
source of truth.

The answers come from the JSON file that CLUX_FAKE_LAYA_ANSWERS names. The
fake reads the file again for each request, so a test can change it between
two verbs:

  {
    "answers": {"secret": 0.9, "risk": "caution"},    default for each question
    "rules": [                                         the first match wins
      {"equals": "hunter2", "answers": {"secret": 0.18}},
      {"contains": "AKIA", "min_lines": 2, "min_length": 10, "answers": {}},
      {"contains": "cut", "input_tokens": 512},  tokens of each question row
      {"asks": "prompt_injection", "fail": 500}
    ],
    "status": [503],       the first requests get these codes, then 200
    "retry_after": "1",    the Retry-After header of a 503 (as laya-serve)
    "delay": 0,            seconds to wait before each answer
    "body": "not json",    a raw body instead of an answer
    "health_status": 200   the code of GET /health
  }

A rule matches when all of its conditions are true: "equals" (the full state
text), "contains", "min_lines", "min_length", and "asks" (a question name in
the request). A state that is a JSON object is matched as its sorted JSON text.

Environment: LAYA_HOST (default 127.0.0.1), LAYA_PORT (0 selects a free port),
LAYA_API_KEY, CLUX_FAKE_LAYA_ANSWERS, CLUX_FAKE_LAYA_PORT_FILE (gets the
port), CLUX_FAKE_LAYA_LOG (one JSON line for each request: the state, the
question names and the model), CLUX_FAKE_LAYA_WIRE (the captures; the default
is laya-wire next to the real path of this file), CLUX_FAKE_LAYA_IGNORE_TERM
(1: the server ignores SIGTERM, as a slow server).
"""
import copy
import json
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.realpath(__file__))
WIRE = os.environ.get("CLUX_FAKE_LAYA_WIRE") or os.path.join(HERE, "laya-wire")
BUILTIN_CHOICE = {"risk": "safe", "state": "other"}
LOCK = threading.Lock()
SERVED = [0]


def load(name):
    with open(os.path.join(WIRE, name), encoding="utf-8") as handle:
        return json.load(handle)


NOUL = load("noul-response.json")
CHOICE = load("choice-response.json")
HEALTH = load("health.json")
BUSY = load("busy-503.json")


def settings():
    try:
        with open(os.environ.get("CLUX_FAKE_LAYA_ANSWERS", ""), encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def state_text(state):
    return state if isinstance(state, str) else json.dumps(state, sort_keys=True)


def matches(rule, text, questions):
    if "equals" in rule and text != rule["equals"]:
        return False
    if "contains" in rule and rule["contains"] not in text:
        return False
    if text.count("\n") + 1 < rule.get("min_lines", 1):
        return False
    if len(text) < rule.get("min_length", 0):
        return False
    if "asks" in rule and rule["asks"] not in questions:
        return False
    return True


def pick(conf, text, questions, name, default):
    for rule in conf.get("rules", []):
        if name in rule.get("answers", {}) and matches(rule, text, questions):
            return rule["answers"][name]
    return conf.get("answers", {}).get(name, default)


def set_confidence(answer, value):
    for key in ("confidence", "answer_confidence"):
        if key in answer:
            answer[key] = value


def answer(conf, state, questions):
    text = state_text(state)
    result = copy.deepcopy(NOUL)
    result["answers"] = {}
    for name, question in questions.items():
        if question.get("type") == "choice":
            labels = list(question.get("criteria") or {})
            fallback = BUILTIN_CHOICE.get(name, labels[0] if labels else "")
            label = pick(conf, text, questions, name, fallback)
            one = copy.deepcopy(CHOICE["answers"]["risk"])
            one["choice"] = label
            one["probabilities"] = {item: (1.0 if item == label else 0.0) for item in labels}
            set_confidence(one, 1.0)
        else:
            value = float(pick(conf, text, questions, name, 0.0))
            one = copy.deepcopy(NOUL["answers"]["destructive"])
            one["noul"] = value
            set_confidence(one, max(value, 1.0 - value))
        result["answers"][name] = one
    tokens = min(512, len(text) // 2)
    for rule in conf.get("rules", []):
        if "input_tokens" in rule and matches(rule, text, questions):
            tokens = rule["input_tokens"]
            break
    # laya-serve gives the sum over the question rows, one row for each
    # question, each cut at 512.
    result["usage"]["input_tokens"] = tokens * max(1, len(questions))
    return result


def log(body):
    path = os.environ.get("CLUX_FAKE_LAYA_LOG")
    if not path:
        return
    line = json.dumps({"state": body.get("state"),
                       "questions": sorted(body.get("questions") or {}),
                       "model": body.get("model")})
    with LOCK:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, code, body=None, raw=None, retry_after=None):
        data = raw.encode("utf-8") if raw is not None else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        if retry_after is not None:
            self.send_header("Retry-After", retry_after)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        # The real /health needs no key, so the fake needs none.
        if self.path != "/health":
            return self.reply(404, {"detail": "Not Found"})
        code = settings().get("health_status", 200)
        return self.reply(code, HEALTH if code == 200 else {"detail": "down"})

    def do_POST(self):
        if self.path != "/v1/systemone":
            return self.reply(404, {"detail": "Not Found"})
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        key = os.environ.get("LAYA_API_KEY")
        if key and self.headers.get("Authorization") != "Bearer " + key:
            return self.reply(401, {"detail": "invalid or missing bearer token"})
        body = json.loads(raw)
        questions = body.get("questions") or {}
        conf = settings()
        log(body)
        with LOCK:
            index = SERVED[0]
            SERVED[0] += 1
        statuses = conf.get("status", [])
        if index < len(statuses) and statuses[index] != 200:
            if statuses[index] == 503:
                return self.reply(503, BUSY, retry_after=str(conf.get("retry_after", "1")))
            return self.reply(statuses[index], {"detail": "error"})
        text = state_text(body.get("state"))
        for rule in conf.get("rules", []):
            if "fail" in rule and matches(rule, text, questions):
                return self.reply(rule["fail"], {"detail": "inference failed"})
        if conf.get("delay"):
            time.sleep(float(conf["delay"]))
        if "body" in conf:
            return self.reply(200, raw=conf["body"])
        return self.reply(200, answer(conf, body.get("state"), questions))


def main():
    if os.environ.get("CLUX_FAKE_LAYA_IGNORE_TERM") == "1":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    server = ThreadingHTTPServer((os.environ.get("LAYA_HOST", "127.0.0.1"),
                                  int(os.environ.get("LAYA_PORT", "0"))), Handler)
    server.daemon_threads = True
    port_file = os.environ.get("CLUX_FAKE_LAYA_PORT_FILE")
    if port_file:
        with open(port_file + ".tmp", "w", encoding="utf-8") as handle:
            handle.write("%d\n" % server.server_address[1])
        os.replace(port_file + ".tmp", port_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
