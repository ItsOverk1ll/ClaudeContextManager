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
| `ccm search [words]` | search all your context (`--project=<name>` for one project) |
| `ccm summary <project>` | write a project's "where we left off" summary now (`--all` for every project) |
| `ccm cleanup [project ...]` | archive old or tiny sessions and shrink transcripts (no project: pick them) |
| `ccm plugins` | browse and install plugins (`plugin install/update/remove/list <name>`) |
| `ccm uninstall` | remove hook, task and command (keeps your context) |

**Main menu:** Enter open project · Ctrl+S sync · Ctrl+F search · Ctrl+N new project · Ctrl+R rename/merge · Ctrl+Y copy the project's Claude context to paste into Claude · Ctrl+W write summary · Ctrl+K clean up · Ctrl+O open folder

**Project menu:** Enter open file · Ctrl+V move to another project · Ctrl+R resume the session · Ctrl+F search this project · Ctrl+W write summary · Ctrl+K clean up · Ctrl+Y copy · Ctrl+D remove (never re-imported) · Ctrl+P plugin actions · Ctrl+O folder

## Built in

- **Where we left off.** Each project gets a short summary at the top of its PROJECT.md (also saved as `SUMMARY.md`): latest state, open threads, next steps and key facts. Claude writes it from the project's Claude context, using the small `haiku` model by default. Setup asks whether to refresh summaries automatically after syncs, at most every 2 hours per project and only when there are new sessions. You can also write one any time with Ctrl+W or `ccm summary <project>`. Summary runs use no tools and aren't saved as sessions, so they never show up in your context.
- **Search.** `/ Search` in the menu (or Ctrl+F) searches every transcript, memory file and doc as you type. The preview jumps to the match, and Enter opens the file at that line (in VS Code if you have it). It uses ripgrep, which the installer adds, or falls back to Windows' `findstr`.
- **Git activity.** For projects that are git repos, `GIT.md` lists recent commits by day, PROJECT.md shows the latest five, and each session row counts the commits made while that session was running. It only re-reads a repo when its HEAD changes.
- **Cleanup.** Ctrl+K on a project, or Settings > Clean up projects... to pick several. It asks how old a session has to be before it's removed (default 180 days), whether to remove tiny sessions (1 prompt or less), and whether to shrink the rest by dropping tool-call lines (prompts and replies stay). It shows the plan before doing anything. Removed sessions go into a zip in `%LOCALAPPDATA%\ClaudeContextManager\archive` (unless you say no) and are never imported again; shrunk sessions stay shrunk on later syncs.

## Plugins

Plugins add context from other AI agents, sorted into the same projects but kept in their own subfolder. Browse them in the menu (**⧉ Plugins**) or on the [Plugins branch](https://github.com/ItsOverk1ll/ClaudeContextManager/tree/Plugins), then install with one command:

```powershell
ClaudeContextManager plugin install codex     # OpenAI Codex CLI sessions + AGENTS.md
ClaudeContextManager plugin install gemini    # Google Gemini CLI sessions + GEMINI.md
ClaudeContextManager plugin install olivebranch   # opt-in: let your agents read each other's context
```

Each agent's context stays separate: Ctrl+Y copies only Claude's, and agents never get each other's context unless you install OliveBranch and ask (per session) or turn it on for a project.

`plugin list`, `plugin update` and `plugin remove <name>` manage them. The Plugins branch README explains how to write one.

## Context folder

```
Context/
  README.md                     overview of all projects
  <Project>/
    PROJECT.md                  where we left off, recent commits, sessions, memory and docs
    SUMMARY.md                  the "where we left off" summary
    GIT.md                      recent commits of the project's repos
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
