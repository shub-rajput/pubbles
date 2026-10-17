# Agent showcase (POC)

Proof of concept for the "scripted mode" in `docs/ideas/2026-10-12-pubbles-for-agents.md`:
an agent reviews a page, writes a showcase script, and this player performs it with the real
cursor while the user records with their own recorder (Screen Studio, CleanShot, …).

It drives the installed Pubbles through its normal hotkeys. No app changes.

```bash
swift run showcase --dry            # open the page, check every target, touch nothing
swift run showcase --countdown 5    # real take; start your recorder during the countdown
swift run showcase path/to/other.json
```

Move the mouse yourself at any point to abort. Needs Accessibility permission for the terminal,
Pubbles running, and Google Chrome (a separate app-mode window with its own profile is used).

## Script format

`scripts/pubbles-app.json` is the pubbles.app tour. Targets are CSS selectors or
`text:Some words` (innermost visible element containing them), resolved live just before each
step, after scroll-reveal animations settle.

| `do` | fields | what happens |
| --- | --- | --- |
| `point` | `target`, `anchor`, `offset` | spring-eased glide to the target |
| `say` | `text` (`\n` = new line) | bubble on if needed, then type into it |
| `newline`, `clear` | | Return / Cmd+Delete in the bubble |
| `pin` | | Cmd+right-click; a fresh bubble stays open |
| `hide` | | bubble off (keeps pins) |
| `dismiss` | | Esc: bubble and all pins gone |
| `circle`, `underline` | `target`, `pad`, `duration` | hold-Cmd doodle |
| `arrow` | `target`, `anchor`, `from: [dx, dy]` | doodled arrow pointing at the target |
| `scroll` | `target` + `align`, or `by` | real trackpad-style wheel events |
| `click` | `target`, `anchor`, `offset` | real click |
| `type` | `text` | type into the page (bubble must be off) |
| `key` | `key` (escape, return, space, tab, pageup, pagedown, up, down) | key into the page (bubble must be off) |
| `wait` | `seconds` | hold still, with a little drift |

The one rule: while the bubble is on, Pubbles owns the keyboard, so `type` and `key` need a
`hide` first. Clicks and scrolling pass through the bubble.
