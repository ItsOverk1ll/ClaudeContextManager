# OliveBranch

An **opt-in bridge** between your agents: lets Claude read your Codex context for a project, and Codex read your Claude context. Without it, each agent's context stays separate.

**Install:**

```powershell
ClaudeContextManager plugin install olivebranch
```

It's only useful with a second agent, so install [codex](../codex/README.md) too.

## Nothing is shared until you ask

### Per session (when you ask)

In a Claude Code or Codex session, ask for it:

> pull my Codex context · what did Claude do on this? · olive branch

Or call the skill directly: `/olivebranch` in Claude Code, `$olivebranch` in Codex. The agent runs `olive pull`, which syncs and prints the **other** agent's context for the project you're working in: its instruction files (CLAUDE.md / AGENTS.md), memory, a list of its sessions, and digests of the latest ones (prompts + last reply). If it can't tell the project from the folder, the agent asks you which one.

### Always on (per project, on purpose)

```powershell
ClaudeContextManager olive on hyprland-wsl      # asks you to confirm
ClaudeContextManager olive off hyprland-wsl
ClaudeContextManager olive status
```

Or open the project in the menu and press **Ctrl+P → OliveBranch**. When it's on, every new Claude and Codex session in that project's folders starts with the other agent's context (a short version; the agent can pull more). It's off for every project until you turn it on, and it applies only to the projects you turn on.

## How it works

- Installs a skill for Claude Code (`~/.claude/skills/olivebranch`) and Codex (`~/.agents/skills/olivebranch`). The skills only run when you ask for the other agent's context.
- When a project is set to always on, adds a `SessionStart` hook to `~/.claude/settings.json` and `~/.codex/hooks.json`. The hook does nothing in projects that aren't on, and it's removed when no project is on. Codex may ask you to review the hook the first time.
- The context is labeled as background from the other agent, so neither agent treats old instructions in it as new requests from you.
- Settings are saved in `<Context>\.ccm\olivebranch.json`, so they follow your context repo.

**Remove:** `ClaudeContextManager plugin remove olivebranch` removes the skills and hooks. Your Context folder isn't touched.
