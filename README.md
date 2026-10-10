# agents.ranma

A plugin for [ranma](https://github.com/masshirodev/ranma), the terminal tiling window manager: what each AI agent running in a pane is doing.

## Install

With [hako](https://github.com/masshirodev/hako.ranma), in `~/.config/ranma/lua/plugins/agents.lua`:

```lua
return { "masshirodev/agents.ranma" }
```

Or by hand, as ranma loads any package under `pack/*/start/`:

```sh
git clone https://github.com/masshirodev/agents.ranma ~/.config/ranma/pack/plugins/start/agents.ranma
```

Needs: [ai-session](https://github.com/masshirodev/ai-session) (`ai peers`, `ai send`). Without `ai` the plugin stays quiet.

## What it does

```text
Reads `ai peers --json` every few seconds (ai-session: each agent's
profile, repo, branch, busy or idle, and its ranma pane), and:
  - marks each agent pane's border: ● working, ? needs you (it went idle
    while you were not looking), nothing once you have seen it;
  - toasts when an agent finishes out of sight;
  - leader i opens a screen of every agent, grouped: Needs you, Working,
    Idle, with the selected one's last lines below.
On the screen: enter jump to its pane, m message it (ai send), x stop it
(ctrl+c into its pane), o options.

An agent that is not Claude Code reports no state to ai; it is listed as
running. On a machine without `ai`, the plugin stays quiet.

ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md.
```

## Options

In ranma's settings panel under `agents`, or with hako's `opts` (`{ "masshirodev/agents.ranma", opts = { ... } }`), or `ranma.set { agents = { ... } }`.

| Option | Default | |
| --- | --- | --- |
| `agents.poll` | `3` | Seconds between two looks at the agents (ai peers). |
| `agents.notify` | `true` | A toast when an agent finishes in a pane you are not looking at. |
| `agents.badges` | `true` | Mark agent panes' borders: ● working, ? needs you. |
| `agents.ask` | `[[(?i)(proceed\?|\(y/n\)|\[y/n\]|allow .*\?|approve|permission)]]` | A regex for an agent asking something on its screen, for agents that tell ai nothing of their state (not Claude). |

## License

MIT or Apache-2.0, as ranma.
