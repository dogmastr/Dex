# OpenDex

![OpenDex with the Script Viewer open: search across all scripts, the code, and a function's flowchart](./preview.png)

OpenDex is an explorer and script reverse-engineering suite for Roblox that runs inside the game through an executor. Next to the usual Dex windows it has a Script Viewer that works like a code navigator: it parses the decompiled Luau, draws flowcharts, inspects and edits the running script, and searches every script of the game.

## Download

Get `out.lua` from the [latest release](https://github.com/dogmastr/OpenDex/releases/latest) and run it in your executor, or load it directly:

```lua
loadstring(game:HttpGet("https://github.com/dogmastr/OpenDex/releases/latest/download/out.lua"))()
```

## Features

### Script Viewer

- **Code navigation:** tabs, find, go to definition, find references and assignments, back and forward. All of it follows `require` into other modules.
- **Annotations:** rename locals, type a note on any line (click the line and type), and apply suggested names for `v12`-style variables. They are saved per script and survive a different decompile.
- **Instances:** what stands for an instance that is in the game (`game.ReplicatedStorage.Remotes`, `script.Parent`, `:WaitForChild("Gui")`) is underlined. Ctrl+click selects it in the Explorer.
- **Navigator sidebar:** the script's outline, callers and callees, and remote, HTTP and `loadstring` calls with resolved paths.
- **Graphs:** a flowchart of the function under the cursor, the script's call graph, and the modules around it. Click a box to jump to its code.
- **Live values:** constants and upvalues of the running script are outlined in the code. Hover one to read or change it, or pin it to the watch list.
- **Tracing:** log a function's arguments, return values and caller. A tracepoint can take a condition, force a return value or change arguments.
- **Runtime tools:** count which functions run, scan for where a value is kept, and open the value a module returned.
- **Search all scripts:** decompiles every script in the background and caches it. Search as text, whole word, Lua pattern, name, string, or a call such as `FireServer(Buy)`.
- **Game overview:** a remote map (who fires and who listens to each remote), scripts ranked by what they contain (remotes, HTTP, obfuscation), and a diff of what changed since your last session.
- **Decompilers:** the executor's own, or Konstant and Advanced Decompiler. Diff two decompiles, a snapshot, the previous version or another tab.

### Explorer and Properties

- Instance tree with current Studio icons and API. Search as you type, with filters such as `/isa Part`, `/remotes` and `/rad 50`.
- Cut, copy, paste, duplicate, group, rename and insert objects.
- **Copy as Code** writes the Luau that rebuilds an object: `Instance.new`, the properties that differ from a new one, attributes and tags.
- **Find in Scripts** searches every script for the object's name.
- Remotes: block from firing (a blocked remote is shown in red), open one in the Remote Spy, see where the game's scripts use it.
- View connections, fire ClickDetectors, ProximityPrompts and TouchTransmitters, play tweens and animations, browse nil instances, click a part to select it.
- Properties filter as you type, with editors for enums, colours, sequences and attributes. Right-click a property to copy its value (as text or as code), its name or its path.

### Remote Spy

- **Sent and received:** lists what the game's scripts send to the server (`FireServer`, `InvokeServer`) and what the server fires at the client (`OnClientEvent`) or invokes on it (`OnClientInvoke`) as it happens, grouped by remote. Bindables can be listed too.
- **Each call:** its arguments, what an invoke returned, and the script, function and line that made it. **Go to call** opens that script in the Script Viewer at the call.
- **As code:** a call is written out as the Luau that makes it again, with the remote's path. Copy it, resend it from the window, or copy a hook snippet for the remote.
- **Block, rules and hide:** stop a remote from firing, or leave a noisy remote out of the list. A rule blocks only the calls a Luau condition names, or sends other arguments in place of the game's. Its window shows the picked call's arguments to click, can write the condition from that call (**Block calls like this**), tries the rule on the call before it is saved, and says when a rule breaks.

### AI window

- **Your editor's AI, on the game:** the **AI** window connects OpenDex to Claude Code, VS Code, Codex, Cursor, Antigravity or opencode through a small relay program (Python, nothing to install; it is in the [`mcp`](./mcp) folder). The AI can list the game's scripts, read a function with its callers, its calls and the remotes it fires, read the Remote Spy's calls, name the variables a decompiler made up (`v12`), write notes on lines and suggest a Remote Spy rule.
- **Every script together:** it can search the code of every script (text, a name, a string, a call), see which scripts fire and listen to a remote, which scripts require a module and use its functions, what each script holds (remotes, HTTP, signs of obfuscation), and what changed since your last visit.
- **The running script:** it can count which functions are called while you do something in the game, log a function's calls with their arguments, and read a function's upvalues and constants, or what a module returned.
- **The game itself:** it can also search the game's objects and read their properties, list every remote, read the output, search the memory (functions, tables, what listens to an event), and run Luau code in the game.
- **What it changes:** names go through the same checks as Apply all and are saved like any rename; a note starts with `AI:` and never replaces one of yours; a rule is only put in the Rules window for you to read and save. Counting and logging calls use the Script Viewer's own hooks: they show in the Outline and on the Trace page, and come off when they are stopped or OpenDex closes.
- **Running code:** the `run` tool runs what the AI wrote in your game with your executor's functions, like a line typed into the Console: it can change the game, fire remotes, write files and send requests. It is there as soon as the AI window is connected. The relay tells your editor that this tool changes things, so an editor that asks before such a tool asks before each run. What comes from the game is data to the AI, never instructions.
- **What it did:** the window's **Activity** page lists every request, the newest first, and marks the ones that ran code, wrote something or hooked a function. Pick one to read it in full: the code that ran, exactly as it was sent, and what came back. **Disconnect** cuts the AI off at once, and stops code it is still running.
- **Set it up:** the window's **Set up** page has the three steps (start the relay, connect with its token, add OpenDex to your editor), and each says by itself whether it is done or what is wrong. The details are in [mcp/README.md](./mcp/README.md).

### Everything else

- **Console:** the game's output with a search box and a switch per kind of message, and a command box with history.
- **3D Viewer:** preview a model, accessory or folder.
- **Save Instance:** the executor's `saveinstance`, or USSI as the fallback.
- **Command palette** for every action, dockable windows with layout presets, and touch support.

## Build

Run `python build.py` (Python 3). It joins `header.lua`, `modules/` and `main.lua` into `out.lua`, the file to run in your executor.

## Executor support

OpenDex starts with whatever the executor has. A feature it cannot run is greyed out and names the missing function.

| Feature | Functions |
|---|---|
| Viewing scripts | `decompile`, or `getscriptbytecode` for the other decompilers |
| Script cache and change tracking | `getscripthash`, `readfile`, `writefile`, `listfiles`, `delfile` |
| Live values | `getgc`, `getupvalues`, `getconstants`, `setupvalue`, `setconstant` |
| Tracing | `hookfunction` |
| Remote Spy: what the game sends, blocking remotes | `hookmetamethod`, `getnamecallmethod` (and `hookfunction` for calls written `remote.FireServer(remote)`) |
| Remote Spy: what the server sends | `getconnections` for events, `getcallbackvalue` for invokes |
| Remote Spy: rules | `loadstring` |
| AI window | `WebSocket` (and a relay program on the PC, see [`mcp`](./mcp)) |

## Files it writes

Everything goes in the executor's workspace folder.

| Path | What it holds |
|---|---|
| `OpenDexSettings.json` | The settings. |
| `dex/layout.json` | What each window remembers: the Script Viewer's panes, the Console's text size and switches, the Remote Spy's Bindables switch, Save Instance's options. Which windows are open is not remembered between visits: OpenDex starts with the Explorer and Properties, and keeps the windows only when it is run again in the same game. |
| `dex/rbx_api.dat`, `dex/rbx_rmd.dat`, `dex/deps_version.dat` | Roblox's API dump and class metadata. Downloaded again when Roblox updates. |
| `dex/cache/` | Every script that was decompiled, by hash, and an index per place. A cached script opens without the decompiler. |
| `dex/annotations/` | Renames and notes, one file per script. |
| `dex/recent.json` | The scripts opened lately, per place. |
| `dex/agent.json` | The AI window's switch, port and the relay's token. |
| `dex/plugins/` | Your plugins (see below). |

Save Instance and "Save script" write their files next to the `dex` folder. Deleting `dex` is safe: you lose the annotations and your plugins, and everything else is made again.

## What it downloads

| When | What | From |
|---|---|---|
| At start | Roblox's version, API dump and class metadata. This is data, and it is kept in `dex/`. | `clientsettings.roblox.com`, `setup.roblox.com` and [Roblox-Client-Tracker](https://github.com/CloneTrooper1019/Roblox-Client-Tracker) |
| Decompiling with Konstant | Nothing that is run: the script's bytecode is sent to the Konstant server, and its code comes back as text. | `api.plusgiant5.com` |
| Decompiling with Advanced Decompiler | The decompiler, which is someone else's script: it is **downloaded and run**. | [AZYsGithub/Advanced-Decompiler-V3](https://github.com/AZYsGithub/Advanced-Decompiler-V3) |
| Save Instance on an executor with no `saveinstance` | USSI, which is someone else's script: it is **downloaded and run**. | [luau/UniversalSynSaveInstance](https://github.com/luau/UniversalSynSaveInstance) |

The two scripts that are run are pinned to a commit, and so is the code they download themselves. What runs is what was there when the pin was set, not what is on those repositories today. The pins are in `main.lua` (`pinnedScript`), so a newer version of either script arrives with a new version of OpenDex.

## Plugins

A Lua file in `dex/plugins` is loaded when OpenDex starts and gets a tile in its menu. The file returns a table:

- `InitDeps(data)` is called first with OpenDex's own tables: `Main`, `Lib` (the UI kit), `Apps` (the other windows, such as `Apps.Explorer`), `Settings`, `API`, `RMD`, `env` (the executor's functions; one the executor lacks is `nil`), `service` and `plr`.
- `Main()` returns the plugin. Its `Init()` runs once and has to set `Window`, a `Lib.Window`. If it has an `Unload()`, that runs before OpenDex reloads: undo there whatever the plugin hooked.
- `PluginData.FriendlyName` is the name on the tile.

```lua
-- dex/plugins/hello.lua
local Main, Lib

return {
	PluginData = {Name = "Hello", FriendlyName = "Hello"},

	InitDeps = function(data)
		Main, Lib = data.Main, data.Lib
	end,

	Main = function()
		local Hello = {}

		Hello.Init = function()
			local window = Lib.Window.new()
			window:SetTitle("Hello")
			window:Resize(220, 120)
			Hello.Window = window

			local button = Lib.Button.new()
			button.Text = "Say hello"
			button.Position = UDim2.new(0, 10, 0, 10)
			button.Size = UDim2.new(1, -20, 0, 22)
			button.OnClick:Connect(function()
				Main.Notify("Hello from a plugin", "success")
			end)
			window:Add(button)
		end

		return Hello
	end,
}
```

A plugin that does not load is named in a notification with its error, and OpenDex starts without it.

## Credits

Based on [Dex++](https://github.com/AZYsGithub/DexPlusPlus) by Chillz, which extends [Moon's Dex](https://github.com/LorekeeperZinnia/Dex). Uses Konstant, [Advanced Decompiler](https://github.com/w-a-e/Advanced-Decompiler-V3) and [USSI](https://github.com/luau/UniversalSynSaveInstance) as fallbacks.

Licensed under [MIT](./LICENSE).
