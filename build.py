from pathlib import Path

# out.lua: header.lua, then every module as a function in the table EmbeddedModules, then main.lua
modules = sorted(Path("modules").glob("*.lua"), key=lambda path: path.name)
embedded = "".join(f'["{path.stem}"] = function()\n{path.read_text()}\nend,\n' for path in modules)
Path("out.lua").write_text(Path("header.lua").read_text() + "\n\nlocal EmbeddedModules = {\n" + embedded + "}\n" + Path("main.lua").read_text())
