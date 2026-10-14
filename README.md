# ClaudeContextManager plugins

Plugins add context from other AI agents to your Context folder. Find the one you want, then paste its install command into PowerShell.

| Plugin | What it adds | Install |
|---|---|---|
| [codex](plugins/codex/README.md) | OpenAI Codex CLI sessions + AGENTS.md files, sorted into your projects in a separate `codex` folder | `ClaudeContextManager plugin install codex` |
| [gemini](plugins/gemini/README.md) | Google Gemini CLI sessions + GEMINI.md files, sorted into your projects in a separate `gemini` folder | `ClaudeContextManager plugin install gemini` |
| [olivebranch](plugins/olivebranch/README.md) | Opt-in bridge: Claude, Codex and Gemini can read each other's context, when you ask in a session or always on for projects you choose | `ClaudeContextManager plugin install olivebranch` |

You can also browse and install plugins from the menu: **ClaudeContextManager → ⧉ Plugins** (or run `ClaudeContextManager plugins`).

| Command | |
|---|---|
| `ClaudeContextManager plugin install <name>` | install or update a plugin, then sync |
| `ClaudeContextManager plugin update` | update all installed plugins |
| `ClaudeContextManager plugin remove <name>` | remove a plugin (asks whether to keep its context) |
| `ClaudeContextManager plugin list` | show installed and available plugins |

Needs ClaudeContextManager 1.1.0 or newer (OliveBranch: 1.2.0). Plugins install to `%APPDATA%\ClaudeContextManager\plugins\<name>`.

---

## Writing a plugin

A plugin is a folder in `plugins/` with three files:

```
plugins/<name>/
  plugin.json   {"name", "version", "description", "author", "minCcmVersion"}
  plugin.ps1    dot-sourced by ClaudeContextManager on startup
  README.md     shown in the Plugins menu preview
```

`plugin.ps1` calls `Register-ContextSource`:

```powershell
Register-ContextSource @{
    Name       = 'myagent'          # stored with each item; also the plugin's subfolder in each project
    Label      = 'My Agent'         # shown in menus and as the PROJECT.md table heading
    Folder     = 'myagent'          # files go to <Project>\myagent\sessions\
    GetSources = { ... }            # -> objects: Id (unique, e.g. 'myagent:<uuid>'), Kind 'session', Path, Mtime, Size
    Read       = { param($src, $cache) ... }   # -> an item (below); $cache lives for one sync
    CopyDocs   = { param($projects, $config) ... }   # optional: copy instruction files into project folders
    Resume     = { param($id, $entry) ... }          # optional: reopen a session (runs in its folder)
}
```

An item is a `[pscustomobject]` with: `Id, Kind ('session'), SourcePath, Title, Cwd, Branch, Source` (label in tables), `Started, Updated` (DateTime), `Turns` (list of `@{ Role = 'user'|'assistant'; Time; Text = List[string]; Tools = List[string] }`), `Hits` (paths for sorting, add with `Add-PathHit $hits $path $weight`: 4 for the working folder, 3 for edited files, 1 for reads/commands), `UserText` (your prompts, for keyword matching), `Prompts` (count). Optional: `AssistantName` (transcript heading), `ResumeHint` (shown in the transcript).

Plugins can also add commands (`Register-CcmCommand -Name -Usage -Action { param($params, $flags) }`), entries in a project's Ctrl+P menu (`Register-ProjectAction -Label {..} -Run {..}`) and install/uninstall steps (`Register-PluginLifecycle -Name -OnInstall {..} -OnUninstall {..}`). `Get-AgentContext $config $project @('codex')` returns one agent's context for a project as text; see [olivebranch](plugins/olivebranch/plugin.ps1).

Sources are only re-read when `Mtime`/`Size` change, so syncing stays fast. Helpers available to plugins: `Add-PathHit`, `$PathRegex`, `ConvertTo-DateTime`, `Get-OneLine`, `Get-SafeName`, `Protect-Secrets`, `$Global` (the `_Global` folder name). See [plugins/codex/plugin.ps1](plugins/codex/plugin.ps1) for a complete example.

Test a plugin from a local folder before publishing: `ClaudeContextManager plugin install C:\path\to\plugins\<name>`.
