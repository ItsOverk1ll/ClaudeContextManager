# Gemini

Adds your **Google Gemini CLI** context to the Context folder, next to your Claude (and Codex) context.

**Install:**

```powershell
ClaudeContextManager plugin install gemini
```

## What it adds

- **Gemini CLI sessions** (`~/.gemini/tmp/<project>/chats`), one Markdown transcript each: your prompts, Gemini's replies and a one-line summary of every tool call (shell commands, file reads and edits). Gemini's own session summary becomes the title.
- **GEMINI.md** files (Gemini's version of CLAUDE.md), from each project folder and your global `~/.gemini/GEMINI.md`

## How it's sorted

Gemini sessions go into the **same projects** as the rest of your context, using the same rules: the project folder the session ran in, the files it read and edited, and mentions of the project's name or keywords. They're kept **separate**:

```
Context/<Project>/
  sessions/           Claude sessions
  gemini/sessions/    Gemini sessions
  gemini/GEMINI.md
  PROJECT.md          a "Gemini sessions" table of their own
```

In the menu they're labeled **Gemini**. Ctrl+V moves them, and **Ctrl+R resumes them in Gemini** (`gemini --resume <id>`). They sync with everything else. Uses `GEMINI_CLI_HOME` if you've set it. Subagent sessions are skipped.

With [OliveBranch](../olivebranch/README.md) installed, Claude and Codex can pull Gemini context when you ask, and Gemini can pull theirs.

**Remove:** `ClaudeContextManager plugin remove gemini`. It asks whether to keep the Gemini context already in your folder.
