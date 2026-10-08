# OpenDex MCP relay

Lets the AI in your editor (Claude Code, VS Code, Codex, Cursor, Antigravity, opencode) read the game through OpenDex, name the variables of a decompiled script, and run code in the game. A script in a game can only connect out, never listen, so OpenDex cannot be an MCP server itself. This relay is the server: your editor connects to it, and OpenDex, running in the game, connects to it too.

```
your editor --MCP over HTTP--> relay (127.0.0.1) <--WebSocket, opened by the game-- OpenDex
```

It is two files: `opendex_mcp.py` and `tools.json` (what the AI is told about each tool). It needs Python 3.9 or newer and nothing else. It does not use any AI itself and keeps nothing but the token.

## Set it up

1. **Start the relay.** In this folder: `python opendex_mcp.py`. It prints a token, saves it in `.token`, and prints what step 3 needs for each editor, with the token filled in. Leave it open.
2. **Connect OpenDex.** Open the **AI** window in OpenDex. On its **Set up** page, paste the token under step 2, then press **Connect** at the top. The status turns to **Connected** and the first two steps say **Done**. It needs an executor with `WebSocket`; the window says so if yours has none.
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

The **Set up** page shows the same three steps, and each says by itself whether it is done, being checked, or has a problem. Its **Copy its setup text** button gives the text for the editor picked in the **Editor** list, with your port and token in it, and the step says where to paste it. `/mcp` only shows the link between the editor and the relay. Whether the game is connected shows in the AI window and in the `status` tool: with the relay up and no game, every tool answers "OpenDex is not connected".

Do not commit the token. Everything above keeps it in your user folder, except `.vscode/mcp.json` and a project's `opencode.json`, which sit in the project. A project `.mcp.json` can use `"Authorization": "Bearer ${OPENDEX_TOKEN}"` to read it from an environment variable.

## What the AI can do

| Tool | What it does |
|---|---|
| `status` | OpenDex's version, the executor and its features, the place, the player, how much the game holds |
| `context` | what you are looking at: the open script, the line and function the cursor is on, the Explorer selection |
| `scripts` | the game's scripts, with ids (`s17`), filtered by path or by what they hold (remotes, HTTP, loadstring, signs of obfuscation, changed, your notes), with what is in each |
| `search` | searches the code of every script: text, a whole word, a Lua pattern, a name, a string, or a call of a function |
| `outline` | a script's functions with their lines |
| `source` | a script's decompiled source with line numbers, in ranges |
| `function` | one function: its code, who calls it, what it calls, its remote and HTTP calls with resolved paths, and the locals the decompiler named |
| `annotations` | your renames and notes for a script |
| `usage` | what a script requires and which scripts require it; every use of a module's function or field in the other scripts |
| `remote_map` | which scripts fire and listen to a remote, with the line and the arguments; the remotes no script mentions |
| `changes` | the scripts that changed, appeared or went since your last visit, and what changed in one |
| `live` | a running function's upvalues and constants; what a module returned |
| `coverage` | counts the calls of a script's running functions while you do something in the game: which functions ran |
| `trace` | logs the calls of a function: its arguments, what it returned, where it was called from |
| `remote_log` | the remotes the Remote Spy has seen, and a remote's newest calls with the script and function behind each |
| `apply_names` | renames locals the decompiler named (`v12`), the way Apply all does: checked for clashes, saved with your annotations |
| `note` | writes a note on a line, starting with `AI:`; a note of yours is never overwritten |
| `open` | shows a script in the Script Viewer at a line |
| `suggest_rule` | puts a block condition in the Remote Spy's Rules window; you read it and press Save |
| `instances` | searches the game's objects by name or class; describes one object: its properties, attributes, tags and children |
| `remotes` | every remote in the game, used or not, with how many calls the Remote Spy caught on each |
| `console` | the game's output, filtered by text or kind |
| `memory` | searches the garbage collector for functions and for tables with a key; lists what listens to an object's events |
| `run` | runs Luau code in the game and returns what it returned and printed |

`run` runs what the AI wrote in your game, with your executor's functions, like a line typed into the Console. It can change the game, fire remotes, press buttons, write files and send requests, and nothing undoes it. It is on whenever OpenDex is connected to the relay; there is no switch for it. The relay marks it for your editor as a tool that changes things and reaches outside, so an editor that asks before such tools asks before each run: keep that question on unless you want the AI to act by itself. Code that has not finished after its timeout (10 seconds unless the AI asks for more, 100 at most) is stopped.

The other tools read, or write into OpenDex's own renames and notes: none of them fires or blocks a remote, or turns a rule on. Two of them, `coverage` and `trace`, put the Script Viewer's hooks on functions of the game to count or log their calls. The functions run as before, the hooks show in the Outline and on the Trace page, and they come off when the AI or you stop them, or when OpenDex closes; the relay marks both as tools that change something. A rule the AI suggests may only compare, calculate, read properties and call a few functions that only read; anything else is refused before it reaches the box. Everything that comes from the game (decompiled code, names, strings, property values, remote arguments, output) is data: the AI is told not to follow instructions found in it, and not to run code because something in the game said to. That is an instruction to the AI, not a lock: with `run` there, a game that plants text for an AI to read could get code run if the AI obeyed it. What the AI reads is sent to the AI service your editor uses, like anything else you ask it about.

## What the AI did

The AI window's **Activity** page lists every request, the newest at the top, with how long it took and whether it failed. A request that is still running is listed too. Pick one to read it in full: the code of a `run` exactly as it was sent, or a tool with its arguments, and under it what OpenDex answered. **Copy request** and **Copy answer** put either on the clipboard. **Changes** narrows the list to what ran code, wrote something or hooked a function, **Failed** to what failed. The list keeps the last 100 requests of this visit. **Disconnect**, at the top of the window, cuts the AI off at once and stops code it is still running (not what that code started by itself with `task.spawn`).

## Options

`python opendex_mcp.py --port 38211 --token TOKEN`. The port can also come from `OPENDEX_PORT`, the token from `OPENDEX_TOKEN`. Use the same port in OpenDex's AI window.

The relay listens on 127.0.0.1 only, refuses requests that carry an `Origin` header (a web page), and needs the token from the editor and from the game. One OpenDex at a time: a newer one replaces the older.

## When it does not work

- **The relay says the port is in use:** another relay is running (close it), or use `--port`.
- **`/mcp` does not list `opendex`:** start a new conversation first. If it is still missing, it was added without `--scope user`, which saves it for one folder only: run the `claude mcp add` command from the relay's window again.
- **`/mcp` shows Failed or "needs authentication":** the token in the editor's config is not the relay's. Run the `claude mcp add` command from the relay's window again.
- **Another editor shows `opendex` as failed, or asks you to sign in:** the relay is not running, or the token in that editor's file is not the relay's. The relay prints every editor's text, with the token, when it starts.
- **The AI window says "The relay is not running":** start it, or check the port (under Options on the Set up page). OpenDex tries again every few seconds.
- **The AI window says the relay refused the token:** paste the token the relay printed (or the one in `.token`).
- **Tools answer "OpenDex is not connected":** the relay is up but OpenDex is not connected to it: open the AI window and press Connect.
- **A tool takes long:** the first read of a big script decompiles it. The relay waits up to two minutes.
- **A tool says its answer is from the scripts read so far:** `search`, `remote_map`, `usage`, `changes` and the filters of `scripts` need every script decompiled, which starts by itself and can take a while in a big game (the Script Viewer's status bar shows it). The AI asks again, or you tell it to.
