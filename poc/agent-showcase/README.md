# Agent showcase (POC)

Proof of concept for the "scripted mode" in `docs/ideas/2026-10-12-pubbles-for-agents.md`:
an agent reviews a page, writes a showcase script, and this player performs it, recording the
page window itself or alongside the user's own recorder (Screen Studio, CleanShot, …).

It needs a Pubbles build from this branch: Pubbles is driven through its agent control channel
(`Sources/Pubbles/AgentControl.swift`), never its hotkeys.

```bash
swift run showcase --dry                          # open the page, check every target, touch nothing
swift run showcase                                # ghost mode + built-in recording (defaults)
swift run showcase --mode drive                   # real cursor instead of the ghost (hands off)
swift run showcase --recorder external            # you run Screen Studio etc. yourself
swift run showcase path/to/other.json
```

A take waits for **Return** (a bubble asks for it), counts down 3-2-1, then plays. **Esc** stops it
at any time and stops the recording too (the partial video is kept).

- **ghost** (default): Pubbles draws its own pointer and the bubble follows it; doodles go to
  Pubbles as strokes; the page gets hover, clicks, wheel and keys over DevTools. Your mouse and
  keyboard stay free (just don't click into or cover the window).
- **drive**: the real cursor moves, clicks and scrolls; moving the mouse aborts.
- **builtin** recorder: `screencapture -v` of exactly the page window to `~/Movies/Pubbles/`
  (system cursor left out in ghost mode).

Needs Accessibility (and Screen Recording, for the built-in recorder) for the terminal, Pubbles
running, and Google Chrome (a separate app-mode window with its own profile).

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
| `circle`, `underline` | `target`, `pad`, `duration` | doodle (bubble comes on if needed) |
| `arrow` | `target`, `anchor`, `from: [dx, dy]` | doodled arrow pointing at the target |
| `scroll` | `target` + `align`, or `by` | eased wheel scroll |
| `click` | `target`, `anchor`, `offset` | click |
| `type` | `text` | type into the page |
| `key` | `key` (escape, return, space, tab, pageup, pagedown, up, down) | key into the page |
| `wait` | `seconds` | hold still |

Rules the player enforces (and reports as actionable errors):

- Doodles and pins stay fixed on screen, not on the page: doodles are cleared automatically
  before a scroll; pins left up during a scroll are an error.
- Drive mode only: while the bubble is on, Pubbles owns the keyboard, so `type` and `key` need a
  `hide` first. Clicks and scrolling pass through the bubble.
