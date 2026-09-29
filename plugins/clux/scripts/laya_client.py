#!/usr/bin/env python3
"""laya_client.py: the only code of clux that speaks to Laya.

terminal.sh runs this file with the Python of the clux venv, or with
CLUX_LAYA_PYTHON. The server URL comes from CLUX_LAYA_URL and the API key
from CLUX_LAYA_KEY. The URL must use http and name a loopback host.

Subcommands that ask Laya (input on stdin, one result on stdout):

  health                          {"ok": true}
  command [--screen] [--shell]
                                  {"level": "safe|caution|dangerous", "reason": "..."}
                                  With --screen, the last input line is the
                                  command line, and the lines above it are the
                                  screen. Each command goes to Laya.
                                  --shell (with --screen): the line is at the
                                  prompt of a nested shell, and it comes as two
                                  input lines: the start of the line (the
                                  prompt), then the text that clux typed. Laya
                                  gets them as one line. Typed text that can
                                  change that shell is dangerous.
  output [--render] [--cut] [--limit S]
                                  {"text": "...", "held": [{"kind": "...", "lines": k}]}
                                  --render prints "held=<k>", then the text.
                                  --cut: the text can start inside a key.
  pane                            {"state": "credential|yes_no|menu|pager|shell_prompt|other"}

Helpers that do not ask Laya: checkpoint, ready, port, version,
pip-install SECONDS PACKAGE, scrub.

Exit codes: 0 a decision; 1 Laya is not available or gave a bad answer;
2 bad input; 3 the text is too long: Laya would examine only its start; 4 the
server refused the API key (401 or 403). On a failure, stdout is empty and stderr has one fixed message.
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
MESSAGES = {1: "laya: not available", 2: "laya: bad input", 3: "laya: too long to examine",
            4: "laya: the server refused the API key"}


class Fail(Exception):
    """End the client with this exit code. With message (the default),
    stderr gets the fixed message of the code; the helpers end with none.
    late: one request reached REQUEST_LIMIT (the server is slow or has a
    queue); the guard holds only that text as not examined."""

    def __init__(self, code, message=True, late=False):
        Exception.__init__(self, code)
        self.code = code
        self.message = message
        self.late = late


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


def policy(name):
    """Read config/laya/<name>.json. There is no user copy, so a user file
    cannot turn off the gate or the guard with a threshold of 2. This is a
    defense in depth only: a command that Laya passed can write any file of
    the user, also these files, the venv and the state file. Spec section 7
    ("The limit of the private directory") puts that out of scope."""
    path = os.path.join(CONFIG, name + ".json")
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


def url_is_loopback(url):
    """http, a loopback host and no user part. terminal.sh uses this check
    too (check-url), so the two cannot disagree."""
    try:
        parts = urllib.parse.urlsplit(url)
        host = parts.hostname
    except ValueError:
        return False
    return (parts.scheme == "http" and host in LOOPBACK
            and not parts.username and not parts.password)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse each redirect: a redirect would send the key (Authorization) and
    the terminal text to the host of Location, which can be remote. The
    answer stays an HTTPError, so the client exits 1."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Remote:
    """The runner that laya.structured.decide calls: one POST to laya-serve.

    LayaDecision is not used: it has no time limit for each request, and it
    does not keep the HTTP status. This runner uses no proxy, so terminal
    text cannot go to a proxy that the environment names.
    """

    def __init__(self, url, key, deadline):
        if not url_is_loopback(url):
            raise Fail(1)
        self.url = url.rstrip("/")
        self.key = key
        self.deadline = deadline
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def limit(self):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise Fail(1)
        return min(REQUEST_LIMIT, left)

    def call(self, method, path, body=None, key=True):
        headers = {"Content-Type": "application/json"}
        if key and self.key:
            headers["Authorization"] = "Bearer " + self.key
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.limit()) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            if error.code == 503:
                raise Busy(retry_after(error.headers))
            if error.code in (401, 403):
                raise Fail(4)
            raise Fail(1)
        except TimeoutError:
            raise Fail(1, late=True)
        except urllib.error.URLError as error:
            raise Fail(1, late=isinstance(error.reason, TimeoutError))
        except (OSError, ValueError, http.client.HTTPException):
            raise Fail(1)

    def health(self):
        # /health of laya-serve needs no key. Before open knows that its own
        # process listens on the port, the key must not go to that port.
        return self.call("GET", "/health", key=False)

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


LEVELS = ("safe", "caution", "dangerous")


def ask_whole_or_alone(runner, pol, whole, *shorter):
    """Ask with the whole state. When Laya cuts it, ask again with each
    shorter state in turn (the line alone, then less of it). A state that
    Laya still cuts is refused (exit 3): Laya would examine only its start."""
    answer = ask(runner, pol, whole)
    for state in shorter:
        if not is_cut(answer, pol):
            break
        answer = ask(runner, pol, state)
    if is_cut(answer, pol):
        raise Fail(3)
    return answer


def split_screen(text, cursor_keep, above_keep, rows=1):
    """Split the input of command --screen and pane. Only the last newline
    goes: a blank last line stays a line. Returns the last ROWS lines, each
    with only its last CURSOR_KEEP characters (all when None), and the
    lines above them, each with only its last ABOVE_KEEP characters."""
    text = text[:-1] if text.endswith("\n") else text
    lines = text.split("\n")
    if len(lines) < rows:
        raise Fail(2)
    last = lines[len(lines) - rows:]
    if cursor_keep is not None:
        last = [line[-cursor_keep:] for line in last]
    return last, [line[-above_keep:] for line in lines[:len(lines) - rows]]


def level_of(answer, pol):
    """dangerous: a boolean above its threshold, or risk dangerous.
    caution: risk caution. Otherwise safe. The reason names the highest
    boolean (the first one in the schema on a tie), or "risk dangerous" when
    only the risk choice gives dangerous."""
    names = [name for name, prop in pol["schema"]["properties"].items()
             if prop.get("type") == "boolean"]
    scores = [(answer.p(name), name) for name in names]
    risk = answer.choice("risk", LEVELS)
    top, top_name = max(scores, key=lambda score: score[0]) if scores else (0.0, "risk")
    reason = "%s %.2f" % (top_name, top)
    if any(p > threshold(pol, name, 0.8) for p, name in scores):
        return "dangerous", reason
    if risk == "dangerous":
        # No boolean is above its threshold: a boolean score would tell the
        # user that the command is not a risk.
        return "dangerous", "risk dangerous"
    if risk == "caution":
        return "caution", reason
    return "safe", reason


# At the clux prompt a line runs in a subshell (__clux_line in terminal.sh),
# so it cannot change the pane shell. At the prompt of a nested shell (bash
# in the pane) a line runs in that shell, and it can change that shell for
# later lines (spec section 7). The gate examines each line alone, so such
# a line is dangerous. The rule reads the words anywhere in the line, also
# inside quotes. It is not complete: quotes can split a word (e""val), and
# only the Laya score stops that. It reads only the text that clux typed,
# not the prompt (a directory named source in the prompt is not a word).
# Each name that __clux_carry in terminal.sh does not carry back from run,
# and PATH and the loader names (a test keeps the two lists equal); names
# that change where later commands read or write files; the zsh prompts
# (with prompt_subst they run $(...) at each prompt) and zsh hook arrays.
SHELL_NAMES = (
    r"PATH|FPATH|PROMPT_COMMAND|BASH[A-Z_]*|ENV|PS[0-4]|IFS|SHELLOPTS"
    r"|POSIXLY_CORRECT|CDPATH|GLOBIGNORE|HISTFILE|HISTCMD|TMOUT|IGNOREEOF|SHLVL|PWD"
    r"|OLDPWD|MAIL|MAILPATH|MAILCHECK|FUNCNEST|LD_[A-Z_]*|DYLD_[A-Z_]*"
    r"|HOME|TMPDIR|INPUTRC|ZDOTDIR"
    r"|PROMPT[234]?|RPROMPT2?|RPS[12]|SPROMPT"
    r"|(precmd|preexec|chpwd|periodic|zshaddhistory|zshexit)_functions")
SHELL_WORDS = re.compile(
    r"\(\s*\)"
    r"|(^|[^A-Za-z0-9_.-])(eval|source|trap|bind|enable|alias|unalias|typeset|declare"
    r"|export|readonly|set|shopt|unset|function|builtin|command|hash|exec|read|mapfile"
    r"|readarray|exit|logout|complete|compgen|bindkey|setopt|unsetopt|zle|autoload|zmodload"
    r"|umask|ulimit|fc)"
    r"(?![A-Za-z0-9_-])"
    r"|(^|[^A-Za-z0-9_.-])printf\s+(-\S+\s+)*-v"
    # . and the zsh r (run a history line again) at the start of a command,
    # also after assignments (X=1 . f) and with a backslash (\. f).
    r"|(^|[;&|(){}`!]|(^|\s)(then|do|else|elif|if|while|until|time|coproc))"
    r"\s*([A-Za-z_][A-Za-z0-9_]*=\S*\s+)*\\?(\.\s|r(\s|$))"
    # History expansion (!!, !rm, !?x?, !-2) and ^old^new run an earlier line.
    r"|!(?![\s=(]|$)|^\s*\^"
    r"|[A-Za-z_][A-Za-z0-9_]*\[[^]]*\]\+?="
    r"|(^|[^A-Za-z0-9_])(" + SHELL_NAMES + r")\+?="
    # A default in an expansion assigns too: ${PROMPT_COMMAND:=x}.
    r"|\$\{(" + SHELL_NAMES + r"):?[=]"
    # The zsh arrays that PATH, FPATH and CDPATH follow, as a word of their
    # own (not --module-path=).
    r"|(^|[\s;&|(){}`])(path|fpath|cdpath)\+?="
    r"|<<")


def cmd_command(args):
    if any(arg not in ("--screen", "--shell") for arg in args):
        raise Fail(2)
    shell = "--shell" in args
    if shell and "--screen" not in args:
        raise Fail(2)
    text = read_stdin()
    typed = None
    if "--screen" in args:
        # The screen is only context: each line keeps its end, as in pane.
        last, above = split_screen(text, None, PANE_ABOVE, 2 if shell else 1)
        if shell:
            typed = last[1]
        command = "".join(last)
        screen = "\n".join(above)
        state = {"line": command, "screen": screen}
        # A blank line in a program can accept a default ([Y/n]), so it goes
        # to Laya with the screen above it.
        if not command.strip() and not screen.strip():
            raise Fail(2)
    else:
        command = text.rstrip("\n")
        state = command
        if not command.strip():
            raise Fail(2)
    # The shell rule needs no request: a line that it refuses is refused
    # also when Laya is slow or does not answer.
    if shell and SHELL_WORDS.search(typed):
        print(json.dumps({"level": "dangerous", "reason": "can change the shell for later commands"}))
        return
    # Each command goes to Laya: no safe list (spec section 7). Laya cuts a
    # long state and examines only its start, so a cut state is refused.
    # When Laya cuts the line and the screen, the line goes alone: a long
    # screen must not stop a short line. A blank line needs its screen.
    shorter = []
    if isinstance(state, dict) and state["screen"] and command.strip():
        shorter.append({"line": command, "screen": ""})
    pol = policy("command")
    answer = ask_whole_or_alone(remote(GATE_LIMIT), pol, state, *shorter)
    level, reason = level_of(answer, pol)
    print(json.dumps({"level": level, "reason": reason}))


PANE_STATES = ("credential", "yes_no", "menu", "pager", "shell_prompt", "other")
PANE_CURSOR = 400          # the end of the cursor line that goes to Laya
PANE_ABOVE = 200           # the end of each line above it
PANE_SHORT = 100           # the end of the cursor line when Laya cuts PANE_CURSOR
PAIR_ABOVE = 200           # the end of the line above in a pair of the line check


def cmd_pane(args):
    """The prompt type of the cursor line. Input: the cursor line and the 4
    lines above it. [inferred] An empty screen is "other" with no request."""
    if args:
        raise Fail(2)
    text = read_stdin()
    if not text.strip():
        print(json.dumps({"state": "other"}))
        return
    # Laya cuts a long state from the right, and the prompt is at the end of
    # the cursor line. Thus each line keeps only its end: PANE_CURSOR
    # characters of the cursor line and PANE_ABOVE of each line above it.
    # When Laya still cuts the text, the cursor line goes alone, then only
    # its last PANE_SHORT characters.
    (cursor,), above = split_screen(text, PANE_CURSOR, PANE_ABOVE)
    shorter = [cursor] if above else []
    if len(cursor) > PANE_SHORT:
        shorter.append(cursor[-PANE_SHORT:])
    answer = ask_whole_or_alone(remote(GATE_LIMIT), policy("pane"),
                                "\n".join(above + [cursor]), *shorter)
    print(json.dumps({"state": answer.choice("state", PANE_STATES)}))


BLOCK_CHARS = 600          # 300 tokens at 2 characters for each token (spec section 8)
PIECE_OVERLAP = 100        # the text that two pieces of one long line share
CUT_TOKENS = 512           # the English checkpoint reads at most 512 tokens for each row
ROW_MARGIN = 16            # measured: the two output-block rows differ by 9 tokens
# laya-serve 0.3.21 runs one model request at a time (one worker thread), and
# REQUEST_LIMIT counts the time in its queue. Two requests at one time keep
# the server busy, and a request waits at most for one other request.
MAX_PARALLEL = 2
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
    each piece is a block of its own. Two pieces share PIECE_OVERLAP
    characters, so a token of up to that length is whole in one piece (a
    held piece holds its full line). [inferred] A block of only blank lines
    is not sent.

    The blocks start at the last line and go up. Each cut of the text
    (read --lines, --max-lines, the byte cut) keeps the end, so a line keeps
    the same block when the cut changes; only the top block changes. A top
    block under half of BLOCK_CHARS joins the block below it."""
    blocks, block, size = [], [], 0
    for index in range(len(lines) - 1, -1, -1):
        line = lines[index]
        if len(line) > BLOCK_CHARS:
            if block:
                blocks.append(block)
                block, size = [], 0
            step = BLOCK_CHARS - PIECE_OVERLAP
            starts = [start for start in range(0, len(line), step)
                      if start == 0 or start + PIECE_OVERLAP < len(line)]
            for start in reversed(starts):
                blocks.append([Unit(index, start, line[start:start + BLOCK_CHARS])])
            continue
        if block and size + len(line) + 1 > BLOCK_CHARS:
            blocks.append(block)
            block, size = [], 0
        block.insert(0, Unit(index, 0, line))
        size += len(line) + 1
    if block:
        below = blocks[-1] if blocks else None
        if size < BLOCK_CHARS // 2 and below and all(len(lines[unit.line]) <= BLOCK_CHARS for unit in below):
            blocks[-1] = block + below
        else:
            blocks.append(block)
    blocks.reverse()
    return [block for block in blocks if any(unit.text.strip() for unit in block)]


def block_text(block):
    return "\n".join(unit.text for unit in block)


def halve(block):
    """Split a block that Laya cut in two. A block of one unit splits the
    text of that unit into two pieces that share up to PIECE_OVERLAP
    characters at the middle."""
    if len(block) > 1:
        middle = len(block) // 2
        return [block[:middle], block[middle:]]
    unit = block[0]
    middle = len(unit.text) // 2
    if middle == 0:
        raise Fail(1)
    share = min(PIECE_OVERLAP // 2, middle // 2)
    return [[Unit(unit.line, unit.start, unit.text[:middle + share])],
            [Unit(unit.line, unit.start + middle - share, unit.text[middle - share:])]]


def is_cut(answer, pol):
    """laya-serve gives usage.input_tokens as the sum over the question rows
    (one row for each question of the policy), and it cuts each row at
    CUT_TOKENS. When the mean row is within ROW_MARGIN of CUT_TOKENS, the
    longest row can be cut."""
    rows = max(1, len(pol["schema"]["properties"]))
    return answer.tokens() / rows >= CUT_TOKENS - ROW_MARGIN


TIME_MARGIN = 0.05         # a failure this near the end of the time limit is the limit


def in_time(runner, request):
    """Run one request of the guard. Give None when the time limit of the
    guard ended, or this one request reached REQUEST_LIMIT (a queue on the
    server), before Laya answered: the caller holds that text as not
    examined. Any other failure (Laya does not answer) stops the guard."""
    try:
        return request()
    except Fail as fail:
        if fail.code == 1 and (fail.late or time.monotonic() >= runner.deadline - TIME_MARGIN):
            return None
        raise


def check_blocks(pool, runner, pol, blocks):
    """Send each block with the block policy. laya-serve gives
    usage.input_tokens as the sum over the question rows (one row for each
    boolean question of this policy), and it cuts each row at CUT_TOKENS.
    When the mean row is within ROW_MARGIN of CUT_TOKENS, the longest row
    can be cut: send the halves of the block again. Give the list of
    (block, answer) and the list of blocks that the time limit left not
    examined."""
    done, late, pending = [], [], blocks
    while pending:
        answers = list(pool.map(
            lambda block: in_time(runner, lambda: ask(runner, pol, block_text(block))), pending))
        again = []
        for block, answer in zip(pending, answers):
            if answer is None:
                late.append(block)
            elif is_cut(answer, pol):
                again.extend(half for half in halve(block)
                             if any(unit.text.strip() for unit in half))
            else:
                done.append((block, answer))
        pending = again
    return done, late


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


def check_lines(pool, runner, pol, units, flagged, values, cleared=frozenset()):
    """Step 5, the line check. `units` are all units of the text in order.
    Each flagged unit goes to Laya alone, and with the unit above it when
    the alone score does not decide. Give the set of line indexes that the
    check holds.

    A unit is held when it alone is above the threshold, or when the pair is
    above the threshold and the unit above is not: not above the threshold
    alone, not held by this check, and not in `values` (the lines that
    secret-values.txt holds). [inferred] Without the last two conditions, the
    line after `hunter2` is held because of `hunter2`. The unit above is held
    when it alone is above the threshold, also when its own block was not
    flagged. `cleared` are the lines that not-secret.txt clears: the check
    never holds them and sends no request for them, and the pair rule reads
    such a line above as not held. A line in `values` is held whatever Laya
    answers, so it gets no request either.

    Phase 1 sends the alone requests, phase 2 only the pairs that can change
    the result. A pair has only the end of the unit above (PAIR_ABOVE), so
    that Laya does not cut the unit below. A request that Laya cuts holds
    its unit: Laya did not examine all of it. Give (held, late): late are
    the lines that the time limit left not examined."""
    limit = threshold(pol, "secret", 0.75)

    def above_of(position):
        if position == 0:
            return None
        above, unit = units[position - 1], units[position]
        if above.text.strip() and above.line in (unit.line, unit.line - 1):
            return above
        return None

    def score(text):
        answer = in_time(runner, lambda: ask(runner, pol, text))
        if answer is None:
            return None
        return 1.0 if is_cut(answer, pol) else answer.p("secret")

    targets = [position for position, unit in enumerate(units)
               if id(unit) in flagged and unit.text.strip() and unit.line not in cleared
               and unit.line not in values]
    alone_ids = set(targets)
    for position in targets:
        above = above_of(position)
        if above is not None and above.line not in cleared and above.line not in values:
            alone_ids.add(position - 1)
    order = sorted(alone_ids)
    alone = dict(zip(order, pool.map(lambda position: score(units[position].text), order)))
    # A unit above that its block check passed and that got no alone answer
    # in time stays shown: then only the pair rule can hold the unit below.
    late = {units[position].line for position, value in alone.items()
            if value is None and position in targets}
    held = set()
    for position in targets:
        if alone[position] is not None and alone[position] > limit:
            held.add(units[position].line)
        if (position - 1 in alone and above_of(position) is not None
                and alone[position - 1] is not None and alone[position - 1] > limit):
            held.add(units[position - 1].line)
    pairs = []
    for position in targets:
        above = above_of(position)
        if units[position].line in held | late or above is None:
            continue
        if above.line in held or above.line in values:
            continue
        pairs.append(position)
    texts = [units[position - 1].text[-PAIR_ABOVE:] + "\n" + units[position].text for position in pairs]
    # In line order: a line that its pair holds stops the pair of the line
    # below it.
    for position, value in zip(pairs, list(pool.map(score, texts))):
        if value is None:
            late.add(units[position].line)
        elif value > limit and units[position - 1].line not in held:
            held.add(units[position].line)
    return held, late - held


def render(lines, ranges):
    """Replace each held range with one marker line. Ranges that share a line
    become one range; it is prompt_injection when one part is, else
    not_examined when one part is. Give (lines, held)."""
    merged = []
    for first, last, kind in sorted(ranges):
        if merged and first <= merged[-1][1]:
            top = merged[-1]
            kind = next(k for k in ("prompt_injection", "not_examined", "secret") if k in (kind, top[2]))
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
# The END line of a private key. Only such a line holds the lines above it
# when the text has no BEGIN: a certificate or "-----END OF REPORT-----" does not.
PEM_KEY_END = re.compile(r"-----END [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----")


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


def pem_ranges(lines, cut=False):
    """Step 6: -----BEGIN to -----END is one held unit. [inferred] A BEGIN with
    no END holds to the end of the text. When the text is cut (it can start
    inside a key), the END line of a private key with no BEGIN holds from
    the first line. The rule holds each range whatever Laya answers."""
    ranges, begin, seen = [], None, False
    for index, line in enumerate(lines):
        if begin is None and PEM_BEGIN in line:
            begin = index
        if PEM_END in line:
            if begin is not None:
                ranges.append((begin, index, "secret"))
            elif not seen and cut and PEM_KEY_END.search(line):
                ranges.append((0, index, "secret"))
            begin, seen = None, True
        elif begin is not None:
            seen = True
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


def guard(text, limit, cut=False):
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
        checked, late_blocks = check_blocks(pool, runner, block_pol, make_blocks(lines))
        ranges, flagged = block_ranges(checked, block_pol)
        units = sorted((unit for block, _answer in checked for unit in block),
                       key=lambda unit: (unit.line, unit.start))
        # not-secret.txt runs before the pair rule and before the half rule
        # counts, and it removes only holds of the line check.
        cleared = {index for index, line in enumerate(lines) if never_secret(line, shapes)}
        held, late = check_lines(pool, runner, line_pol, units, flagged, values, cleared)
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    ranges += [(line, line, "secret") for line in sorted(held | values)]
    # Text that the time limit left not examined is held (spec section 8).
    ranges += [(block[0].line, block[-1].line, "not_examined") for block in late_blocks]
    ranges += [(line, line, "not_examined") for line in sorted(late - values)]
    ranges += pem_ranges(lines, cut)
    ranges += half_rule(checked, ranges)
    out, summary = render(lines, ranges)
    return "\n".join(out) + tail, summary


def cmd_output(args):
    render_mode, cut, limit, rest = False, False, DEFAULT_OUTPUT_LIMIT, list(args)
    while rest:
        arg = rest.pop(0)
        if arg == "--render":
            render_mode = True
        elif arg == "--cut":
            cut = True
        elif arg == "--limit" and rest:
            try:
                limit = float(rest.pop(0))
            except ValueError:
                raise Fail(2)
            if limit <= 0:
                raise Fail(2)
        else:
            raise Fail(2)
    text, held = guard(read_stdin(), limit, cut)
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
        raise Fail(1, message=False)
    path = try_to_load_from_cache(repo_id="convaiinnovations/laya", filename="model.safetensors")
    if not isinstance(path, str) or not os.path.isfile(path):
        raise Fail(1, message=False)
    print(path)


def cmd_ready(args):
    """Exit 0 when this Python can import laya and the English checkpoint is
    in the Hugging Face cache: the install check of open in one process."""
    if args:
        raise Fail(2)
    try:
        import laya.structured  # noqa: F401
    except ImportError:
        raise Fail(1, message=False)
    cmd_checkpoint([])


def cmd_port(args):
    """A free TCP port on 127.0.0.1."""
    if args:
        raise Fail(2)
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        print(sock.getsockname()[1])


def cmd_check_url(args):
    """Exit 0 when the URL is http on a loopback host with no user part."""
    if len(args) != 1:
        raise Fail(2)
    if not url_is_loopback(args[0]):
        raise Fail(1, message=False)


def cells(text):
    """The screen cells of text: 2 for a wide character, 0 for a
    combining character, else 1."""
    import unicodedata
    count = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        count += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return count


def cmd_after_cursor(args):
    """after-cursor X < ROW: print "mid" when the row has text that is not a
    space at cell X or after it, else "end". tmux gives cursor_x in cells.
    A word, not an exit code: a failure must not read as "end"."""
    if len(args) != 1 or not args[0].isdigit():
        raise Fail(2)
    row = read_stdin().rstrip("\n").rstrip()
    print("end" if cells(row) <= int(args[0]) else "mid")


def cmd_version(args):
    """The installed laya version (laya status, laya install)."""
    if args:
        raise Fail(2)
    from importlib.metadata import PackageNotFoundError, version
    try:
        print(version("laya"))
    except PackageNotFoundError:
        raise Fail(1, message=False)


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
        raise Fail(124, message=False)
    try:
        done = subprocess.run([sys.executable, "-m", "pip", "install",
                               "--disable-pip-version-check", args[1]], timeout=seconds)
    except subprocess.TimeoutExpired:
        raise Fail(124, message=False)
    raise Fail(done.returncode, message=False)


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
    "ready": cmd_ready,
    "port": cmd_port,
    "check-url": cmd_check_url,
    "after-cursor": cmd_after_cursor,
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
    except Fail as error:
        code = error.code
        if error.message:
            message = MESSAGES.get(error.code, MESSAGES[1])
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
