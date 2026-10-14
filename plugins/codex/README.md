# Codex

Adds your **OpenAI Codex CLI** context to the Context folder, next to your Claude context.

**Install:**

```powershell
ClaudeContextManager plugin install codex
```

## What it adds

- **Codex sessions** (`~/.codex/sessions`, including archived ones), one Markdown transcript each: your prompts, Codex's replies and a one-line summary of every command and file edit
- **AGENTS.md** files (Codex's version of CLAUDE.md), from each project folder and your global `~/.codex/AGENTS.md`

## How it's sorted

Codex sessions go into the **same projects** as your Claude context, using the same rules: the folders the session worked in and edited (including `apply_patch` edits), and mentions of the project's name or keywords. They're kept **separate** from Claude's:

```
Context/<Project>/
  sessions/          Claude sessions
  codex/sessions/    Codex sessions
  codex/AGENTS.md
  PROJECT.md         "Sessions" table for Claude, "Codex sessions" table for Codex
```

In the menu, Codex sessions are labeled **Codex**. Ctrl+V moves them like any other session, and **Ctrl+R resumes them in Codex** (`codex resume <id>`).

Codex sessions sync with everything else: `ClaudeContextManager sync`, the background sync every 30 minutes, and after each Claude Code session (if you turned that on in setup). Uses `CODEX_HOME` if you've set it.

**Remove:** `ClaudeContextManager plugin remove codex`. It asks whether to keep the Codex context already in your folder.
