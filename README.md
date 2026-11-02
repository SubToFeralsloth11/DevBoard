# DevBoard

A small liquid-glass island that sits in the middle of your Mac's menu bar, level with the clock and the File / Edit menus. It shows your omp agents working, your next class and DayMap tasks, holds files you're moving between apps, captures your screen (screenshots, recordings, instant replay) and keeps an eye on memory.

## The island

- **Compact:** sits inside the menu bar. Shows how many agents are working, then (in order) a running recording, instant replay, or your DayMap headline: the class you're in, the next class within 90 minutes, or the nearest task due in the next two days. Memory used and shelf count are on the right.
- **Hover:** it grows downward into a bar with Agents, School, Files, Monitor, Clips, Screenshot, Record, Save replay and Settings. If the shelf has files, they appear in a strip under the bar, ready to drag out.
- **Drop files:** start dragging files anywhere and the island turns into a drop zone. Drop them and they go on the shelf. Switch apps, hover the island, and drag them back out.
- **Toasts:** saved clips, screenshots, finished agents and DayMap reminders briefly appear in the island. Click one to open it.
- **Right-click:** a menu with more options, including syncing DayMap, hiding the island and quitting.

## Board tabs

| Tab | What it does |
|---|---|
| Agents | A live "screen" for every recent omp session: what it is thinking, which tool it is running, the last output, an activity graph, tokens and cost. Subagents are nested under their parent. Click a card for the full feed and shortcuts to open the project. |
| School | Your classes for today (or the next school day) and every DayMap task, grouped into overdue, this week, later and handed in. Click a task to open it in DayMap inside DevBoard. |
| Files | The shelf (drop zone, drag out, double-click to open) and a quick Spotlight file-name search over your home folder and Applications. ↑↓ and ⏎ work; results can be dragged out or onto the shelf. |
| Monitor | CPU, memory, memory pressure, swap and network graphs. Memory use is grouped by app (Chrome helpers count as Chrome), processes paused by ram-guard are flagged, and you can quit an app in two clicks. |
| Clips | Your screenshots and clips. The editor trims with the native QuickTime trimmer and has 11 filter presets, exposure/contrast/saturation/warmth sliders, mute, export, GIF export, copy, share and drag-out. |
| Settings | DayMap address and reminders, replay length, quality, frame rate, display, audio, microphone, cursor, agent window, open at login. |

## DayMap

DayMap has no public API and signs in through Microsoft, so DevBoard signs in the way your browser does. Click **Sign in to DayMap** (School tab or Settings). A DevBoard window opens your timetable; sign in once. After that, a hidden web view with the same session syncs every 20 minutes, on wake, and when you open the School tab:

- **Tasks** come from `student/assignments.aspx` (every page of the task grid).
- **Classes and diary events** come from `DWS/Diary.ashx`, the feed DayMap's timetable page uses, for yesterday through the next three weeks.

Reminders appear in the island once each: a new task when it is posted, a task the afternoon before (3:30 pm) and the morning (7:30 am) it is due, and each class 5 minutes before it starts. Both kinds can be turned off in Settings.

The last sync is cached in `~/Library/Application Support/DevBoard/daymap.json`, so the island has your data straight after launch. Your password is never stored. DayMap's session cookie is kept in `daymap-session.plist` in the same folder (readable only by you) so a relaunch doesn't sign you out. **Sign out** in Settings removes both and clears the DayMap and Microsoft cookies.

## HTML previews

Double-click an `.html` file (or a folder with an `index.html`) on the shelf or in search, or choose **Open in DevBoard**. It opens in a DevBoard browser window that can read the whole project: the nearest folder above the page with `.git`, `package.json`, `project.godot` or a Vite config, otherwise the page's own folder. Relative CSS, JS, images, `fetch()` of local files and ES modules all load. The page reloads when any file in the project changes (turn off **Live reload** to stop that), and right-click → **Inspect Element** opens Web Inspector.

## Shortcuts

| Keys | Action |
|---|---|
| ⌥⇧D | Open / close the board |
| ⌥⇧A / ⌥⇧L / ⌥⇧F | Agents / School / Files (focuses search) |
| ⌥⇧M / ⌥⇧C | Monitor / Clips |
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
