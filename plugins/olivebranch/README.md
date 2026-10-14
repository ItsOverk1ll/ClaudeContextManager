# OliveBranch

An **opt-in bridge** between your agents: lets Claude read your Codex and Gemini context for a project, and the other way around. Without it, each agent's context stays separate.

**Install:**

```powershell
ClaudeContextManager plugin install olivebranch
```

It works with **any two or more agents**: Claude plus [codex](../codex/README.md), [gemini](../gemini/README.md), or both. It doesn't need all three.

## Which agents take part

OliveBranch checks which agents are set up instead of assuming. An agent takes part when its context plugin is installed (Claude is built in) and its CLI is used on this PC. It checks again after every sync and whenever you install or remove a plugin. So:

- **Claude only:** nothing to bridge yet. OliveBranch installs no skills or hooks and tells you which plugin to add.
- **Claude + Codex** or **Claude + Gemini:** those two get the skill and can read each other's context.
- **Add an agent later:** it's picked up on the next sync or plugin install, with no reinstall needed. Removing a plugin takes its skill and hooks away again.
- **A plugin installed but its CLI gone from this PC:** Claude can still read that agent's saved context, but that agent gets no skill or hook (and no config folder is created for it).

## Nothing is shared until you ask

### Per session (when you ask)

In a Claude Code or Codex session, ask for it:

> pull my Codex context · what did Claude do on this? · olive branch

Or call the skill directly: `/olivebranch` in Claude Code and Gemini CLI, `$olivebranch` in Codex. The agent runs `olive pull`, which syncs and prints the **other** agent's context for the project you're working in: its instruction files (CLAUDE.md / AGENTS.md), memory, a list of its sessions, and digests of the latest ones (prompts + last reply). If it can't tell the project from the folder, the agent asks you which one.

### Always on (per project, on purpose)

```powershell
ClaudeContextManager olive on hyprland-wsl      # asks you to confirm
ClaudeContextManager olive off hyprland-wsl
ClaudeContextManager olive status
```

Or open the project in the menu and press **Ctrl+P → OliveBranch**. When it's on, every new Claude and Codex session in that project's folders starts with the other agent's context (a short version; the agent can pull more). It's off for every project until you turn it on, and it applies only to the projects you turn on.

## How it works

- Installs a skill for Claude Code (`~/.claude/skills/olivebranch`), Codex (`~/.agents/skills/olivebranch`) and Gemini CLI (`~/.gemini/skills/olivebranch`), for the agents you have. The skills only run when you ask for the other agent's context.
- When a project is set to always on, adds a `SessionStart` hook to `~/.claude/settings.json` and `~/.codex/hooks.json` (Gemini sessions don't get the always-on hook yet; ask for the context there). The hook does nothing in projects that aren't on, and it's removed when no project is on. Codex may ask you to review the hook the first time.
- The context is labeled as background from the other agent, so neither agent treats old instructions in it as new requests from you.
- Settings are saved in `<Context>\.ccm\olivebranch.json`, so they follow your context repo.

**Remove:** `ClaudeContextManager plugin remove olivebranch` removes the skills and hooks. Your Context folder isn't touched.
