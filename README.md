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
- **Annotations:** rename locals, add notes and bookmarks, and apply suggested names for `v12`-style variables. They are saved per script and survive a different decompile.
- **Navigator sidebar:** the script's outline, callers and callees, and remote, HTTP and `loadstring` calls with resolved paths.
- **Graphs:** a flowchart of the function under the cursor, the script's call graph, and the modules around it. Click a box to jump to its code.
- **Live values:** constants and upvalues of the running script are outlined in the code. Hover one to read or change it, or pin it to the watch list.
- **Tracing:** log a function's arguments, return values and caller. A tracepoint can take a condition, force a return value or change arguments.
- **Runtime tools:** count which functions run, scan for where a value is kept, tap what goes to `loadstring` and HTTP, and open the value a module returned.
- **Search all scripts:** decompiles every script in the background and caches it. Search as text, whole word, Lua pattern, name, string, or a call such as `FireServer(Buy)`.
- **Game overview:** a remote map (who fires and who listens to each remote), scripts ranked by what they contain (remotes, HTTP, obfuscation), and a diff of what changed since your last session.
- **Decompilers:** the executor's own, or Konstant, Advanced Decompiler and Shiny. Diff two decompiles, a snapshot, the previous version or another tab.

### Explorer and Properties

- Instance tree with current Studio icons and API. Search as you type, with filters such as `/isa Part`, `/remotes` and `/rad 50`.
- Cut, copy, paste, duplicate, group, rename and insert objects.
- Remotes: block from firing, find the calling script, see where the game's scripts use it.
- View connections, fire ClickDetectors, ProximityPrompts and TouchTransmitters, play tweens and animations, browse nil instances, click a part to select it.
- Properties filter as you type, with editors for enums, colours, sequences and attributes.

### Everything else

- **Console:** the game's output and a command box.
- **3D Viewer:** preview a model, accessory or folder.
- **Save Instance:** the executor's `saveinstance`, or USSI as the fallback.
- **Command palette** for every action, dockable windows with saved layouts, and touch support.

## Build

Run `python build.py` (Python 3). It joins `header.lua`, `modules/` and `main.lua` into `out.lua`, the file to run in your executor.

## Executor support

OpenDex starts with whatever the executor has. A feature it cannot run is greyed out and names the missing function.

| Feature | Functions |
|---|---|
| Viewing scripts | `decompile`, or `getscriptbytecode` for the other decompilers |
| Script cache and change tracking | `getscripthash`, `readfile`, `writefile`, `listfiles`, `delfile` |
| Live values | `getgc`, `getupvalues`, `getconstants`, `setupvalue`, `setconstant` |
| Tracing, taps, blocking remotes | `hookfunction`, `hookmetamethod` |

## Credits

Based on [Dex++](https://github.com/AZYsGithub/DexPlusPlus) by Chillz, which extends [Moon's Dex](https://github.com/LorekeeperZinnia/Dex). Uses Konstant, [Advanced Decompiler](https://github.com/w-a-e/Advanced-Decompiler-V3), [Shiny](https://github.com/rocult/shiny) and [USSI](https://github.com/luau/UniversalSynSaveInstance) as fallbacks.

Licensed under [MIT](./LICENSE).
