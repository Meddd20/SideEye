# Sideeye 👁️

**Ambient window overlay for macOS** — mirror any window you already have open as a translucent, click-through layer that floats quietly above your work.

A livestream in the corner. A reference doc you glance at. A video call you keep an eye on. Sideeye takes _any_ window and turns it into a ghost of itself: visible, but out of the way — visually (opacity) and physically (your clicks pass straight through it).

It also leans into a small human truth: some people focus better when _something_ is quietly present — the "body doubling" effect — without having to schedule a call with another person to get it.

## Features

- **Mirror any window** — pick from the menu bar; the list is grouped into _This Workspace_, _Full-Screen Workspaces_, and _Other Workspaces_ (every mirrorable window stays reachable)
- **Live overlay** — real-time capture via ScreenCaptureKit, composited on the GPU, always on top, visible on every Space/full-screen app
- **Opacity slider** — tick marks at 0 / 25 / 50 / 75 / 100%, a live percentage readout, and a 5% floor so a low mirror can never be dialed into true invisibility
- **Peek hotkey** — hold <kbd>⌘ Command</kbd> + <kbd>⌥ Option</kbd> and the overlay jumps to 100% opacity; release and it drops back to the slider's value — or tap <kbd>⌘⌥3</kbd> to keep it lit without holding anything. The "where did it go?" rescue for when the mirror is dialed down and you can't find it
- **Hide hotkey** — tap <kbd>⌘⌥2</kbd> to hide the mirror; tap again to bring it back. The capture stream keeps running while hidden, so showing it again is instant. While hidden, the menu also offers **Show Mirrored Window**
- **Click-Through toggle** — a checkmark, not a mystery: ✓ means your clicks pass through the mirror to the windows behind it; unchecked means the mirror accepts clicks (so you can drag/resize it). Starts **on**
- **Drag & resize** — background-drag to move, invisible edge zones to resize (while click-through is off)
- **Remembers where you left it** — every drag, resize, and opacity change is auto-saved; stop mirroring (or quit and relaunch) and the next mirror — whichever app's window you pick — lands right back in the same size and place
- **Saved Preferences** — name a look per app; once saved, it becomes that app's default and auto-applies whenever that app is mirrored. Apply, rename, overwrite, or delete any time from the menu
- **One mirror at a time, zero recording** — the feed is live and temporary; video frames are never stored. The only things saved are your mirror preferences (size, place, opacity, click-through) and the names you give them

## Requirements

- macOS 13.0 or later
- Xcode 15+ (to build from source)

## Permissions — and why

Sideeye asks for up to two permissions, and being open source is the point: you can read exactly what each one is used for.

| Permission           | Used for                                                                 | What it is NOT used for                                                                                             |
| -------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| **Screen Recording** | Capturing the one window you chose to mirror                             | Nothing else. No screenshots are taken, no frames are stored — the feed goes straight to the overlay and dies there |
| **Accessibility**    | The peek hotkey (a listen-only event tap that watches for ⌘⌥ being held) | Reading anyone's keystrokes or content. The tap observes modifier state only and never swallows a key                |

Only the **peek** hotkey needs Accessibility. The <kbd>⌘⌥2</kbd> hide hotkey and the <kbd>⌘⌥3</kbd> peek latch use the system global-hotkey API and need no permission at all.

Without Accessibility, peek simply stays dormant — the menu swaps the hotkey hint for _"Peek: allow Sideeye in Accessibility settings"_ so it never fails silently. The hide hint is always shown, since it never degrades.

## Build from source

```bash
git clone https://github.com/<you>/sideeye.git
cd sideeye
swiftc -O -o sideeye \
  AppDelegate.swift CaptureEngine.swift MirrorPreferences.swift OverlayWindow.swift \
  PeekManager.swift SCWindow+Extensions.swift StatusMenuController.swift \
  SystemHotkeys.swift WindowListManager.swift main.swift
```

That produces a working binary. For the proper menu-bar experience (no Dock icon), wrap it in an app bundle with an `Info.plist` containing:

```xml
<key>LSUIElement</key>
<true/>
```

Or simply add the sources to an Xcode "App" project with **Application is agent (UIElement)** checked in the target's Info tab.

## Usage

1. Click the eye icon in the menu bar
2. **Mirror a Window…** → pick any window
3. Drag the overlay where you want it, dial the opacity down until it's ambient
4. Leave **Click-Through** on so it never blocks your clicks; untick it only when you want to grab/resize the mirror
5. Lost it? Hold <kbd>⌘⌥</kbd> to light it up (tap <kbd>⌘⌥3</kbd> to keep it lit without holding)
6. Need it out of the way for a moment? Tap <kbd>⌘⌥2</kbd> to hide it, tap again (or **Show Mirrored Window**) to bring it back
7. **Stop Mirroring** when you're done

Once you've positioned the mirror, Sideeye remembers it — as one global look, not per app: the next mirror, of ANY app's window — after Stop Mirroring, or even after quitting and relaunching — reopens with the same size, place, opacity, and click-through as the look you last left it in. When the next source has a different shape, the height stays exactly as saved and the width follows the new shape — anchored to the side of the screen the mirror hugs: tucked right, it reflows leftward; tucked left, it reflows rightward; centered, it reflows symmetrically. A brand-new setup (nothing remembered yet) still starts visible and centered, and interactive (click-through off) so you can drag it into place first.

### Saved Preferences

The **Saved Preferences** section only appears while a mirror is running, and everything in it belongs to the app being mirrored:

- **Save Current as Preference…** — snapshots the live look (size, place, opacity, click-through) under a name you choose
- Each saved preference gets its own submenu: **Apply** (put it on the mirror now — and it becomes the default), **Set as Default** (mark it as the app's default without moving the live mirror), **Rename…**, **Update with Current** (overwrite the snapshot with the mirror's look right now), **Delete** (confirmed)
- The default is always marked with a ✓ in **two** places: next to the governing snapshot in the list, and beside **Set as Default** inside its submenu. No ✓ anywhere means no snapshot governs the app and the global remembered look applies instead
- **Reset to Default Style** — clears this app's saved default *and* the global remembered look, kicking the mirror back to the centered first-run default; named snapshots are kept
- The ✓ marks the snapshot that currently **governs its app**: it auto-applies every time that app is mirrored, and stays marked through minor tweaks until you Delete or Reset it. Use **Update with Current** to absorb your latest tweaks into the snapshot

How the two layers cooperate: an app with a saved preference always reopens in **its** snapshot (that's the set-it-once, never-again default); an app without one reopens in the global remembered look — so your earlier repro (save on Brave, stop, mirror QuickTime) now lands QuickTime exactly where the mirror last was.

## How it works

```
Source window ──SCStream──▶ CaptureEngine ──CMSampleBuffer──▶ MirrorView
                              │                    (AVSampleBufferDisplayLayer, GPU)
                              ▼
                        OverlayWindow
              borderless · floating · clear background
              alphaValue = opacity · ignoresMouseEvents = click-through

hotkeys ──▶ CaptureEngine ──▶ OverlayWindow
  hold ⌘⌥   (PeekManager)    alphaValue → 1.0 while held
  tap  ⌘⌥2   (SystemHotkeys)  orderOut / orderFront (stream keeps running)
  tap  ⌘⌥3   (SystemHotkeys)  latch alphaValue → 1.0 without holding
```

- **CaptureEngine** owns the ScreenCaptureKit stream and all overlay state (opacity, click-through, peek, hidden) — the single source of truth the menu reads from
- **OverlayWindow** is a borderless, floating `NSWindow` with a clear background; transparency is `alphaValue`, click-through is `ignoresMouseEvents`
- **MirrorView** backs an `AVSampleBufferDisplayLayer` — frames are enqueued straight from the capture callback, no CPU copies
- **PeekManager** runs a listen-only `CGEventTap` on modifier changes; "the keybind" is one boolean expression: _are ⌘ and ⌥ both held right now?_
- **SystemHotkeys** registers Carbon global hotkeys (⌘⌥2 hide/show, ⌘⌥3 peek latch) — no Accessibility grant needed, and they swallow the keystroke so the chord never leaks into the focused app

## Project structure

| File                         | Role                                                                           |
| ---------------------------- | ------------------------------------------------------------------------------ |
| `main.swift`                 | Entry point — boots `NSApplication`                                            |
| `AppDelegate.swift`          | Wires everything together, sets accessory (menu-bar-only) policy               |
| `StatusMenuController.swift` | The menu bar UI: two menu shapes, opacity control, click-through toggle, hints |
| `CaptureEngine.swift`        | Stream lifecycle + the state every control reads from                          |
| `MirrorPreferences.swift`    | Per-app remembered looks + the screen math that turns saved fractions into a clamped window frame |
| `OverlayWindow.swift`        | The floating overlay window + `MirrorView` frame sink                          |
| `PeekManager.swift`          | The ⌘⌥ peek hold (listen-only event tap)                                       |
| `SystemHotkeys.swift`        | The ⌘⌥2 hide/show and ⌘⌥3 peek latch (Carbon global hotkeys)                    |
| `WindowListManager.swift`    | Refreshes and partitions the mirrorable window list                            |
| `SCWindow+Extensions.swift`  | Display names, mirrorability filtering, fullscreen detection                   |

## Limitations & known issues

Honest list, current as of this build:

1. **The mirror is a passive copy** — you can't click, scroll, or type into it. With Click-Through on, your clicks pass to whatever is _behind_ the overlay; with it off, clicks land on the overlay itself (drag/resize). To actually use the source window, switch to it and interact there. A true "interactive mirror" isn't realistically buildable — macOS offers no reliable way to forward a click to a background window that may be occluded — so this is a platform limit, not a missing feature.
2. **Full-screen media players on another Space** — the audio keeps playing, but the mirror shows a stuck, blurred frame instead of the video. ScreenCaptureKit can't deliver that window's content while it's fullscreen there.
3. **Opacity is the only legibility knob** — if the mirrored content has low contrast against what's behind it, the only fix is raising the opacity. There's no border, shadow, or tint yet to help the mirror stand out.
4. **Click-Through ON means no moving or resizing** — the whole background is the drag handle, so it only works while Click-Through is off. Toggle it off, reposition, toggle back.
5. **Minimized source → frozen mirror** — capture pauses while the source window is minimized; the overlay holds the last frame until the window is restored.
6. **Source resizes aren't followed** — the stream is configured with the source's size when mirroring starts; resizing the source afterwards letterboxes the mirror instead of re-framing.
7. **Mirrored content can appear twice** — bring the source window to the front and the overlay stays on top of it, so you see the same thing twice. (Workaround: tap <kbd>⌘⌥2</kbd> to hide it.)
8. **The cursor isn't mirrored** — capture runs with `showsCursor = false`, so the source's mouse pointer never appears in the mirror.
9. **One mirror at a time, video only** — by design for v1: no audio capture, no multi-window mirroring.

## Roadmap

Improvements planned from the internal PRD plus fixes for the limitations above:

- [ ] **Auto-hide when frontmost** — overlay hides while you're actually using the source window, so nothing is shown twice _(fixes #7; a manual hide hotkey has shipped)_
- [ ] **Remote pause** — send a spacebar keypress to the source app without switching focus to it
- [ ] **Panic hotkey** — one shortcut that instantly restores full visibility, full opacity, and interactivity. (The manual hide/show toggle ships; a true "reset everything" panic key doesn't yet)
- [ ] **Preset positions** — snap the overlay to corners/center from the menu; every new session still starts centered by design
- [ ] **Follow source resizes** — reconfigure the stream when the source window changes size _(fixes #6)_
- [ ] **Mirror a region of a window** — show only a chosen rectangle of the source (say, just the video canvas inside a browser) instead of the whole window. ScreenCaptureKit ignores `sourceRect` for single-window capture, so this is a display-time crop: capture the whole window as usual at native resolution, then clip/offset the video layer so only the chosen region is visible. Quality stays exactly as sharp as the source — nothing is rescaled. Depends on _Follow source resizes_ to keep the overlay's shape correct.
- [ ] **Legibility aids** — optional border/shadow/tint so low-contrast mirrors stay readable at low opacity _(fixes #3)_
- [ ] **Fullscreen media-player capture** — investigate what ScreenCaptureKit can and can't deliver there _(fixes #2)_

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
