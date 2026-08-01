# herdr-control-panel

One keybinding, one panel. Open a workspace from your history or from any path on disk — and put your own actions in the same menu.

A plugin for [herdr](https://herdr.dev). Pure bash and fzf, no build step.

日本語の README は [README.ja.md](README.ja.md) にあります。

```
┌──────────────────────────────────────────────┐
│ herdr control panel                          │
│                                              │
│ > New workspace                              │
│   Lazygit                                    │
│   File viewer                                │
│   + Add action...                            │
│   🌐 Language / 言語                          │
│   Cancel                                     │
└──────────────────────────────────────────────┘
```

## Why

Opening a new workspace in a terminal multiplexer means typing a path, and typing a path means
no completion, no history, and a typo you only notice after the pane is gone. Meanwhile every
new tool you wire up wants a keybinding of its own, and `prefix+`something-you-forgot does not
scale past about five of them.

This plugin trades N keybindings for one. Press it, and you get a fuzzy-filterable menu:
a workspace picker that remembers where you have been and completes paths as you type, plus
whatever else you decided belongs there.

## Install

```sh
herdr plugin install iskwyuki/herdr-control-panel
```

Then bind a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+space"
description = "open control panel"
type = "shell"
command = "herdr plugin action invoke open-control-panel --plugin herdr-control-panel"
```

The panel opens as a split pane on the right. To open it below instead, or as a full overlay,
edit `--direction` / `--placement` in `scripts/open-control-panel.sh`.

**Requires:** herdr 0.7.0+, [fzf](https://github.com/junegunn/fzf), [jq](https://jqlang.github.io/jq/), and bash.
Linux and macOS.

### Opening it in a floating popup

herdr's `type = "popup"` gives you a floating window instead of a pane, but it runs a plain shell
command — it does not inject the plugin environment (`HERDR_PLUGIN_CONFIG_DIR` /
`HERDR_PLUGIN_STATE_DIR`), and it has no way to know where the plugin was installed. So point it
at a small wrapper of your own that resolves the install path:

```sh
#!/usr/bin/env bash
root="$(herdr plugin list --json | jq -r '.result.plugins[] | select(.plugin_id=="herdr-control-panel").plugin_root')"
exec bash "$root/scripts/panel.sh"
```

```toml
[[keys.command]]
key = "prefix+space"
type = "popup"
command = "herdr-panel"   # the wrapper above, on your PATH
width = "50%"
height = "60%"
```

Resolving the path at run time is not optional: `herdr plugin install` puts the plugin under a
directory whose name contains the commit hash, so it changes on every update. Your config and
history are shared with the pane route either way — with the environment missing, the panel asks
herdr for its config directory and derives the state directory the same way herdr does.

## Opening a workspace

`New workspace` offers two ways in:

- **History** — directories you have opened before, most recent first. Stored one path per line
  in the plugin's state directory, capped at 50. Directories that no longer exist are not shown.
- **Open Folder...** — any path, with no restriction to a project root. The fzf query line doubles
  as a path input: the candidate list is regenerated on every keystroke.

| Key | Action |
|---|---|
| *(type)* | Filter candidates under that path. `~` and `$HOME`-relative paths work. Prefix matches sort first |
| `Enter` | Descend into the selected directory. Pick the leading `▸ Open here` to confirm instead |
| `Ctrl-O` | Confirm the typed path immediately, if it exists |
| `ESC` | Back to the previous menu (closes the panel from the main menu) |

Hidden directories appear only once you type a `.`. When the history is empty the menu is skipped
and Open Folder opens directly. It starts at `~/dev` if that exists, otherwise `$HOME`.

## Adding your own actions

Write them in `config.toml` in the plugin's config directory
(`herdr plugin config-dir herdr-control-panel` prints the path):

```toml
[[actions]]
label   = "Lazygit"
command = "lazygit"          # run through a shell, so pipes and arguments work
# requires = "lazygit"       # optional; defaults to the first word of "command"
```

Those three keys are the whole vocabulary. Anything else is **reported with its line number**
rather than silently ignored. Values cannot contain a double quote — use single quotes inside.

Picking `+ Add action...` in the panel appends to the very same file, so the UI and hand-editing
never disagree about where actions live. Commands that are not installed are labelled
`(not installed)` in the menu and refuse to run.

Validate without opening the panel:

```sh
bash "$(herdr plugin list --json | jq -r '.result.plugins[] | select(.plugin_id=="herdr-control-panel").plugin_root')/scripts/panel.sh" --check-config
```

The panel's own language (English / Japanese, English by default) is switched from the
`🌐 Language` entry, not from this file.

## Design notes

**It ships with one action, on purpose.** The panel is a good place to put lazygit, a file viewer,
a system monitor — but every one of those is a bet that you have that tool installed. Shipping
those items would mean shipping menu entries that fail silently on someone else's machine, so the
distributed plugin contains exactly one action that is guaranteed to work: the one built on herdr
itself. Everything else is a two-line block you add.

**A broken config never breaks the panel.** Config errors and core functionality are deliberately
decoupled: a malformed `config.toml` surfaces as a `⚠ N problem(s)` entry you can select to read,
while `New workspace` keeps working. The worst possible outcome for a panel bound to a keybinding
is that it stops opening at all.

**A TOML subset, not a TOML parser.** bash has no TOML parser, and writing a real one in bash is
a bug farm. So the parser accepts a documented subset — `[[actions]]` with `label` / `command` /
`requires`, double-quoted values, no escapes — and everything outside it becomes an error with a
line number. The template written on first run documents that subset in the file itself.

**fzf, not a hand-rolled TUI.** It handles mouse clicks (gum did not), it fuzzy-filters for free,
and `--disabled` plus `change:reload` turns its query line into a path input that re-completes on
every keystroke. The Open Folder browser is that one trick.

**bash 3.2 compatible.** macOS still ships bash 3.2 as `/bin/bash`, and a terminal launched from
a GUI app does not necessarily have Homebrew's bash 5 on `PATH`. No associative arrays, no `mapfile`.

## License

MIT — see [LICENSE](LICENSE).
