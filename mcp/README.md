# OpenDex MCP relay

Lets the AI in your editor (Claude Code, VS Code, Codex, Cursor, Antigravity, opencode) read what OpenDex shows and name the variables of a decompiled script. A script in a game can only connect out, never listen, so OpenDex cannot be an MCP server itself. This relay is the server: your editor connects to it, and OpenDex, running in the game, connects to it too.

```
your editor --MCP over HTTP--> relay (127.0.0.1) <--WebSocket, opened by the game-- OpenDex
```

It is two files: `opendex_mcp.py` and `tools.json` (what the AI is told about each tool). It needs Python 3.9 or newer and nothing else. It does not use any AI itself and keeps nothing but the token.

## Set it up

1. **Start the relay.** In this folder: `python opendex_mcp.py`. It prints a token, saves it in `.token`, and prints what step 3 needs for each editor, with the token filled in. Leave it open.
2. **Connect OpenDex.** Open the **AI** window in OpenDex, paste the token, switch on **Connect to the relay**. The dot turns green. It needs an executor with `WebSocket`; the window says so if yours has none.
3. **Add OpenDex to your editor.**
   - **Claude Code**, in any terminal (VS Code's works if the `claude` command is installed): `claude mcp add --scope user --transport http opendex http://127.0.0.1:38211/mcp --header "Authorization: Bearer TOKEN"`. `--scope user` saves it for every folder; without it Claude Code saves it for the terminal's current folder only, and the VS Code panel may not find it. In the VS Code panel, `/mcp` opens a dialog that can add a server too (HTTP, the same URL and header). Start a new conversation, type `/mcp`, and `opendex` should say **Connected**.
   - **VS Code's own agent**, in `.vscode/mcp.json`: `{"servers": {"opendex": {"type": "http", "url": "http://127.0.0.1:38211/mcp", "headers": {"Authorization": "Bearer TOKEN"}}}}`.
   - **Codex** (its CLI, its VS Code extension and its app read the same file), at the end of `~/.codex/config.toml`. Replace the block if it is there already:
     ```toml
     [mcp_servers.opendex]
     url = "http://127.0.0.1:38211/mcp"
     http_headers = { "Authorization" = "Bearer TOKEN" }
     ```
   - **Cursor**, in `~/.cursor/mcp.json`: `{"mcpServers": {"opendex": {"url": "http://127.0.0.1:38211/mcp", "headers": {"Authorization": "Bearer TOKEN"}}}}`.
   - **Antigravity**, in `~/.gemini/config/mcp_config.json` (the agent panel's **...** menu, **MCP Servers**, **Manage MCP Servers**, **View raw config** opens it): `{"mcpServers": {"opendex": {"serverUrl": "http://127.0.0.1:38211/mcp", "headers": {"Authorization": "Bearer TOKEN"}}}}`.
   - **opencode**, in `~/.config/opencode/opencode.json`, or in a project's own `opencode.json`: `{"mcp": {"opendex": {"type": "remote", "url": "http://127.0.0.1:38211/mcp", "oauth": false, "headers": {"Authorization": "Bearer TOKEN"}}}}`.

   `~` is your user folder (`C:\Users\you` on Windows). If a file lists other servers already, add only the `"opendex": {...}` part to its list. Then start a new conversation; some editors read the file only when they start. Any other editor that speaks MCP over HTTP works the same way: it needs the URL and the header `Authorization: Bearer TOKEN`.
4. **Ask.** Click into a function in the Script Viewer and say "name the variables in the function I'm looking at". The AI reads it, and the new names appear in your viewer, saved with your other renames.

The AI window's **Copy its setup text** button gives the text for the editor picked in its **Editor** list, with your port and token in it. `/mcp` only shows the link between the editor and the relay. Whether the game is connected shows in the AI window and in the `status` tool: with the relay up and no game, every tool answers "OpenDex is not connected".

Do not commit the token. Everything above keeps it in your user folder, except `.vscode/mcp.json` and a project's `opencode.json`, which sit in the project. A project `.mcp.json` can use `"Authorization": "Bearer ${OPENDEX_TOKEN}"` to read it from an environment variable.

## What the AI can do

| Tool | What it does |
|---|---|
| `status` | OpenDex's version, the executor, which features it has |
| `context` | what you are looking at: the open script, the line and function the cursor is on, the Explorer selection |
| `scripts` | the game's scripts, with ids (`s17`), filtered by path |
| `outline` | a script's functions with their lines |
| `source` | a script's decompiled source with line numbers, in ranges |
| `function` | one function: its code, who calls it, what it calls, its remote and HTTP calls with resolved paths, and the locals the decompiler named |
| `annotations` | your renames and notes for a script |
| `remote_log` | the remotes the Remote Spy has seen, and a remote's newest calls with the script and function behind each |
| `apply_names` | renames locals the decompiler named (`v12`), the way Apply all does: checked for clashes, saved with your annotations |
| `note` | writes a note on a line, starting with `AI:`; a note of yours is never overwritten |
| `open` | shows a script in the Script Viewer at a line |
| `suggest_rule` | puts a block condition in the Remote Spy's Rules window; you read it and press Save |

It cannot run code in the game, fire or block a remote, or turn a rule on. A rule it suggests may only compare, calculate, read properties and call a few functions that only read; anything else is refused before it reaches the box. Everything that comes from the game (decompiled code, names, strings, remote arguments) is data: the AI is told not to follow instructions found in it, and no tool would act on them anyway. What the AI reads is sent to the AI service your editor uses, like anything else you ask it about.

The AI window lists every request, with how long it took and whether it failed.

## Options

`python opendex_mcp.py --port 38211 --token TOKEN`. The port can also come from `OPENDEX_PORT`, the token from `OPENDEX_TOKEN`. Use the same port in OpenDex's AI window.

The relay listens on 127.0.0.1 only, refuses requests that carry an `Origin` header (a web page), and needs the token from the editor and from the game. One OpenDex at a time: a newer one replaces the older.

## When it does not work

- **The relay says the port is in use:** another relay is running (close it), or use `--port`.
- **`/mcp` does not list `opendex`:** start a new conversation first. If it is still missing, it was added without `--scope user`, which saves it for one folder only: run the `claude mcp add` command from the relay's window again.
- **`/mcp` shows Failed or "needs authentication":** the token in the editor's config is not the relay's. Run the `claude mcp add` command from the relay's window again.
- **Another editor shows `opendex` as failed, or asks you to sign in:** the relay is not running, or the token in that editor's file is not the relay's. The relay prints every editor's text, with the token, when it starts.
- **The AI window says "the relay is not running":** start it, or check the port. OpenDex tries again every few seconds.
- **The AI window says the relay refused the token:** paste the token the relay printed (or the one in `.token`).
- **Tools answer "OpenDex is not connected":** the relay is up but OpenDex is not connected to it: open the AI window and switch on Connect to the relay.
- **A tool takes long:** the first read of a big script decompiles it. The relay waits up to two minutes.
