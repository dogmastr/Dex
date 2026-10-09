#!/usr/bin/env python3
"""OpenDex MCP relay.

Sits between an AI client that speaks MCP (Claude Code, VS Code) and OpenDex running in a Roblox game:

    editor --MCP over HTTP--> this relay <--WebSocket, opened by the game-- OpenDex

The game can only connect out, never listen, so something outside the game has to be the MCP server.
This is that program: no AI, no state, nothing to install (Python 3.9 or newer, standard library only).
Run it once and leave it open:

    python opendex_mcp.py [--port 38211] [--token TOKEN]

The tools are listed in tools.json, next to this file. It speaks both MCP eras: the handshake of the
2025 revisions (initialize) and the stateless 2026-07-28 revision (every request carries its version).
"""
import argparse
import asyncio
import base64
import hashlib
import hmac
import itertools
import json
import os
import secrets
import struct
import sys
import time
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERSION = "1.0"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"  # fixed by the WebSocket standard (RFC 6455)
MODERN = ["2026-07-28"]
LEGACY = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
SERVER_INFO = {"name": "opendex", "title": "OpenDex", "version": VERSION}
META_VERSION = "io.modelcontextprotocol/protocolVersion"
META_SERVER = "io.modelcontextprotocol/serverInfo"
MAX_BODY = 4 * 1024 * 1024
MAX_WS = 16 * 1024 * 1024
LOOPBACK = ("127.0.0.1", "localhost", "[::1]")
NO_GAME = ("OpenDex is not connected to the relay. In the game, open OpenDex's AI window, "
           "paste the token there and switch on \"Connect to the relay\".")
# What each editor wants (the URL, then the token) and where it goes. The AI window's Copy button
# (modules/Agent.lua) and README.md give the same texts.
EDITORS = [
    ("Claude Code", "VS Code's terminal, or any", 'claude mcp add --scope user --transport http opendex %s --header "Authorization: Bearer %s"'),
    ("VS Code's own agent", ".vscode/mcp.json", '{"servers": {"opendex": {"type": "http", "url": "%s", "headers": {"Authorization": "Bearer %s"}}}}'),
    ("Codex", "the end of ~/.codex/config.toml", '[mcp_servers.opendex]\nurl = "%s"\nhttp_headers = { "Authorization" = "Bearer %s" }'),
    ("Cursor", "~/.cursor/mcp.json", '{"mcpServers": {"opendex": {"url": "%s", "headers": {"Authorization": "Bearer %s"}}}}'),
    ("Antigravity", "~/.gemini/config/mcp_config.json", '{"mcpServers": {"opendex": {"serverUrl": "%s", "headers": {"Authorization": "Bearer %s"}}}}'),
    ("opencode", "~/.config/opencode/opencode.json", '{"mcp": {"opendex": {"type": "remote", "url": "%s", "oauth": false, "headers": {"Authorization": "Bearer %s"}}}}'),
]

REASONS = {200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
           404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"}

_spec = json.loads((HERE / "tools.json").read_text(encoding="utf-8"))
INSTRUCTIONS = _spec["instructions"]
TOOLS = {t["name"]: t for t in _spec["tools"]}
TOOL_LIST = [{
    "name": t["name"],
    "description": t["description"],
    "inputSchema": t["inputSchema"],
    "annotations": {"readOnlyHint": bool(t.get("readOnly")), "destructiveHint": bool(t.get("destructive")),
                    "openWorldHint": bool(t.get("openWorld"))},
} for t in _spec["tools"]]

TOKEN = ""
PORT = 38211
state = {"game": None}  # the one connection from OpenDex
pending = {}            # call id -> (future, the game it was sent to)
call_ids = itertools.count(1)


def log(text):
    print(time.strftime("%H:%M:%S ") + text, flush=True)


# ------------------------------------------------------------------------------------------------
# WebSocket (RFC 6455), just what a client that sends and receives text needs
# ------------------------------------------------------------------------------------------------

def unmask(data, mask):
    n = len(data)
    if n == 0:
        return data
    key = (mask * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big")


def ws_frame(opcode, payload):
    n = len(payload)
    if n < 126:
        head = struct.pack(">BB", 0x80 | opcode, n)
    elif n < 65536:
        head = struct.pack(">BBH", 0x80 | opcode, 126, n)
    else:
        head = struct.pack(">BBQ", 0x80 | opcode, 127, n)
    return head + payload


async def ws_read(reader, writer):
    """The next text or binary message. Pings are answered here; a close frame raises ConnectionError."""
    parts, total = [], 0
    while True:
        head = await reader.readexactly(2)
        fin, opcode, n = head[0] & 0x80, head[0] & 0x0F, head[1] & 0x7F
        if n == 126:
            (n,) = struct.unpack(">H", await reader.readexactly(2))
        elif n == 127:
            (n,) = struct.unpack(">Q", await reader.readexactly(8))
        if n > MAX_WS:
            raise ConnectionError("message too large")
        mask = await reader.readexactly(4) if head[1] & 0x80 else None
        data = await reader.readexactly(n)
        if mask:
            data = unmask(data, mask)
        if opcode == 8:
            raise ConnectionError("closed by OpenDex")
        if opcode == 9:
            writer.write(ws_frame(10, data))
            await writer.drain()
            continue
        if opcode == 10:
            continue
        if opcode in (1, 2):
            parts, total = [data], len(data)
        elif opcode == 0:
            parts.append(data)
            total += len(data)
        else:
            continue
        if total > MAX_WS:
            raise ConnectionError("message too large")
        if fin:
            return b"".join(parts)


class Game:
    """The connection from OpenDex."""

    def __init__(self, reader, writer, hello):
        self.reader, self.writer, self.hello = reader, writer, hello
        self.lock = asyncio.Lock()
        self.closed = False

    async def send(self, obj):
        data = ws_frame(1, json.dumps(obj, separators=(",", ":")).encode("utf-8"))
        async with self.lock:
            self.writer.write(data)
            await self.writer.drain()

    async def close(self, reason=""):
        if self.closed:
            return
        self.closed = True
        try:
            async with self.lock:
                self.writer.write(ws_frame(8, struct.pack(">H", 1000) + reason.encode("utf-8")[:100]))
                await self.writer.drain()
        except Exception:
            pass
        try:
            self.writer.close()
        except Exception:
            pass


class GameError(Exception):
    pass


async def call_game(tool, args, timeout):
    game = state["game"]
    if game is None:
        raise GameError(NO_GAME)
    cid = next(call_ids)
    future = asyncio.get_running_loop().create_future()
    pending[cid] = (future, game)
    try:
        await game.send({"type": "call", "id": cid, "tool": tool, "args": args})
        return await asyncio.wait_for(future, timeout)
    except asyncio.TimeoutError:
        raise GameError("OpenDex did not answer within %d seconds (the game may be busy or paused)." % timeout)
    except (ConnectionError, OSError):
        raise GameError("OpenDex disconnected while the call was running.")
    finally:
        pending.pop(cid, None)


async def game_session(reader, writer, headers):
    key = headers.get("sec-websocket-key")
    if headers.get("upgrade", "").lower() != "websocket" or not key:
        writer.write(http_response(400, b"expected a WebSocket upgrade", ctype="text/plain"))
        await writer.drain()
        return
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest())
    writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                 b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")
    await writer.drain()

    # the first message has to be the hello, with the token
    hello = None
    try:
        hello = json.loads((await asyncio.wait_for(ws_read(reader, writer), 10)).decode("utf-8"))
    except Exception:
        pass
    ok = isinstance(hello, dict) and hello.get("type") == "hello" and hmac.compare_digest(
        str(hello.get("token", "")).encode("utf-8"), TOKEN.encode("utf-8"))
    refused = Game(reader, writer, hello)
    if not ok:
        try:
            await refused.send({"type": "error", "message": "The relay refused the token"})
        except Exception:
            pass
        await refused.close("bad token")
        log("a connection to /game was refused (no hello, or the wrong token)")
        return

    game = refused
    old, state["game"] = state["game"], game
    if old is not None:
        # The older one is told why, so that it stops: two that each connect again would push each other
        # off for ever (two Roblox clients on one executor both have the switch on).
        try:
            await asyncio.wait_for(old.send({"type": "replaced"}), 5)
        except Exception:
            pass
        await old.close("replaced by a newer OpenDex")
    log("OpenDex connected (%s, OpenDex %s, place %s)" % (hello.get("executor", "?"), hello.get("version", "?"), hello.get("place", "?")))
    try:
        await game.send({"type": "welcome", "relay": VERSION})
        while True:
            message = json.loads((await ws_read(reader, writer)).decode("utf-8"))
            kind = message.get("type") if isinstance(message, dict) else None
            if kind == "result":
                entry = pending.get(message.get("id"))
                if entry and entry[0] is not None and not entry[0].done():
                    entry[0].set_result(message)
            elif kind == "ping":
                await game.send({"type": "pong"})
    except (asyncio.IncompleteReadError, ConnectionError, OSError, ValueError):
        pass
    finally:
        if state["game"] is game:
            state["game"] = None
        game.closed = True
        for future, owner in list(pending.values()):
            if owner is game and not future.done():
                future.set_exception(ConnectionError("OpenDex disconnected"))
        log("OpenDex disconnected")
        try:
            writer.close()
        except Exception:
            pass


# ------------------------------------------------------------------------------------------------
# MCP: JSON-RPC over one HTTP endpoint
# ------------------------------------------------------------------------------------------------

def rpc_result(mid, result):
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def rpc_error(mid, code, message, data=None):
    error = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": mid, "error": error}


TYPES = {"string": str, "integer": int, "number": (int, float), "boolean": bool, "array": list, "object": dict}


def check_value(value, schema, path):
    kind = schema.get("type")
    if kind:
        wrong = isinstance(value, bool) and kind in ("integer", "number")
        if wrong or not isinstance(value, TYPES[kind]) or (kind == "integer" and isinstance(value, float) and not value.is_integer()):
            return "%s must be %s" % (path, "an integer" if kind == "integer" else "a " + kind)
    if "enum" in schema and value not in schema["enum"]:
        return "%s must be one of %s" % (path, ", ".join(map(str, schema["enum"])))
    if kind == "object":
        return check_object(value, schema, path)
    if kind == "array" and "items" in schema:
        for i, item in enumerate(value):
            problem = check_value(item, schema["items"], "%s[%d]" % (path, i + 1))
            if problem:
                return problem
    return None


def check_object(args, schema, path):
    props = schema.get("properties", {})
    for name in schema.get("required", []):
        if name not in args:
            return "%s is missing" % (path + "." + name if path else name)
    for name, value in args.items():
        if name not in props:
            if schema.get("additionalProperties") is False:
                return "unknown argument %s" % (path + "." + name if path else name)
            continue
        problem = check_value(value, props[name], path + "." + name if path else name)
        if problem:
            return problem
    return None


def text_result(text, is_error):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


async def tool_call(params):
    name, args = params.get("name"), params.get("arguments")
    spec = TOOLS.get(name) if isinstance(name, str) else None  # (a list or an object cannot be looked up at all)
    if spec is None:
        raise RpcError(-32602, "Unknown tool: %s" % name)
    if args is None:
        args = {}
    if not isinstance(args, dict):
        raise RpcError(-32602, "arguments must be an object")
    problem = check_object(args, spec["inputSchema"], "")
    if problem:
        return text_result("Invalid arguments: " + problem, True)
    started = time.time()
    try:
        reply = await call_game(name, args, spec.get("timeout", 60))
    except GameError as error:
        log("%s: %s" % (name, error))
        return text_result(str(error), True)
    took = int((time.time() - started) * 1000)
    if reply.get("ok"):
        result = reply.get("result")
        text = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, separators=(",", ":"))
        log("%s ok (%d ms, %d chars)" % (name, took, len(text)))
        return text_result(text, False)
    log("%s failed: %s" % (name, reply.get("error")))
    return text_result("Error: %s" % reply.get("error", "unknown error"), True)


def decode_name(value):
    if value.startswith("=?base64?") and value.endswith("?="):
        try:
            return base64.b64decode(value[9:-2]).decode("utf-8")
        except Exception:
            return None
    return value


def header_problem(headers, method, params, version):
    sent = headers.get("mcp-protocol-version")
    if sent is not None and sent != version:
        return "MCP-Protocol-Version %s does not match the request's %s" % (sent, version)
    if headers.get("mcp-method") is not None and headers["mcp-method"] != method:
        return "Mcp-Method %s does not match the request's %s" % (headers["mcp-method"], method)
    if method == "tools/call" and headers.get("mcp-name") is not None and decode_name(headers["mcp-name"]) != params.get("name"):
        return "Mcp-Name does not match the tool name in the request"
    return None


async def handle_modern(mid, method, params, version, headers):
    """The 2026-07-28 revision: no handshake, every request says what it speaks."""
    if version not in MODERN:
        return 400, rpc_error(mid, -32022, "Unsupported protocol version", {"supported": MODERN + LEGACY, "requested": version})
    problem = header_problem(headers, method, params, version)
    if problem:
        return 400, rpc_error(mid, -32020, "Header mismatch: " + problem)
    meta = {META_SERVER: SERVER_INFO}
    if method == "server/discover":
        return 200, rpc_result(mid, {"resultType": "complete", "supportedVersions": MODERN, "capabilities": {"tools": {}},
                                      "_meta": meta, "instructions": INSTRUCTIONS, "ttlMs": 300000, "cacheScope": "private"})
    if method == "tools/list":
        return 200, rpc_result(mid, {"resultType": "complete", "tools": TOOL_LIST, "_meta": meta, "ttlMs": 300000, "cacheScope": "private"})
    if method == "tools/call":
        try:
            result = await tool_call(params)
        except RpcError as error:
            return 200, rpc_error(mid, error.code, error.message)
        result.update({"resultType": "complete", "_meta": meta})
        return 200, rpc_result(mid, result)
    return 404, rpc_error(mid, -32601, "Method not found: %s" % method)


async def handle_legacy(mid, method, params):
    """The revisions up to 2025-11-25: the client opens with initialize."""
    if method == "initialize":
        asked = params.get("protocolVersion")
        return 200, rpc_result(mid, {"protocolVersion": asked if asked in LEGACY else LEGACY[0],
                                      "capabilities": {"tools": {"listChanged": False}},
                                      "serverInfo": SERVER_INFO, "instructions": INSTRUCTIONS})
    if method == "ping":
        return 200, rpc_result(mid, {})
    if method == "tools/list":
        return 200, rpc_result(mid, {"tools": TOOL_LIST})
    if method == "tools/call":
        try:
            return 200, rpc_result(mid, await tool_call(params))
        except RpcError as error:
            return 200, rpc_error(mid, error.code, error.message)
    return 200, rpc_error(mid, -32601, "Method not found: %s" % method)


async def handle_rpc(message, headers):
    """(HTTP status, JSON-RPC response or None) for one JSON-RPC message."""
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return 400, rpc_error(None, -32600, "Invalid Request")
    method, mid = message.get("method"), message.get("id")
    if not isinstance(method, str) or "id" not in message:
        return 202, None  # a notification, or a response: nothing to answer
    params = message.get("params")
    if params is None:
        params = {}
    if not isinstance(params, dict):
        return 200, rpc_error(mid, -32602, "params must be an object")
    meta = params.get("_meta")
    version = meta.get(META_VERSION) if isinstance(meta, dict) else None
    if version is not None:
        return await handle_modern(mid, method, params, str(version), headers)
    return await handle_legacy(mid, method, params)


async def mcp_post(body, headers):
    try:
        message = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return 400, rpc_error(None, -32700, "Parse error")
    if isinstance(message, list):  # (a batch, in the 2025-03-26 revision)
        answers = []
        for item in message:
            _, answer = await handle_rpc(item, headers)
            if answer is not None:
                answers.append(answer)
        return (200, answers) if answers else (202, None)
    return await handle_rpc(message, headers)


# ------------------------------------------------------------------------------------------------
# HTTP
# ------------------------------------------------------------------------------------------------

def http_response(status, body=b"", ctype="application/json", extra=None):
    lines = ["HTTP/1.1 %d %s" % (status, REASONS.get(status, "OK")), "Content-Length: %d" % len(body), "Cache-Control: no-store"]
    if body:
        lines.append("Content-Type: " + ctype)
    lines.extend(extra or [])
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body


def json_response(status, obj):
    return http_response(status, json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


async def read_request(reader):
    line = await reader.readline()
    if not line:
        return None
    parts = line.decode("latin-1").split()
    if len(parts) < 2:
        raise ValueError("bad request line")
    headers = {}
    while True:
        raw = await reader.readline()
        if raw in (b"\r\n", b"\n", b""):
            break
        name, _, value = raw.decode("latin-1").partition(":")
        headers[name.strip().lower()] = value.strip()
        if len(headers) > 100:
            raise ValueError("too many headers")
    body = b""
    if "content-length" in headers:
        size = int(headers["content-length"])
        if size > MAX_BODY:
            raise ValueError("body too large")
        body = await reader.readexactly(size)
    elif headers.get("transfer-encoding", "").lower() == "chunked":
        chunks, total = [], 0
        while True:
            size = int((await reader.readline()).split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while (await reader.readline()) not in (b"\r\n", b"\n", b""):
                    pass
                break
            total += size  # counted before the chunk is read: a chunk can say it is as large as it likes
            if total > MAX_BODY:
                raise ValueError("body too large")
            chunks.append(await reader.readexactly(size))
            await reader.readline()
        body = b"".join(chunks)
    return parts[0].upper(), parts[1], headers, body


def host_ok(headers):
    host = headers.get("host", "")
    name = host.rsplit(":", 1)[0] if not host.endswith("]") and ":" in host else host
    return name.lower() in LOOPBACK


def origin_host(origin):
    rest = origin.split("://", 1)[-1].split("/", 1)[0]
    return (rest.rsplit(":", 1)[0] if not rest.endswith("]") and ":" in rest else rest).lower()


async def route(reader, writer, method, target, headers, body):
    """Answers one request. Returns whether the connection can be used for another."""
    path = target.split("?", 1)[0]
    if not host_ok(headers):
        writer.write(http_response(403, b"forbidden host", ctype="text/plain"))
        return True

    if path == "/game" and headers.get("upgrade", "").lower() == "websocket":
        origin = headers.get("origin")
        if origin and origin_host(origin) not in LOOPBACK:  # (a web page elsewhere; the token would stop it anyway)
            writer.write(http_response(403, b"forbidden origin", ctype="text/plain"))
            return False
        await game_session(reader, writer, headers)
        return False

    if path == "/mcp":
        if "origin" in headers:  # a browser: an MCP client is not one
            writer.write(json_response(403, rpc_error(None, -32600, "Forbidden origin")))
            return True
        if not hmac.compare_digest(headers.get("authorization", "").encode("utf-8"), ("Bearer " + TOKEN).encode("utf-8")):
            writer.write(http_response(401, b'{"error":"unauthorized","hint":"send the relay\'s token as Authorization: Bearer TOKEN"}',
                                       extra=['WWW-Authenticate: Bearer realm="opendex"']))
            return True
        if method != "POST":
            writer.write(http_response(405, extra=["Allow: POST"]))
            return True
        status, answer = await mcp_post(body, headers)
        writer.write(http_response(status) if answer is None else json_response(status, answer))
        return True

    if path == "/" and method == "GET":
        writer.write(http_response(200, b"OpenDex MCP relay\n", ctype="text/plain"))
        return True
    writer.write(http_response(404, b"not found", ctype="text/plain"))
    return True


async def handle(reader, writer):
    try:
        while True:
            request = await read_request(reader)
            if request is None:
                break
            keep = await route(reader, writer, *request)
            await writer.drain()
            if not keep:
                break
    except (asyncio.IncompleteReadError, ConnectionError, OSError):
        pass
    except ValueError as error:
        try:
            writer.write(http_response(400, str(error).encode("utf-8"), ctype="text/plain"))
            await writer.drain()
        except Exception:
            pass
    except Exception:
        log("internal error:\n" + traceback.format_exc())
        try:
            writer.write(http_response(500, b"internal error", ctype="text/plain"))
            await writer.drain()
        except Exception:
            pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


# ------------------------------------------------------------------------------------------------
# Start
# ------------------------------------------------------------------------------------------------

def load_token(given):
    if given:
        return given
    if os.environ.get("OPENDEX_TOKEN"):
        return os.environ["OPENDEX_TOKEN"]
    path = HERE / ".token"
    try:
        # (saved by a Windows tool it can start with a byte order mark, and PowerShell's > writes UTF-16)
        raw = path.read_bytes()
        saved = raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig").strip()
        if saved:
            return saved
    except OSError:
        pass
    except UnicodeError:
        print("The saved token (%s) is not text that can be read: a new one is made." % path)
    token = secrets.token_urlsafe(18)
    try:
        path.write_text(token + "\n", encoding="utf-8")
    except OSError:
        pass
    return token


def banner():
    url = "http://127.0.0.1:%d/mcp" % PORT
    print("OpenDex MCP relay %s" % VERSION)
    print("  listening on %s (this PC only)" % url)
    print("  token: %s" % TOKEN)
    print()
    print("  In OpenDex: open the AI window, paste the token, switch on \"Connect to the relay\".")
    print("  Then give your editor its lines below (the AI window's Copy button has the same text):")
    for name, where, text in EDITORS:
        print("  %s (%s):" % (name, where))
        print("    " + (text % (url, TOKEN)).replace("\n", "\n    "))
    print()
    print("Waiting for OpenDex... (Ctrl+C to stop)", flush=True)


async def listen():
    try:
        return await asyncio.start_server(handle, "127.0.0.1", PORT)
    except OSError as error:
        sys.exit("Could not listen on 127.0.0.1:%d (%s). Is the relay already running? Use --port for another port." % (PORT, error))


def loop_error(loop, context):
    # WinError 64 is a connection that was reset before it was accepted. asyncio reports it twice, with
    # a traceback each time; serve() says it in a line, and listens again.
    if getattr(context.get("exception"), "winerror", None) != 64:
        loop.default_exception_handler(context)


async def serve():
    server = await listen()
    banner()
    asyncio.get_running_loop().set_exception_handler(loop_error)
    try:
        while True:
            await asyncio.sleep(0.5)
            # Windows: when a client resets its connection before it is accepted, asyncio reports "Accept failed
            # on a socket" and closes the listening socket. The relay would run on without listening.
            if any(sock.fileno() == -1 for sock in server.sockets):
                server.close()
                server = await listen()
                log("the listening socket was lost (a client reset its connection); listening again")
    finally:
        server.close()


def port_number(text):
    try:
        port = int(text)
    except ValueError:
        port = 0
    if not 1024 <= port <= 65535:  # (the range OpenDex's AI window takes)
        raise argparse.ArgumentTypeError("%r is not a port: it has to be a number from 1024 to 65535" % text)
    return port


def main():
    global TOKEN, PORT
    for stream in (sys.stdout, sys.stderr):  # (a name from the game that the console cannot show must not stop a call)
        try:
            stream.reconfigure(errors="replace")
        except Exception:
            pass
    parser = argparse.ArgumentParser(description="Relay between MCP clients (Claude Code, VS Code) and OpenDex.")
    parser.add_argument("--port", type=port_number, default=os.environ.get("OPENDEX_PORT", "38211"), help="port on 127.0.0.1 (default 38211)")
    parser.add_argument("--token", help="the token clients must send (default: $OPENDEX_TOKEN, or one kept in .token next to this file)")
    options = parser.parse_args()
    PORT, TOKEN = options.port, load_token(options.token).strip()
    if not (TOKEN and TOKEN.isascii() and TOKEN.isprintable()):
        sys.exit("The token has to be plain text (ASCII letters, digits and signs): an editor sends it in an HTTP header.")
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
