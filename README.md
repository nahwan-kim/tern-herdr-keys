# Herdr Keys for Tern

A [Tern](https://stencil.so/tern) plugin that brings [herdr](https://github.com/herdrdev/herdr)-style spaces
to Tern. A herdr space is a Tern session.

| Key | Effect |
| --- | --- |
| ⌘⇧1 … ⌘⇧9 | Show the Nth session in the vertical tab list's order (hosts in host order) |
| ⌘W | Close the focused block. A session's last block leaves it empty; ⌘W on an empty session ends it through Tern's own command, so the close confirmation and locks still apply |
| ⌘⇧W | Close the current session, never a host's default |
| ctrl+alt+shift+R | Rename the tab in a terminal or agent block; in other views, run that view's ⌘R action (a browser reloads) |
| ctrl+alt+shift+C | Open the block note in a terminal or agent block; in other views, run that view's ⇧⌘C action |

An empty session stays open on ⌘W when it has parked blocks, when it is the host's only session, or when it is the
host's default.

**Default spaces:** the palette command "스페이스: 지금 스페이스를 이 기기의 기본으로 고정" pins the current session as
its host's default. A default stays first among that host's sessions and neither close ends it. The pin keeps the
session's id, so renaming the session keeps it pinned.

## Setup

```sh
tern plugin install github.com/nahwan-kim/tern-herdr-keys
# or, from a clone: tern plugin link .
```

- **⌘N:** plugin keys cannot take this Tern default, so map it in `settings.json`:
  `"keybinds": { "cmd+n": "new_session" }`.
- **⌘R and ⇧⌘C:** Tern's text input takes these before its keymap. A Karabiner rule active while Tern is frontmost
  sends them as ctrl+alt+shift+R / ctrl+alt+shift+C.

## License

MIT
