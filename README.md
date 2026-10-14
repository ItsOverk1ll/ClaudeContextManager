# ClaudeContextManager

Collects your context from **Claude Code** (the CLI and the Claude Desktop Code tab), **Claude memory**, **CLAUDE.md** files and **claude.ai / Claude Desktop chat exports** into one `Context` folder, **sorts it by project automatically**, and lets you browse it in a terminal menu (fzf, styled like [BetterHotkeys](https://github.com/ItsOverk1ll/BetterHotkeys) and following its theme). It can back the folder up to a private GitHub repo (default name **BitOfContext**).

## Install

```powershell
gh repo clone ItsOverk1ll/ClaudeContextManager
pwsh -File .\ClaudeContextManager\install.ps1
```

Requires Windows, PowerShell 7 and fzf (the installer installs missing ones with winget). Git + GitHub CLI are needed for the GitHub backup.

Setup asks:

1. Where to keep the Context folder (default `~\Context`)
2. Whether to sort automatically (default yes; otherwise new context goes to `Unsorted` for you to sort)
3. Whether to redact API keys/tokens/passwords (default yes)
4. Whether to sync when a Claude Code session ends (a `SessionEnd` hook in `~/.claude/settings.json`)
5. Whether to also sync every 30 minutes in the background (scheduled task, catches Desktop sessions)
6. Whether to create a **private** GitHub repo for your context (default `BitOfContext`) and push after every sync

## Use

| Command | |
|---|---|
| `ClaudeContextManager` or `ccm` | open the menu (both names take the commands below) |
| `ccm sync` | sync now (`--push`, `--resort`, `--quiet`) |
| `ccm push` | commit + push the Context folder |
| `ccm import <zip>` | import a claude.ai data export |
| `ccm setup` | run setup again |
| `ccm open` | open the Context folder |
| `ccm plugins` | browse and install plugins (`plugin install/update/remove/list <name>`) |
| `ccm uninstall` | remove hook, task and command (keeps your context) |

**Main menu:** Enter open project · Ctrl+S sync · Ctrl+N new project · Ctrl+R rename/merge · Ctrl+Y copy the project's context (docs + memory) to paste into Claude · Ctrl+O open folder

**Project menu:** Enter open file · Ctrl+V move to another project · Ctrl+R resume the session in Claude Code · Ctrl+Y copy · Ctrl+D remove (never re-imported) · Ctrl+O folder

## Plugins

Plugins add context from other AI agents, sorted into the same projects but kept in their own subfolder. Browse them in the menu (**⧉ Plugins**) or on the [Plugins branch](https://github.com/ItsOverk1ll/ClaudeContextManager/tree/Plugins), then install with one command:

```powershell
ClaudeContextManager plugin install codex     # OpenAI Codex CLI sessions + AGENTS.md
ClaudeContextManager plugin install olivebranch   # opt-in: let Claude read Codex context and vice versa
```

Each agent's context stays separate: Ctrl+Y copies only Claude's, and agents never get each other's context unless you install OliveBranch and ask (per session) or turn it on for a project.

`plugin list`, `plugin update` and `plugin remove <name>` manage them. The Plugins branch README explains how to write one.

## Context folder

```
Context/
  README.md                     overview of all projects
  <Project>/
    PROJECT.md                  sessions, memory and docs for the project
    CLAUDE.md                   copied from the project folder
    memory/*.md                 Claude memory files about the project
    sessions/<date>_<title>_<id>.md   one Markdown transcript per session/chat
    claude-ai-project/          claude.ai Project instructions + knowledge (from an export)
  Unsorted/                     context that didn't clearly match a project
  _Global/CLAUDE.md             your ~/.claude/CLAUDE.md
  .ccm/                         index, manual sorting, project rules
```

## How auto-sort works

Each session is scored against projects:

- **Folders it touched**: the session's working folder plus every file path in its tool calls (edits count more than reads). A path maps to its git repo root, or to its folder under your home / Documents / source\repos. New folders become projects automatically.
- **Mentions**: a project's name or keywords in your prompts or the title.

The best score wins; below the threshold the session goes to `Unsorted`. Folders you launch Claude from for everything (your home folder, `~\Claude`, Desktop) don't count. Anything you move by hand (Ctrl+V) stays where you put it, even after a re-sort. Folders and keywords per project live in `.ccm\projects.json` (Settings > Edit project rules).

## Claude Desktop chats

Claude Desktop **Code** sessions are on disk and sync automatically. Regular Desktop/claude.ai **chats** are stored on Anthropic's servers, so they come in through a data export: Claude > Settings > Privacy > **Export data**, then `ccm import <zip>` (or Settings > Import in the menu). claude.ai Projects in the export become project folders with their instructions and knowledge files.

## Privacy

Transcripts can include anything you pasted into Claude. Secret redaction is on by default (Anthropic/OpenAI/GitHub/AWS/Slack/Google keys, JWTs, private keys, `password=`-style values), but it's pattern-based: review before sharing. The GitHub repo is always created private, and setup refuses to use an existing public repo.
