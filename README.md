# DevBoard

A small liquid-glass island that lives at the top of your Mac's screen. It shows your omp agents working, captures your screen (screenshots, recordings, instant replay) and keeps an eye on memory.

## The island

- **Compact:** how many agents are working, whether instant replay is armed or a recording is running, and memory used.
- **Hover:** it expands into a bar with Agents, Monitor, Clips, Screenshot, Record, Save replay and Settings.
- **Toasts:** saved clips, screenshots and finished agents briefly appear in the island. Click one to open it.
- **Right-click:** a menu with more options, including hiding the island and quitting.

## Board tabs

| Tab | What it does |
|---|---|
| Agents | A live "screen" for every recent omp session: what it is thinking, which tool it is running, the last output, an activity graph, tokens and cost. Subagents are nested under their parent. Click a card for the full feed and shortcuts to open the project. |
| Monitor | CPU, memory, memory pressure, swap and network graphs. Memory use is grouped by app (Chrome helpers count as Chrome), processes paused by ram-guard are flagged, and you can quit an app in two clicks. |
| Clips | Your screenshots and clips. The editor trims with the native QuickTime trimmer and has 11 filter presets, exposure/contrast/saturation/warmth sliders, mute, export, GIF export, copy, share and drag-out. |
| Settings | Replay length, quality, frame rate, display, audio, microphone, cursor, agent window, open at login. |

## Shortcuts

| Keys | Action |
|---|---|
| ⌥⇧D | Open / close the board |
| ⌥⇧A / ⌥⇧M / ⌥⇧C | Agents / Monitor / Clips |
| ⌥⇧S | Screenshot (region; press Space to pick a window) |
| ⌥⇧R | Start / stop recording |
| ⌥⇧X | Save the last 30 s (instant replay) |
| ⌥⇧H | Hide / show the island |

## Memory use

- **Replay buffer:** it is hardware-encoded (H.264) into 5-second files on disk, never into RAM. Saving a replay or finishing a recording joins those files without re-encoding.
- **Capture:** it uses the YUV 4:2:0 pixel format with a 4-frame queue.
- **Agent transcripts:** they are read incrementally, and only the last 80 lines per agent are kept.
- **Process scan:** it only runs while the Monitor tab is open. Otherwise DevBoard checks two kernel counters every 3 s.
- **Thumbnails:** they are small and held in a bounded cache.

## Build

Requires macOS 26 and the Swift 6.2+ command line tools. Xcode is not needed.

```
scripts/build-app.sh          # release build, sign, install to /Applications
open /Applications/DevBoard.app
```

On first launch macOS asks for **Screen Recording** permission. Turn it on for DevBoard in System Settings → Privacy & Security, then relaunch. The build script signs with a local self-signed identity called "DevBoard Local Signing", if one exists in your keychain, so the permission survives rebuilds.

Files are saved to `~/Movies/DevBoard/{Clips,Screenshots}`.
