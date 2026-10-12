#!/usr/bin/env python3
"""clef_client.py: the only code of clux that speaks to Clef.

terminal.sh runs this file with python3, or with CLUX_CLEF_PYTHON. The
server URL comes from CLUX_CLEF_URL and the API key from CLUX_CLEF_KEY. The
URL must use http and name a loopback host or a Tailscale host. The client
makes its own plan from each policy schema and sends one POST to the
server; it imports no model package.

Subcommands that ask Clef (input on stdin, one result on stdout):

  health                          {"ok": true}
  command [--screen] [--shell]
                                  {"level": "safe|caution|dangerous", "reason": "..."}
                                  With --screen, the last input line is the
                                  command line, and the lines above it are the
                                  screen. Each command goes to Clef.
                                  --shell (with --screen): the line is at the
                                  prompt of a nested shell, and it comes as two
                                  input lines: the start of the line (the
                                  prompt), then the text that clux typed. Clef
                                  gets them as one line. Typed text that can
                                  change that shell is dangerous.
  output [--render] [--limit S] [--pieces BYTES] [--runs 0,I,...]
                                  {"text": "...", "held": [{"kind": "...", "lines": k}]}
                                  --render prints "held=<k>" (with " not_examined=<m>"
                                  when the time limit left <m> lines not examined),
                                  then the text.
                                  --pieces: guard pieces of whole lines of at most
                                  BYTES each, with one time limit for all.
                                  --runs: the first line of each run of lines
                                  that are next to each other; the PEM rule
                                  does not cross from one run to the next.
  pane [--limit S]                {"state": "credential|yes_no|menu|pager|shell_prompt|other"}
                                  --limit: a time limit shorter than the gate limit.

Helpers that do not ask Clef: check-url, after-cursor.

Exit codes: 0 a decision; 1 Clef is not available or gave a bad answer;
2 bad input; 3 the state is too long for Clef to examine; 4 the server
refused the API key (401 or 403). On a failure, stdout is empty and stderr has one fixed message.
The client never writes terminal text to stderr or to a log.
"""
import http.client
import ipaddress
import json
import math
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import warnings

HERE = os.path.dirname(os.path.realpath(__file__))
CONFIG = os.path.join(HERE, "..", "config", "clef")
LOOPBACK = ("127.0.0.1", "localhost", "::1")
REQUEST_LIMIT = 15.0
RETRY_DELAY = 1.0   # the Retry-After of a proxy, and the most that the client waits
# Its own constant (spec section 5): one request can wait for a request of
# another companion, so the gate does not add the retry to the request limit.
GATE_LIMIT = 15.0
MESSAGES = {1: "clef: not available", 2: "clef: bad input", 3: "clef: too long to examine",
            4: "clef: the server refused the API key"}


# The HTTP error codes of the Clef server, and the exit code that each one
# means to the client. The one table for all requests. 503 is not here:
# predict tries one time more, and a second 503 is a late request (Fail
# late=True), which the guard holds. 413: the state is longer than the
# context of the model, and each request sends "truncate": false, so the
# server says so instead of cutting the state. Each other code is an error
# of the server with its own message, and the client exits 1, so the verb
# fails closed (spec section 5).
HTTP_ERRORS = {401: 4, 403: 4, 413: 3}


class Fail(Exception):
    """End the client with this exit code. With message (the default),
    stderr gets the fixed message of the code; the helpers end with none.
    A message text replaces the fixed message.
    late: one request reached REQUEST_LIMIT, or the server had a queue two
    times (503); the guard holds only that text as not examined."""

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
    """Read config/clef/<name>.json. There is no user copy, so a user file
    cannot turn off the gate or the guard with a threshold of 2. This is a
    defense in depth only: a command that Clef passed can write any file of
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


def finite(value):
    """VALUE as a finite number, else Fail(2). nan makes each comparison
    false (a threshold of nan holds nothing), and inf is no time limit."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise Fail(2)
    if not math.isfinite(number):
        raise Fail(2)
    return number


def time_limit(value):
    """VALUE of a --limit option: a finite number of seconds above 0."""
    limit = finite(value)
    if limit <= 0:
        raise Fail(2)
    return limit


def threshold(pol, name, default):
    try:
        return finite(pol.get("thresholds", {}).get(name, default))
    except AttributeError:
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


TAILSCALE_NETS = (ipaddress.ip_network("100.64.0.0/10"),
                  ipaddress.ip_network("fd7a:115c:a1e0::/48"))
TAILNET_SUFFIX = ".ts.net"
HOST_MESSAGE = "clef: the host of CLUX_CLEF_URL is not a loopback or Tailscale host"
# The addresses of each name that this process resolved: one lookup for each
# name, so a second lookup cannot give another address.
RESOLVED = {}


def lookup(name):
    """The addresses of NAME. The one lookup of the client: no environment
    variable and no option changes it, and a test replaces this function."""
    return [info[4][0] for info in socket.getaddrinfo(name, None, type=socket.SOCK_STREAM)]


def is_tailscale(address):
    """ADDRESS is in the Tailscale ranges. A zone (fe80::1%en0) is not."""
    try:
        value = ipaddress.ip_address(address.split("%")[0])
    except ValueError:
        return False
    return any(value in net for net in TAILSCALE_NETS)


def host_kind(url):
    """(kind, address) for a URL that the client may use: ("loopback", host)
    or ("tailscale", address). None for each other URL, so terminal text does
    not go out of the tailnet. The URL must use http and have no user part."""
    try:
        parts = urllib.parse.urlsplit(url)
        host = parts.hostname
        parts.port     # a port that is not a number raises ValueError here
    except ValueError:
        return None
    if parts.scheme != "http" or not host or parts.username or parts.password:
        return None
    if host in LOOPBACK:
        return "loopback", host
    if is_tailscale(host):
        return "tailscale", host
    if not host.endswith(TAILNET_SUFFIX):
        return None
    if host not in RESOLVED:
        try:
            addresses = lookup(host)
        except OSError:
            addresses = []
        RESOLVED[host] = addresses if addresses and all(is_tailscale(a) for a in addresses) else None
    return ("tailscale", RESOLVED[host][0]) if RESOLVED[host] else None


def connect_url(url, address):
    """(request URL, Host header) for URL with ADDRESS in place of its host.
    The client connects to the address that host_kind checked, so the lookup
    function is on the connect path, and the server still sees the name."""
    parts = urllib.parse.urlsplit(url)
    literal = "[%s]" % address if ":" in address else address
    netloc = literal + (":%d" % parts.port if parts.port else "")
    return urllib.parse.urlunsplit(("http", netloc, parts.path, "", "")).rstrip("/"), parts.netloc


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse each redirect: a redirect would send the key (Authorization) and
    the terminal text to the host of Location, which can be remote. The
    answer stays an HTTPError, so the client exits 1."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Remote:
    """The runner of one companion: each request goes to one POST to the
    Clef server. This runner uses no proxy, so terminal text cannot go to a
    proxy that the environment names."""

    def __init__(self, url, key, deadline):
        kind = host_kind(url)
        if kind is None:
            raise Fail(1, message=HOST_MESSAGE)
        self.url, self.host = connect_url(url, kind[1])
        self.key = key
        self.deadline = deadline
        self.last = 0.0
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def limit(self):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise Fail(1)
        return min(REQUEST_LIMIT, left)

    def call(self, method, path, body=None):
        headers = {"Content-Type": "application/json", "Host": self.host}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
        start = time.monotonic()
        try:
            with self.opener.open(request, timeout=self.limit()) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            if error.code == 503:
                raise Busy(retry_after(error.headers))
            if error.code in HTTP_ERRORS:
                raise Fail(HTTP_ERRORS[error.code])
            raise Fail(1, message="clef: the server gave error %d" % error.code)
        except TimeoutError:
            raise Fail(1, late=True)
        except urllib.error.URLError as error:
            raise Fail(1, late=isinstance(error.reason, TimeoutError))
        except (OSError, ValueError, http.client.HTTPException):
            raise Fail(1)
        finally:
            self.last = time.monotonic() - start

    def health(self):
        # The key goes to health too: clux does not own the port now.
        return self.call("GET", "/health")

    def predict(self, state, questions):
        body = {"state": state, "questions": questions, "truncate": False}
        try:
            result = self.call("POST", "/v1/systemone", body)
        except Busy as busy:
            # Try one time more, after the Retry-After of a proxy.
            time.sleep(busy.delay)
            try:
                result = self.call("POST", "/v1/systemone", body)
            except Busy:
                raise Fail(1, late=True)
        if not isinstance(result, dict) or not isinstance(result.get("answers"), dict):
            raise Fail(1)
        return result


def remote(limit):
    """A runner for the server of this companion, with a total time limit."""
    return Remote(os.environ.get("CLUX_CLEF_URL", ""), os.environ.get("CLUX_CLEF_KEY", ""),
                  time.monotonic() + limit)


def questions_of(pol):
    """The Clef questions of a policy schema (spec section 5): a boolean
    property is a noul question, an enum is a choice question with one
    criterion for each value, and the description is the instruction. Each
    other property type is bad input. The client makes this plan itself, so
    it imports no model package."""
    properties = pol.get("schema", {}).get("properties")
    if not isinstance(properties, dict) or not properties:
        raise Fail(2)
    questions = {}
    for name, prop in properties.items():
        if not isinstance(prop, dict) or not isinstance(prop.get("description"), str):
            raise Fail(2)
        if prop.get("type") == "boolean":
            questions[name] = {"type": "noul", "instructions": prop["description"]}
        elif isinstance(prop.get("enum"), list) and prop["enum"]:
            questions[name] = {"type": "choice", "instructions": prop["description"],
                               "criteria": {value: None for value in prop["enum"]}}
        else:
            raise Fail(2)
    return questions


class Answer:
    """The answers of one POST /v1/systemone."""

    def __init__(self, result):
        self.result = result
        self.answers = result.get("answers") or {}

    def p(self, name):
        """The noul probability of a boolean question."""
        try:
            value = float(self.answers[name]["noul"])
        except (KeyError, TypeError, ValueError):
            raise Fail(1)
        if not 0.0 <= value <= 1.0:
            raise Fail(1)
        return value

    def choice(self, name, labels):
        try:
            value = self.answers[name]["choice"]
        except (KeyError, TypeError):
            raise Fail(1)
        if value not in labels:
            raise Fail(1)
        return value


def ask(runner, pol, state):
    """Send one state to Clef with the questions of a policy."""
    return Answer(runner.predict(state, questions_of(pol)))


def cmd_health(args):
    if args:
        raise Fail(2)
    try:
        answer = remote(REQUEST_LIMIT).health()
    except Busy:
        raise Fail(1)
    if not isinstance(answer, dict):
        raise Fail(1)
    print(json.dumps({"ok": True}))


LEVELS = ("safe", "caution", "dangerous")


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
# only the Clef score stops that. It reads only the text that clux typed,
# not the prompt (a directory named source in the prompt is not a word).
# Each name that __clux_carry in terminal.sh does not carry back from run,
# and PATH and the loader names (a test keeps the two lists equal); names
# that change where later commands read or write files; the zsh prompts
# (with prompt_subst they run $(...) at each prompt) and zsh hook arrays.
# A name is set with no NAME= too: for NAME in, select NAME, getopts X NAME
# and read NAME (the words below).
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
    r"|umask|ulimit|fc|select|getopts|sched|vared|zparseopts|emulate|disable|functions"
    r"|local|private|integer|float)"
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
    # for and the zsh foreach set each name after them (zsh takes more
    # than one name: for a PATH in x).
    r"|(^|[^A-Za-z0-9_.-])(for|foreach)\s+([A-Za-z_][A-Za-z0-9_]*\s+)*(" + SHELL_NAMES
    + r"|prompt|psvar|path|fpath|cdpath|manpath|module_path|mailpath)(?![A-Za-z0-9_])"
    # A default in an expansion assigns too: ${PROMPT_COMMAND:=x}.
    r"|\$\{(" + SHELL_NAMES + r"):?[=]"
    # The zsh arrays that PATH, FPATH and CDPATH follow, and the zsh prompt
    # (the same as PS1), as a word of their own (not --module-path=).
    r"|(^|[\s;&|(){}`])(path|fpath|cdpath|manpath|module_path|mailpath|prompt|psvar)\+?="
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
        # to Clef with the screen above it.
        if not command.strip() and not screen.strip():
            raise Fail(2)
    else:
        command = text.rstrip("\n")
        state = command
        if not command.strip():
            raise Fail(2)
    # The shell rule needs no request: a line that it refuses is refused
    # also when Clef is slow or does not answer.
    if shell and SHELL_WORDS.search(typed):
        print(json.dumps({"level": "dangerous", "reason": "can change the shell for later commands"}))
        return
    # Each command goes to Clef: no safe list (spec section 7). A command
    # that is longer than the context of Clef gives 413, which is exit 3.
    pol = policy("command")
    answer = ask(remote(GATE_LIMIT), pol, state)
    level, reason = level_of(answer, pol)
    print(json.dumps({"level": level, "reason": reason}))


PANE_STATES = ("credential", "yes_no", "menu", "pager", "shell_prompt", "other")
PANE_CURSOR = 400          # the end of the cursor line that goes to Clef
PANE_ABOVE = 200           # the end of each line above it


def cmd_pane(args):
    """The prompt type of the cursor line. Input: the cursor line and the 4
    lines above it. [inferred] An empty screen is "other" with no request.
    --limit S: a shorter time limit than GATE_LIMIT (the time that is left
    before the deadline of a wait)."""
    limit = GATE_LIMIT
    if args:
        if len(args) != 2 or args[0] != "--limit":
            raise Fail(2)
        limit = min(GATE_LIMIT, time_limit(args[1]))
    text = read_stdin()
    if not text.strip():
        print(json.dumps({"state": "other"}))
        return
    # Clef reads the end of the state last, and the prompt is at the end of
    # the cursor line. Each line keeps only its end: PANE_CURSOR characters
    # of the cursor line and PANE_ABOVE of each line above it.
    (cursor,), above = split_screen(text, PANE_CURSOR, PANE_ABOVE)
    answer = ask(remote(limit), policy("pane"), "\n".join(above + [cursor]))
    print(json.dumps({"state": answer.choice("state", PANE_STATES)}))


BLOCK_CHARS = 2000         # the block of the guard (spec section 8, step 1)
PIECE_OVERLAP = 100        # the text that two pieces of one long line share
LINE_QUESTIONS = 10        # the line questions of one request (spec section 8, step 3)
LINE_COST = 0.35           # the time that each line question adds (spec section 8, step 4)
DEFAULT_OUTPUT_LIMIT = 45.0


class Unit:
    """One line of the text, or one piece of a long line. `line` is the index
    of the line in the text, and `start` the offset of the piece."""

    def __init__(self, line, start, text):
        self.line = line
        self.start = start
        self.text = text


def make_blocks(lines):
    """Split the lines into blocks of complete lines, at most BLOCK_CHARS
    characters each (spec section 8, step 1). A line longer than BLOCK_CHARS
    is cut into pieces, and each piece is a block of its own. Two pieces
    share PIECE_OVERLAP characters, so a token of up to that length is whole
    in one piece (a held piece holds its full line). [inferred] A block of
    only blank lines is not sent.

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


TIME_MARGIN = 0.05         # a failure this near the end of the time limit is the limit


def in_time(runner, request):
    """Run one request of the guard. Give None when the time limit of the
    guard ended, or this one request reached REQUEST_LIMIT (a queue on the
    server), before Clef answered: the caller holds that text as not
    examined. Any other failure (Clef does not answer) stops the guard."""
    try:
        return request()
    except Fail as fail:
        if fail.code == 1 and (fail.late or time.monotonic() >= runner.deadline - TIME_MARGIN):
            return None
        raise


# The client sends one request at a time (spec section 5): the Clef server
# runs one request at a time, and a second request of this client would only
# make the request of another companion wait longer.
def check_blocks(runner, pol, blocks):
    """Step 2: one request for each block, one at a time, the bottom blocks
    first (the newest lines). Give the list of (block, answer, seconds) and
    the list of blocks that the time limit left not examined. The seconds of
    a block are the cost of one request on this block: step 4 reads them."""
    done, late = [], []
    for block in blocks[::-1]:
        answer = in_time(runner, lambda: ask(runner, pol, block_text(block)))
        if answer is None:
            late.append(block)
        else:
            done.append((block, answer, runner.last))
    return done, late


def block_ranges(checked, pol):
    """Step 2: a block with prompt_injection above its threshold is one held
    range. Give (ranges, flagged): flagged are the blocks that the line
    search reads, each with the seconds that its block check took."""
    ranges, flagged = [], []
    for block, answer, seconds in checked:
        if answer.p("prompt_injection") > threshold(pol, "prompt_injection", 0.8):
            ranges.append((block[0].line, block[-1].line, "prompt_injection"))
        elif answer.p("secret") > threshold(pol, "secret", 0.5):
            flagged.append((block, seconds))
    return ranges, flagged


def line_text(pol):
    """The question text of the line search: the description of the secret
    property of output-line.json. search_lines puts the line number in it."""
    prop = (pol.get("schema", {}).get("properties") or {}).get("secret")
    if not isinstance(prop, dict) or not isinstance(prop.get("description"), str) \
            or "the text" not in prop["description"]:
        raise Fail(2)
    return prop["description"]


def search_lines(runner, pol, block, skip, limit, seconds):
    """Step 3, the line search of one block. The state is the full block,
    each line with its number from 1, so the block gives each line its
    context: there is no pair rule. One request asks for at most
    LINE_QUESTIONS lines, so it stays near 8 s and a request of another
    companion does not wait too long (spec section 7). SKIP are the numbers
    that get no question. Give the held line indexes, or None when the time
    that is left is less than the estimated cost of the search (the number
    of requests times the time of the block check of this block, plus
    LINE_COST for each line question), or when one request got no answer:
    the caller holds the full block (spec section 8, step 4)."""
    numbers = [index + 1 for index in range(len(block)) if index + 1 not in skip]
    if not numbers:
        return set()
    requests = -(-len(numbers) // LINE_QUESTIONS)
    if runner.deadline - time.monotonic() < requests * seconds + LINE_COST * len(numbers):
        return None
    state = "\n".join("%d: %s" % (index + 1, unit.text) for index, unit in enumerate(block))
    text = line_text(pol)
    held = set()
    for start in range(0, len(numbers), LINE_QUESTIONS):
        part = numbers[start:start + LINE_QUESTIONS]
        questions = {"line%d" % number:
                     {"type": "noul", "instructions": text.replace("the text", "line %d" % number)}
                     for number in part}
        answer = in_time(runner, lambda: Answer(runner.predict(state, questions)))
        if answer is None:
            return None
        for number in part:
            if answer.p("line%d" % number) > limit:
                held.add(block[number - 1].line)
    return held


def check_lines(runner, pol, lines, flagged, values, cleared):
    """Step 3 for each flagged block. A block that is one piece of a line
    longer than BLOCK_CHARS gets no line search: the full line is held. A
    line that secret-values.txt holds, a line that not-secret.txt clears and
    a blank line get no question. Give (held lines, full ranges): the full
    ranges are the blocks that the search did not finish and the long lines
    of the pieces."""
    limit = threshold(pol, "secret", 0.75)
    held, full = set(), []
    for block, seconds in flagged:
        if len(lines[block[0].line]) > BLOCK_CHARS:
            full.append((block[0].line, block[0].line, "secret"))
            continue
        skip = {index + 1 for index, unit in enumerate(block)
                if not unit.text.strip() or unit.line in values or unit.line in cleared}
        found = search_lines(runner, pol, block, skip, limit, seconds)
        if found is None:
            full.append((block[0].line, block[-1].line, "secret"))
        else:
            held |= found
    return held, full


def merge(ranges, order):
    """Ranges that share a line become one range, of the first kind in
    ORDER that one part has."""
    merged = []
    for first, last, kind in sorted(ranges):
        if merged and first <= merged[-1][1]:
            top = merged[-1]
            kind = next(k for k in order if k in (kind, top[2]))
            merged[-1] = (top[0], max(top[1], last), kind)
        else:
            merged.append((first, last, kind))
    return merged


def render(lines, ranges):
    """Replace each held range with one marker line. Give (lines, held).

    A secret or a prompt_injection wins over not_examined: its lines are
    held, and a retry (wait --run again) must not give them back. So the
    held ranges merge first (prompt_injection wins when one part is), and a
    not_examined range keeps only the lines that no held range covers. Those
    lines are really not examined, and they keep the retry."""
    held_ranges = merge([r for r in ranges if r[2] != "not_examined"], ("prompt_injection", "secret"))
    covered = {line for first, last, _kind in held_ranges for line in range(first, last + 1)}
    late = []
    for first, last, kind in ranges:
        if kind != "not_examined":
            continue
        start = None
        for line in range(first, last + 2):
            if line <= last and line not in covered:
                start = line if start is None else start
            elif start is not None:
                late.append((start, line - 1, "not_examined"))
                start = None
    merged = sorted(held_ranges + merge(late, ("not_examined",)))
    out, held, index = [], [], 0
    for first, last, kind in merged:
        out.extend(lines[index:first])
        count = last - first + 1
        if kind == "secret" and count == 1:
            out.append("[held by clef: secret]")
        else:
            out.append("[held by clef: %s, %d lines]" % (kind, count))
        held.append({"kind": kind, "lines": count})
        index = last + 1
    out.extend(lines[index:])
    return out, held


# Each BEGIN or END marker of a line, in order.
PEM_MARKER = re.compile(r"-----(BEGIN|END)")
# The END line of a private key. Only such a line holds the lines above it
# when the text has no BEGIN: a certificate or "-----END OF REPORT-----" does not.
PEM_KEY_END = re.compile(r"-----END [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----")
# The BEGIN line of a private key. Only such a line holds to the end of the
# text when no END comes: a certificate with no END does not.
PEM_KEY_BEGIN = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----")


def compile_lines(name):
    try:
        return [re.compile(line) for line in shipped_lines(name)]
    except re.error:
        raise Fail(2)


def value_lines(lines, patterns):
    """Step 8: the lines that match secret-values.txt, or the BEGIN line of
    a private key (PEM_KEY_BEGIN, the one pattern for that line)."""
    return {index for index, line in enumerate(lines)
            if PEM_KEY_BEGIN.search(line) or any(p.search(line) for p in patterns)}


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
    """Step 6: -----BEGIN to -----END is one held unit. [inferred] The BEGIN
    line of a private key with no END holds to the end of the text; another
    BEGIN with no END (a certificate) holds nothing, and Clef examines it.
    The END line of a private key with no BEGIN holds from the line after
    the END before it (or from the first line). This applies to all text,
    not only to cut text: tail, grep -A or sed -n on a key file give the
    end of a key with no BEGIN. Round 7 limited it to cut text so that a
    lone -----END OF REPORT----- held no output; the END side must now name
    PRIVATE KEY, so that case holds nothing. The rule holds each range
    whatever Clef answers. A line can hold more than one marker (cat of a
    file with no newline at its end gives -----END CERTIFICATE----------BEGIN
    RSA PRIVATE KEY-----), so the markers of a line count in their order."""
    ranges, begin, key, start = [], None, None, 0
    for index, line in enumerate(lines):
        for marker in PEM_MARKER.finditer(line):
            if marker.group(1) == "BEGIN":
                if begin is None:
                    begin = index
                if key is None and PEM_KEY_BEGIN.match(line, marker.start()):
                    key = index
                continue
            if begin is not None:
                ranges.append((begin, index, "secret"))
            elif PEM_KEY_END.match(line, marker.start()):
                ranges.append((start, index, "secret"))
            begin, key, start = None, None, index + 1
    if key is not None:
        ranges.append((key, len(lines) - 1, "secret"))
    return ranges


def half_rule(checked, ranges):
    """Step 6: when more than half of the lines of a block are held (by any
    rule), the full block is held. A line that is not examined is not held:
    it must keep its retry, so it does not count here."""
    held = {line for first, last, kind in ranges if kind != "not_examined"
            for line in range(first, last + 1)}
    result = []
    for block, _answer, _seconds in checked:
        block_lines = sorted({unit.line for unit in block})
        if 2 * sum(1 for line in block_lines if line in held) > len(block_lines):
            result.append((block_lines[0], block_lines[-1], "secret"))
    return result


def guard_lines(lines, pem, runner, setup):
    """The output guard of one piece (spec section 8). setup holds the
    policies and the patterns, which guard reads one time. pem holds the
    ranges of pem_ranges in this piece. Give (guarded lines, held). A block
    is never held as not_examined after its block check gave secret (spec
    section 8, step 4)."""
    if not any(line.strip() for line in lines):
        return lines, []
    block_pol, line_pol, value_patterns, shapes = setup
    values = value_lines(lines, value_patterns)
    checked, late_blocks = check_blocks(runner, block_pol, make_blocks(lines))
    ranges, flagged = block_ranges(checked, block_pol)
    # not-secret.txt runs before the half rule counts, and it removes only
    # the holds of the line search.
    cleared = {index for index, line in enumerate(lines) if never_secret(line, shapes)}
    held, full = check_lines(runner, line_pol, lines, flagged, values, cleared)
    ranges += [(line, line, "secret") for line in sorted(held | values)]
    ranges += full
    # Text that the time limit left not examined is held (spec section 8).
    ranges += [(block[0].line, block[-1].line, "not_examined") for block in late_blocks]
    ranges += pem
    ranges += half_rule(checked, ranges)
    return render(lines, ranges)


def guard(text, limit, size=0, runs=(0,)):
    """The output guard (spec section 8). Give (guarded text, held).

    With SIZE, the text goes in pieces of whole lines, each at most SIZE
    bytes (one line that is longer is a piece of its own), so a guard of
    one piece never starts inside a line (wait --pattern). All pieces share
    one time limit and one read of the policies. The bottom piece goes
    first, as the bottom blocks do in check_blocks. The PEM rule runs on the
    full text, not in each piece, because a key can go over the edge of a
    piece; each piece gets its part of the ranges.

    RUNS are the first lines of the runs of lines that are next to each
    other in the source (wait --pattern sends the new lines of a screen,
    which come from more than one place). The PEM rule runs in each run and
    never crosses the gap to the run above."""
    if not text.strip():
        return text, []
    tail = "\n" if text.endswith("\n") else ""
    lines = (text[:-1] if tail else text).split("\n")
    parts, part, used = [], [], 0
    for line in lines if size else ():
        count = len(line.encode("utf-8")) + 1
        if part and used + count > size:
            parts.append(part)
            part, used = [], 0
        part.append(line)
        used += count
    parts.append(part if size else lines)
    pem = []
    edges = [start for start in runs if start < len(lines)] + [len(lines)]
    for start, end in zip(edges, edges[1:]):
        pem += [(first + start, last + start, kind)
                for first, last, kind in pem_ranges(lines[start:end])]
    starts, offset = [], 0
    for part in parts:
        starts.append(offset)
        offset += len(part)
    setup = (policy("output-block"), policy("output-line"),
             compile_lines("secret-values.txt"), compile_lines("not-secret.txt"))
    runner = remote(limit)
    results = [None] * len(parts)
    for index in reversed(range(len(parts))):
        first, last = starts[index], starts[index] + len(parts[index]) - 1
        own = [(max(start, first) - first, min(end, last) - first, kind)
               for start, end, kind in pem if start <= last and end >= first]
        results[index] = guard_lines(parts[index], own, runner, setup)
    return ("\n".join(line for result in results for line in result[0]) + tail,
            [item for result in results for item in result[1]])


def parse_runs(value):
    """--runs 0,4,9: the first line of each run, from 0, going up."""
    if not re.fullmatch(r"0(,[1-9][0-9]*)*", value):
        raise Fail(2)
    runs = [int(start) for start in value.split(",")]
    if any(b <= a for a, b in zip(runs, runs[1:])):
        raise Fail(2)
    return runs


def cmd_output(args):
    render_mode, limit, size, runs, rest = False, DEFAULT_OUTPUT_LIMIT, 0, (0,), list(args)
    while rest:
        arg = rest.pop(0)
        if arg == "--render":
            render_mode = True
        elif arg == "--pieces" and rest and rest[0].isdigit() and int(rest[0]) > 0:
            size = int(rest.pop(0))
        elif arg == "--runs" and rest:
            runs = parse_runs(rest.pop(0))
        elif arg == "--limit" and rest:
            limit = time_limit(rest.pop(0))
        else:
            raise Fail(2)
    text, held = guard(read_stdin(), limit, size, runs)
    if render_mode:
        # not_examined=N only when the time limit left lines not examined:
        # the caller can then try again, which it must not do for a secret.
        late = sum(item["lines"] for item in held if item["kind"] == "not_examined")
        sys.stdout.write("held=%d%s\n%s" % (sum(item["lines"] for item in held),
                                             " not_examined=%d" % late if late else "", text))
    else:
        print(json.dumps({"text": text, "held": held}))


def cmd_check_url(args):
    """check-url URL: print the kind of the host of a URL that the client may
    use (loopback or tailscale), else exit 1. open and clef status read it."""
    if len(args) != 1:
        raise Fail(2)
    kind = host_kind(args[0])
    if kind is None:
        raise Fail(1, message=False)
    print(kind[0])


def cells(text):
    """The screen cells of text, never fewer than tmux gives (spec section
    7): too few would let text go in the middle of the line with no gate;
    too many only refuses the send. 2 for a wide character, 0 for a
    combining character, else 1. A variation selector (U+FE00 to U+FE0F) is
    0, but VS16 (U+FE0F) after a narrow character is 1: tmux 3.4 and later
    show that character wide. tmux 3.4 and later also join an emoji and its
    skin tone, and a ZWJ sequence, in 2 cells, and give 0 to a format
    character (U+200B); older versions do not. So these keep their full
    count, and a row with one of them after the cursor can be refused. A
    code point that this Python does not know (category Cn, for example an
    emoji newer than its Unicode data) is 2: tmux 3.7b shows U+1FAE9 in 2
    cells, and 2 is never too few. A private use character is 1, as in tmux."""
    import unicodedata
    count, last = 0, 0
    for char in text:
        if "\ufe00" <= char <= "\ufe0f":
            count += 1 if char == "\ufe0f" and last == 1 else 0
            last = 2 if char == "\ufe0f" and last == 1 else last
            continue
        if unicodedata.combining(char):
            continue
        last = 2 if unicodedata.east_asian_width(char) in ("W", "F") \
            or unicodedata.category(char) == "Cn" else 1
        count += last
    return count


def cmd_after_cursor(args):
    """after-cursor X < ROW: print "mid" when the row has text that is not a
    space at cell X or after it, else "end". tmux gives cursor_x in cells.
    A word, not an exit code: a failure must not read as "end"."""
    if len(args) != 1 or not args[0].isdigit():
        raise Fail(2)
    row = read_stdin().rstrip("\n").rstrip()
    print("end" if cells(row) <= int(args[0]) else "mid")


SUBCOMMANDS = {
    "health": cmd_health,
    "command": cmd_command,
    "pane": cmd_pane,
    "output": cmd_output,
    "check-url": cmd_check_url,
    "after-cursor": cmd_after_cursor,
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
        if isinstance(error.message, str):
            message = error.message
        elif error.message:
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
