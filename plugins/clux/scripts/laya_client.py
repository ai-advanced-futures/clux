#!/usr/bin/env python3
"""laya_client.py: the only code of clux that speaks to Laya.

terminal.sh runs this file with the Python of the clux venv, or with
CLUX_LAYA_PYTHON. The server URL comes from CLUX_LAYA_URL and the API key
from CLUX_LAYA_KEY. The URL must use http and name a loopback host.

Subcommands that ask Laya (input on stdin, one result on stdout):

  health                          {"ok": true}
  command [--screen] [--no-safe-list]
                                  {"level": "safe|caution|dangerous", "reason": "..."}
                                  With --screen, the last input line is the
                                  command line, and the lines above it are the
                                  screen. --no-safe-list skips the safe list.
  output [--render] [--limit S]   {"text": "...", "held": [{"kind": "...", "lines": k}]}
                                  --render prints "held=<k>", then the text.
  pane                            {"state": "credential|yes_no|menu|pager|shell_prompt|other"}

Helpers that do not ask Laya: checkpoint, port, version,
pip-install SECONDS PACKAGE, scrub.

Exit codes: 0 a decision; 1 Laya is not available or gave a bad answer;
2 bad input. On a failure, stdout is empty and stderr has one fixed message.
The client never writes terminal text to stderr or to a log.
"""
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import warnings
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.realpath(__file__))
CONFIG = os.path.join(HERE, "..", "config", "laya")
LOOPBACK = ("127.0.0.1", "localhost", "::1")
REQUEST_LIMIT = 5.0
RETRY_DELAY = 1.0   # the Retry-After of the server, and the most that the client waits
GATE_LIMIT = 2 * REQUEST_LIMIT + RETRY_DELAY   # one request, the pause and the retry after a 503
MESSAGES = {1: "laya: not available", 2: "laya: bad input"}


class Fail(Exception):
    """End the client with exit code 1 or 2 and a fixed message."""

    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


class Exit(Exception):
    """End the client with this exit code and no message (the helpers)."""

    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


class Busy(Exception):
    """The server gave 503: too many requests at one time."""

    def __init__(self, delay):
        super().__init__()
        self.delay = delay


def retry_after(headers):
    """The Retry-After seconds of a 503, from 0 to RETRY_DELAY. RETRY_DELAY
    when the header is not there or is not a number of seconds."""
    try:
        delay = float(headers.get("Retry-After"))
    except (AttributeError, TypeError, ValueError):
        return RETRY_DELAY
    return min(max(delay, 0.0), RETRY_DELAY) if delay == delay else RETRY_DELAY


def read_stdin():
    return sys.stdin.buffer.read().decode("utf-8", "replace")


def config_home():
    return os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")


def policy(name):
    """Read config/laya/<name>.json. A user copy in
    $XDG_CONFIG_HOME/clux/laya/<name>.json replaces the shipped file."""
    user = os.path.join(config_home(), "clux", "laya", name + ".json")
    path = user if os.path.isfile(user) else os.path.join(CONFIG, name + ".json")
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        raise Fail(2)
    if not isinstance(value, dict) or not isinstance(value.get("schema"), dict):
        raise Fail(2)
    return value


def threshold(pol, name, default):
    try:
        return float(pol.get("thresholds", {}).get(name, default))
    except (AttributeError, TypeError, ValueError):
        raise Fail(2)


def shipped_lines(name):
    """The lines of a shipped .txt file, less blank lines and # comments.
    These files have no user copy."""
    try:
        with open(os.path.join(CONFIG, name), encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        raise Fail(2)
    return [line.strip() for line in lines if line.strip() and not line.strip().startswith("#")]


class Remote:
    """The runner that laya.structured.decide calls: one POST to laya-serve.

    LayaDecision is not used: it has no time limit for each request, and it
    does not keep the HTTP status. This runner uses no proxy, so terminal
    text cannot go to a proxy that the environment names.
    """

    def __init__(self, url, key, deadline):
        try:
            parts = urllib.parse.urlsplit(url)
            host = parts.hostname
        except ValueError:
            raise Fail(1)
        if parts.scheme != "http" or host not in LOOPBACK or parts.username or parts.password:
            raise Fail(1)
        self.url = url.rstrip("/")
        self.key = key
        self.deadline = deadline
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def limit(self):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise Fail(1)
        return min(REQUEST_LIMIT, left)

    def call(self, method, path, body=None):
        headers = {"Content-Type": "application/json"}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.limit()) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            if error.code == 503:
                raise Busy(retry_after(error.headers))
            raise Fail(1)
        except (OSError, ValueError, http.client.HTTPException):
            raise Fail(1)

    def health(self):
        return self.call("GET", "/health")

    def predict(self, state, questions, model=None):
        body = {"state": state, "questions": questions}
        if model:
            body["model"] = model
        try:
            result = self.call("POST", "/v1/systemone", body)
        except Busy as busy:
            # The server runs at most LAYA_MAX_CONCURRENT requests at one
            # time. Try one time more, after the Retry-After of the server.
            time.sleep(busy.delay)
            try:
                result = self.call("POST", "/v1/systemone", body)
            except Busy:
                raise Fail(1)
        if not isinstance(result, dict) or not isinstance(result.get("answers"), dict):
            raise Fail(1)
        return result


def remote(limit):
    """A runner for the server of this companion, with a total time limit."""
    return Remote(os.environ.get("CLUX_LAYA_URL", ""), os.environ.get("CLUX_LAYA_KEY", ""),
                  time.monotonic() + limit)


class Answer:
    """One DecisionResult of laya.structured.decide."""

    def __init__(self, result):
        self.result = result

    def p(self, name):
        """The probability of "true" for a boolean property."""
        try:
            value = float(self.result.probabilities[name]["true"])
        except (KeyError, TypeError, ValueError):
            raise Fail(1)
        if not 0.0 <= value <= 1.0:
            raise Fail(1)
        return value

    def choice(self, name, labels):
        value = self.result.values.get(name)
        if value not in labels:
            raise Fail(1)
        return value

    def tokens(self):
        try:
            return int((self.result.usage or {})["input_tokens"])
        except (KeyError, TypeError, ValueError):
            raise Fail(1)


def ask(runner, pol, state):
    """Send one state to Laya with the schema of a policy."""
    try:
        from laya.structured import SchemaError, decide
    except ImportError:
        raise Fail(1)
    try:
        return Answer(decide(runner, state, schema=pol["schema"], return_details=True,
                             model=pol.get("model") or "english"))
    except (Fail, Busy):
        raise
    except SchemaError:
        raise Fail(2)
    except Exception:
        raise Fail(1)


def cmd_health(args):
    if args:
        raise Fail(2)
    try:
        answer = remote(REQUEST_LIMIT).health()
    except Busy:
        raise Fail(1)
    if not isinstance(answer, dict) or answer.get("status") != "ok":
        raise Fail(1)
    print(json.dumps({"ok": True}))


UNSAFE = frozenset(";|&<>$`()\n\r")
BLOCKED_FIRST = ("sudo", "env", "xargs", "eval", "command", "builtin")
LEVELS = ("safe", "caution", "dangerous")


def on_safe_list(command):
    """True when the command skips Laya (spec section 7, Safe list)."""
    if any(char in UNSAFE for char in command):
        return False
    words = command.split()
    if not words or words[0] in BLOCKED_FIRST:
        return False
    for line in shipped_lines("safe-commands.txt"):
        entry = line.split()
        if words[:len(entry)] == entry:
            return True
    return False


def level_of(answer, pol):
    """dangerous: a boolean above its threshold, or risk dangerous.
    caution: risk caution. Otherwise safe. The reason names the highest
    boolean (the first one in the schema on a tie)."""
    names = [name for name, prop in pol["schema"]["properties"].items()
             if prop.get("type") == "boolean"]
    scores = [(answer.p(name), name) for name in names]
    risk = answer.choice("risk", LEVELS)
    top, top_name = max(scores, key=lambda score: score[0]) if scores else (0.0, "risk")
    reason = "%s %.2f" % (top_name, top)
    if risk == "dangerous" or any(p > threshold(pol, name, 0.8) for p, name in scores):
        return "dangerous", reason
    if risk == "caution":
        return "caution", reason
    return "safe", reason


def cmd_command(args):
    if any(arg not in ("--screen", "--no-safe-list") for arg in args):
        raise Fail(2)
    text = read_stdin()
    if "--screen" in args:
        lines = text.rstrip("\n").split("\n")
        command = lines[-1]
        state = {"line": command, "screen": "\n".join(lines[:-1])}
    else:
        command = text.rstrip("\n")
        state = command
    if not command.strip():
        raise Fail(2)
    if "--no-safe-list" not in args and on_safe_list(command):
        level, reason = "safe", "safe list"
    else:
        pol = policy("command")
        level, reason = level_of(ask(remote(GATE_LIMIT), pol, state), pol)
    print(json.dumps({"level": level, "reason": reason}))


PANE_STATES = ("credential", "yes_no", "menu", "pager", "shell_prompt", "other")


def cmd_pane(args):
    """The prompt type of the cursor line. Input: the cursor line and the 4
    lines above it. [inferred] An empty screen is "other" with no request."""
    if args:
        raise Fail(2)
    text = read_stdin().rstrip("\n")
    if not text.strip():
        state = "other"
    else:
        state = ask(remote(GATE_LIMIT), policy("pane"), text).choice("state", PANE_STATES)
    print(json.dumps({"state": state}))


BLOCK_CHARS = 600          # 300 tokens at 2 characters for each token (spec section 8)
CUT_TOKENS = 512           # the English checkpoint reads at most 512 tokens
MAX_PARALLEL = 16          # the same as LAYA_MAX_CONCURRENT
DEFAULT_OUTPUT_LIMIT = 15.0


class Unit:
    """One line of the text, or one piece of a long line. `line` is the index
    of the line in the text, and `start` the offset of the piece."""

    def __init__(self, line, start, text):
        self.line = line
        self.start = start
        self.text = text


def make_blocks(lines):
    """Split the lines into blocks of complete lines, at most BLOCK_CHARS
    characters each. A line longer than BLOCK_CHARS is cut into pieces, and
    each piece is a block of its own. [inferred] A block of only blank lines
    is not sent."""
    blocks, block, size = [], [], 0
    for index, line in enumerate(lines):
        if len(line) > BLOCK_CHARS:
            if block:
                blocks.append(block)
                block, size = [], 0
            for start in range(0, len(line), BLOCK_CHARS):
                blocks.append([Unit(index, start, line[start:start + BLOCK_CHARS])])
            continue
        if block and size + len(line) + 1 > BLOCK_CHARS:
            blocks.append(block)
            block, size = [], 0
        block.append(Unit(index, 0, line))
        size += len(line) + 1
    if block:
        blocks.append(block)
    return [block for block in blocks if any(unit.text.strip() for unit in block)]


def block_text(block):
    return "\n".join(unit.text for unit in block)


def halve(block):
    """Split a block that Laya cut in two. A block of one unit splits the
    text of that unit into two pieces."""
    if len(block) > 1:
        middle = len(block) // 2
        return [block[:middle], block[middle:]]
    unit = block[0]
    middle = len(unit.text) // 2
    if middle == 0:
        raise Fail(1)
    return [[Unit(unit.line, unit.start, unit.text[:middle])],
            [Unit(unit.line, unit.start + middle, unit.text[middle:])]]


def check_blocks(pool, runner, pol, blocks):
    """Send each block with the block policy. When usage.input_tokens is
    CUT_TOKENS or more, Laya cut the block: send its halves again. Give the
    list of (block, answer)."""
    done, pending = [], blocks
    while pending:
        answers = list(pool.map(lambda block: ask(runner, pol, block_text(block)), pending))
        again = []
        for block, answer in zip(pending, answers):
            if answer.tokens() >= CUT_TOKENS:
                again.extend(half for half in halve(block)
                             if any(unit.text.strip() for unit in half))
            else:
                done.append((block, answer))
        pending = again
    return done


def block_ranges(checked, pol):
    """Step 4 and the start of step 5: a block with prompt_injection above its
    threshold becomes one held range. The units of a block with secret above
    its threshold go to the line check. Give (ranges, flagged unit ids)."""
    ranges, flagged = [], set()
    for block, answer in checked:
        if answer.p("prompt_injection") > threshold(pol, "prompt_injection", 0.8):
            ranges.append((block[0].line, block[-1].line, "prompt_injection"))
        elif answer.p("secret") > threshold(pol, "secret", 0.5):
            flagged.update(id(unit) for unit in block)
    return ranges, flagged


def check_lines(pool, runner, pol, units, flagged, values):
    """Step 5, the line check. `units` are all units of the text in order.
    Each flagged unit goes to Laya alone and with the unit above it. Give the
    set of line indexes that the check holds.

    A unit is held when it alone is above the threshold, or when the pair is
    above the threshold and the unit above is not: not above the threshold
    alone, not held by this check, and not in `values` (the lines that
    secret-values.txt holds). [inferred] Without the last two conditions, the
    line after `hunter2` is held because of `hunter2`."""
    limit = threshold(pol, "secret", 0.75)
    targets, alone_ids, pairs = [], set(), []
    for position, unit in enumerate(units):
        if id(unit) not in flagged or not unit.text.strip():
            continue
        targets.append(position)
        alone_ids.add(position)
        if position > 0:
            above = units[position - 1]
            if above.text.strip() and above.line in (unit.line, unit.line - 1):
                alone_ids.add(position - 1)
                pairs.append(position)
    jobs = [("alone", position, units[position].text) for position in sorted(alone_ids)]
    jobs += [("pair", position, units[position - 1].text + "\n" + units[position].text)
             for position in pairs]
    scores = list(pool.map(lambda job: ask(runner, pol, job[2]).p("secret"), jobs))
    alone, pair = {}, {}
    for (kind, position, _text), score in zip(jobs, scores):
        (alone if kind == "alone" else pair)[position] = score
    held = set()
    for position in targets:
        line = units[position].line
        if alone[position] > limit:
            held.add(line)
        elif position in pair and pair[position] > limit:
            above = units[position - 1]
            if alone[position - 1] <= limit and above.line not in held and above.line not in values:
                held.add(line)
    return held


def render(lines, ranges):
    """Replace each held range with one marker line. Ranges that share a line
    become one range; it is prompt_injection when one part is. Give
    (lines, held)."""
    merged = []
    for first, last, kind in sorted(ranges):
        if merged and first <= merged[-1][1]:
            top = merged[-1]
            kind = "prompt_injection" if "prompt_injection" in (kind, top[2]) else "secret"
            merged[-1] = (top[0], max(top[1], last), kind)
        else:
            merged.append((first, last, kind))
    out, held, index = [], [], 0
    for first, last, kind in merged:
        out.extend(lines[index:first])
        count = last - first + 1
        if kind == "secret" and count == 1:
            out.append("[held by laya: secret]")
        else:
            out.append("[held by laya: %s, %d lines]" % (kind, count))
        held.append({"kind": kind, "lines": count})
        index = last + 1
    out.extend(lines[index:])
    return out, held


PEM_BEGIN = "-----BEGIN"
PEM_END = "-----END"


def compile_lines(name):
    try:
        return [re.compile(line) for line in shipped_lines(name)]
    except re.error:
        raise Fail(2)


def value_lines(lines, patterns):
    """Step 8: the lines that match secret-values.txt."""
    return {index for index, line in enumerate(lines) if any(p.search(line) for p in patterns)}


def never_secret(line, patterns):
    """not-secret.txt (spec section 15). An anchored pattern removes the hold
    with no other check. Any other pattern removes it only when the line has
    no =, : or @."""
    for pattern in patterns:
        if not pattern.search(line):
            continue
        if pattern.pattern.startswith("^") and pattern.pattern.endswith("$"):
            return True
        if not any(char in line for char in "=:@"):
            return True
    return False


def pem_ranges(lines):
    """Step 6: -----BEGIN to -----END is one held unit. [inferred] A BEGIN with
    no END holds to the end of the text, and the rule holds each range
    whatever Laya answers."""
    ranges, begin = [], None
    for index, line in enumerate(lines):
        if begin is None and PEM_BEGIN in line:
            begin = index
        if begin is not None and PEM_END in line:
            ranges.append((begin, index, "secret"))
            begin = None
    if begin is not None:
        ranges.append((begin, len(lines) - 1, "secret"))
    return ranges


def half_rule(checked, ranges):
    """Step 6: when more than half of the lines of a block are held (by any
    rule), the full block is held."""
    held = {line for first, last, _kind in ranges for line in range(first, last + 1)}
    result = []
    for block, _answer in checked:
        block_lines = sorted({unit.line for unit in block})
        if 2 * sum(1 for line in block_lines if line in held) > len(block_lines):
            result.append((block_lines[0], block_lines[-1], "secret"))
    return result


def guard(text, limit):
    """The output guard (spec section 8). Give (guarded text, held)."""
    if not text.strip():
        return text, []
    tail = "\n" if text.endswith("\n") else ""
    lines = (text[:-1] if tail else text).split("\n")
    block_pol, line_pol = policy("output-block"), policy("output-line")
    values = value_lines(lines, compile_lines("secret-values.txt"))
    shapes = compile_lines("not-secret.txt")
    runner = remote(limit)
    pool = ThreadPoolExecutor(max_workers=MAX_PARALLEL)
    try:
        checked = check_blocks(pool, runner, block_pol, make_blocks(lines))
        ranges, flagged = block_ranges(checked, block_pol)
        units = sorted((unit for block, _answer in checked for unit in block),
                       key=lambda unit: (unit.line, unit.start))
        held = check_lines(pool, runner, line_pol, units, flagged, values)
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    # not-secret.txt runs before the half rule counts, and it removes only
    # holds of the line check.
    held = {line for line in held if not never_secret(lines[line], shapes)}
    ranges += [(line, line, "secret") for line in sorted(held | values)]
    ranges += pem_ranges(lines)
    ranges += half_rule(checked, ranges)
    out, summary = render(lines, ranges)
    return "\n".join(out) + tail, summary


def cmd_output(args):
    render_mode, limit, rest = False, DEFAULT_OUTPUT_LIMIT, list(args)
    while rest:
        arg = rest.pop(0)
        if arg == "--render":
            render_mode = True
        elif arg == "--limit" and rest:
            try:
                limit = float(rest.pop(0))
            except ValueError:
                raise Fail(2)
            if limit <= 0:
                raise Fail(2)
        else:
            raise Fail(2)
    text, held = guard(read_stdin(), limit)
    if render_mode:
        sys.stdout.write("held=%d\n%s" % (sum(item["lines"] for item in held), text))
    else:
        print(json.dumps({"text": text, "held": held}))


def cmd_checkpoint(args):
    """Exit 0 when the English checkpoint is in the Hugging Face cache
    (HF_HUB_CACHE, else $HF_HOME/hub, else ~/.cache/huggingface/hub).
    open, laya install and laya status use this one check."""
    if args:
        raise Fail(2)
    try:
        from huggingface_hub import try_to_load_from_cache
    except ImportError:
        raise Exit(1)
    path = try_to_load_from_cache(repo_id="convaiinnovations/laya", filename="model.safetensors")
    if not isinstance(path, str) or not os.path.isfile(path):
        raise Exit(1)
    print(path)


def cmd_port(args):
    """A free TCP port on 127.0.0.1."""
    if args:
        raise Fail(2)
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        print(sock.getsockname()[1])


def cmd_version(args):
    """The installed laya version (laya status, laya install)."""
    if args:
        raise Fail(2)
    from importlib.metadata import PackageNotFoundError, version
    try:
        print(version("laya"))
    except PackageNotFoundError:
        raise Exit(1)


def cmd_pip_install(args):
    """pip-install SECONDS PACKAGE: pip in this Python with a time limit.
    Exit 124 when the time ends, else the pip exit code. The macOS base
    system has no timeout command. pip writes to the stdout and the stderr of
    the client, so the user sees the pip error."""
    import subprocess
    if len(args) != 2:
        raise Fail(2)
    try:
        seconds = float(args[0])
    except ValueError:
        raise Fail(2)
    if seconds <= 0:
        raise Exit(124)
    try:
        done = subprocess.run([sys.executable, "-m", "pip", "install",
                               "--disable-pip-version-check", args[1]], timeout=seconds)
    except subprocess.TimeoutExpired:
        raise Exit(124)
    raise Exit(done.returncode)


def cmd_scrub(args):
    """Copy stdin to stdout less each line that matches secret-values.txt."""
    if args:
        raise Fail(2)
    patterns = compile_lines("secret-values.txt")
    for line in read_stdin().splitlines():
        if not any(pattern.search(line) for pattern in patterns):
            print(line)


SUBCOMMANDS = {
    "health": cmd_health,
    "command": cmd_command,
    "pane": cmd_pane,
    "output": cmd_output,
    "checkpoint": cmd_checkpoint,
    "port": cmd_port,
    "version": cmd_version,
    "pip-install": cmd_pip_install,
    "scrub": cmd_scrub,
}


def main(argv):
    if not argv or argv[0] not in SUBCOMMANDS:
        raise Fail(2)
    SUBCOMMANDS[argv[0]](argv[1:])


def run(argv):
    warnings.simplefilter("ignore")
    message = None
    try:
        main(argv)
        code = 0
    except Exit as done:
        code = done.code
    except Fail as error:
        code, message = error.code, MESSAGES.get(error.code, MESSAGES[1])
    except BaseException:
        code, message = 1, MESSAGES[1]
    try:
        sys.stdout.flush()
    except BaseException:
        code, message = 1, MESSAGES[1]
    if message:
        try:
            sys.stderr.write(message + "\n")
            sys.stderr.flush()
        except BaseException:
            pass
    # os._exit: the threads of a pool that passed its time limit must not
    # keep the process alive.
    os._exit(code)


if __name__ == "__main__":
    run(sys.argv[1:])
