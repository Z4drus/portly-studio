# Portly Studio

**A vibecoding cockpit built on top of [Portly](https://github.com/Melvynx/portly).**

Portly supervises local development servers on macOS: every command runs in a real interactive PTY,
its port is checked, and it comes back after a crash. Portly Studio keeps all of that and turns the
app into the place you actually code from — a project sidebar where each project holds split
terminals running Claude Code, Codex, Cursor Agent or Gemini CLI, and a live readout of how much of
each assistant's limit you have already burned.

Three things, in one native app:

- **Supervised dev servers** — Portly's original job, unchanged.
- **Coding sessions** — persistent split terminals per project, with agent presets, resumed
  conversations, a scratch shell, an `.env` editor and a keep-awake mug.
- **AI usage statistics** — one ring per assistant, in a screen-edge notch, in the sidebar and in
  the menu bar, with every limit window and its reset time.

macOS 14 or newer, Apple silicon or Intel. macOS only.

---

## Install

### Download

Grab the latest `Portly-Studio-macOS.zip` from
[Releases](https://github.com/Z4drus/portly-studio/releases/latest), unzip it, and move
**Portly Custom.app** to `/Applications`.

The build is signed ad-hoc rather than notarized by Apple, so macOS quarantines the download. Clear
the flag once:

```bash
xattr -dr com.apple.quarantine "/Applications/Portly Custom.app"
open "/Applications/Portly Custom.app"
```

The app lives in the menu bar. Its onboarding card installs the `portly` CLI and the agent skill,
and points at the Full Disk Access and Accessibility toggles — grant them and the agents Portly
starts inherit them.

Because the signature is ad-hoc, macOS treats each new version as a different app and asks for those
two permissions again after an update.

### Build from source

```bash
git clone https://github.com/Z4drus/portly-studio.git
cd portly-studio
./build.sh --run
```

`build.sh` builds and signs the bundle, installs `/Applications/Portly Custom.app`, drops the
`portly` CLI in the first writable bin directory on `PATH`, installs the bundled skill in
`~/.agents/skills/portly`, adds marker-delimited Portly rules to `~/.agents/AGENTS.md`, and launches
the app. Reinstalling quits the running app first, which stops every supervised server.

`build.sh` asks SwiftPM for its native build engine. The newer default engine compiles SwiftTerm's
Metal shaders and fails on a Mac without Xcode's separately downloaded Metal Toolchain; run
`swift build --build-system native` and `swift test --build-system native` by hand for the same reason.

- `./build.sh --no-install` assembles `dist/Portly Custom.app` without installing it.
- `./build.sh --release` produces the universal, ad-hoc signed `dist/Portly-Studio-macOS.zip`.
- `./build.sh --forever` also registers the LaunchAgent, so Portly starts at every login.

When a Developer certificate is present, the local build signs with it so the Full Disk Access and
Accessibility grants survive rebuilds. The release archive never uses it: an ad-hoc signature keeps
the maintainer's Apple ID and team identifier out of every downloaded copy.

---

## The coding cockpit

- **Coding sessions per project** — each project holds several sessions; a session is 1 to 5
  terminals split right or down (⌘D / ⇧⌘D), resizable, zoomable (⇧⌘↩), with per-session text size
  (⌘+ / ⌘−). Layouts persist in `~/.config/portly/studio.json` and shells respawn when a session is
  reopened.
- **Agent presets** — a new terminal starts Claude Code (bypass permissions by default), Codex,
  Cursor Agent, Gemini CLI, a custom command, or a bare shell. Settings → Code.
- **A sidebar in your order** — drag a project header to move it (or *Move Up* / *Move Down* in its
  right-click menu); the order is kept across launches. A server that starts, by hand or on its own,
  puts its project at the top, and it stays there once the server stops. Each header carries the
  number of servers and sessions it holds when collapsed, and a **+** that opens a new coding session.
- **Archive** — right-click a project and choose *Archive Project* to take it out of the sidebar. A
  project with no server started, no session opened and no agent at work for a day archives itself
  (Settings → Code → Sidebar: a day, 3 days, a week, a month, or never). Archived projects wait behind
  the button left of the search field: a searchable list, and picking one brings it back to the top
  with a coding session open on it; its right-click menu also brings it back without opening
  anything. Archiving is state, not a date recomputed at launch: an archived project stays archived
  until you bring it back or one of its servers starts. "Worked on" means a real exchange in a Claude
  conversation, not the bookkeeping Claude Code appends to a transcript every time it is resumed.
- **Relaunch** — the sessions of the projects in the sidebar respawn at launch and the last selection
  comes back; an archived project respawns its sessions the moment one is opened. Claude Code panes
  carry a session id (`--session-id`) and resume their conversation (`--resume`) after a quit or a
  reboot; a *Reset* button in the pane header starts a fresh chat.
- **Resume notes** — quitting Portly ends the agents it runs, including one that is busy replacing
  Portly itself. A one-line note left in `~/.config/portly/resume-notes.json`, keyed by Claude
  conversation id (`{"<id>": "The new build is installed, verify it."}`), is handed to that
  conversation as its first message when it resumes, and deleted as it is read.
- **Option composes characters** — ⌥ types what your layout says it types (`{ } [ ] @ | ~ #` on
  Swiss, German, French and other ISO layouts) instead of acting as Meta. It stays Meta for the keys
  that produce no character, so ⌥← / ⌥→ and ⌥⌫ still move and delete by word.
- **Workspace trust** — Claude Code asks "Is this a project you created or one you trust?" the first
  time it runs in a folder, and there is no flag to skip it. Creating a project in Portly answers it
  in advance by writing the same key its dialog writes
  (`projects["<real path>"].hasTrustDialogAccepted` in `~/.claude.json`), preserving every other byte
  of that file, so a new project opens straight on a prompt. Settings → Code has the toggle and an
  *Approve every project now* button for older projects.
- **PATH** — launched from the Dock, macOS gives an app almost no PATH. Portly asks your interactive
  login shell once and hands its PATH (pnpm, bun, fnm…) to every server, terminal and install it
  starts.
- **Terminal titles** — the pane header follows the OSC title the CLI sets (Claude Code names its
  tasks) and the working directory.
- **Free terminal** — the *Terminal* button at the foot of the sidebar opens a terminal that belongs
  to no project: tabs along the top, iTerm-style, each a login shell starting in your home folder.
  Close a tab from the cross on its left, double-click to rename it, drag to reorder, ⌘T for a new
  one, ⌘1–⌘9 to jump, ⌘] / ⌘[ to cycle. A tab remembers the folder it was in and reopens there after
  a relaunch. Run anything in it, Claude Code included.
- **Agent launch screen** — a new agent terminal hides the shell prompt and the command it types
  behind a small launch screen until Claude Code has drawn its first screen: the mascot, a pixel
  loader, and whether the chat is new or resumed. It lifts as soon as the agent is ready (its title,
  or output settling), on any key you press, and after ten seconds no matter what.
- **Quick terminal** — one scratch shell per project, floating top-right, toggled with ⌘J from any
  screen.
- **Environment files** — every `.env*` at the project root in a floating panel (⇧⌘E) with dotenv
  colouring (keys, strings, comments, `${vars}`, unclosed quotes flagged), plus "create `.env` from
  `.env.example`" and the reverse.
- **Git at a glance** — left of the mug, on every screen of a project whose folder is a
  repository: the branch glyph, the lines added and removed since the last commit (green and
  red), and how many commits wait to be pushed. The popover below it lists the changed files
  with their status mark and line counts, greys out the `.env*` files Git ignores, and draws the
  recent history as a lane graph: filled dots are on a remote, hollow ones are still only here,
  branch names ride along as badges. Nothing in it drives Git; one button types the request you
  make several times a day into the focused terminal, *commit and push everything, including the
  changes that are not yours*, and the agent does it. The readout refreshes when files change under
  the project (FSEvents, build folders ignored), every 20 s as a safety net, and whenever it opens.
- **Talvo** — Bleeze's own project tool (projects, milestones, issues, documents, Linear-style)
  mirrored in Portly, for a Portly linked to a Talvo server. Settings → Talvo takes the server
  address and a per-device token created in Talvo (*Appareils* in the account menu); the token lives
  in the keychain and nothing of it is in the repository, so a public build has no Talvo at all.
  Once connected, a Talvo button at the left of the toolbar links the project on screen to one of
  your Talvo projects and then shows its name, its open and urgent issues and its health. Clicking it
  covers the detail area with the project: issues by status with search and filters (open, mine,
  urgent), the selected issue in full (properties, Markdown description, sub-issues, relations,
  links, comments, activity), and the project tab (description, milestones with progress, members,
  links, updates, documents). A token with the write scope can change an issue's status and comment;
  *Tell the agent* hands an issue to the focused terminal by its identifier. Changes made in Talvo
  show within a second: Portly keeps one event stream open, Talvo sends a sequence number per change,
  and Portly fetches only what moved since the one it holds, a few kilobytes an hour. A copy of the
  light records waits in `~/.config/portly/talvo-cache.json` so a relaunch asks for a delta, not the
  whole workspace; long texts are read when opened.
- **Keep awake** — the mug in the toolbar arms it, and it stays armed across launches. It holds the
  Mac awake whenever an agent works — a Claude Code session anywhere on the Mac whose own status says
  `busy` (`~/.claude/sessions/<pid>.json`), or a Portly terminal producing output — lets go once
  every agent has been idle for N minutes, and holds again as soon as one starts. While holding: a
  power assertion stops idle sleep, a second one keeps the screen on (optional), and
  `pmset disablesleep`, with an administrator, keeps a closed lid from cutting Wi-Fi and the agents.
  With the lid closed and no other screen connected, the built-in screen is put to sleep (dimmed to
  its minimum if it stays lit, brightness restored when the lid opens), the agents keep working, and
  the Mac is sent to sleep once they are done. It also lets go after 90 s offline, under 10 %
  battery, and always on quit. The first activation asks for your password once to install a sudo
  rule limited to those two `pmset` commands.
- **Activity** — a spinner next to a session while any of its terminals produces output, a dot once
  it went quiet and you have not looked yet. Claude Code's animated title glyph is stripped.
- **Drop zone** — drop files anywhere on a project screen to copy them to its root, then
  *Tell the agent* types the file list into the focused terminal.
- **Plain dev commands** — *Add Server* suggests the project's scripts as everybody types them
  (`pnpm run dev`, `npm run dev`, `bun run dev`, `yarn run dev`, from the lockfile) with a free port.
  The port is never written into the command: Portly exports `PORT`, and adds `--port` when it spawns
  a bare script that starts Vite, Astro, SvelteKit, React Router, Angular or Expo, which ignore it.
- **Dependencies** — a Node server whose `node_modules` is missing shows an *Install dependencies*
  button (pnpm, bun, yarn or npm, detected from the lockfile) and greys out *Start* until the install
  finishes.
- **Icons and colours** — Nucleo glyph-duo icons everywhere, a project icon picker that searches
  3 400 glyphs in French or English, and a twenty-colour project palette.

## AI usage

How much of each coding assistant's limit you have burned, read from the credential the tool already
holds on the machine — Claude Code's keychain token by default; Codex, Cursor and Grok are opt-in in
Settings → AI Usage. Nothing is sent anywhere except to each vendor's own usage endpoint.

Claude Code's token is read the way Claude Code reads it, through `/usr/bin/security`. That is what
keeps macOS from asking: a keychain item only answers the applications on its access list, Claude
Code files a new item at every token rotation, and the application on each new list is `security`.
Read directly, the item prompted again every hour however often *Always Allow* was chosen.

A black notch on a screen edge shows one ring per assistant and unfolds on hover, with a tooltip
listing every limit window — Claude's current session, the all-models week, and per-model weekly
windows such as Fable — and when each resets. Clicking a ring refreshes it. The same readings sit in
a collapsible section just above *Resources* in the sidebar, and as rows in the menu bar popover.

Settings → AI Usage chooses which of the three surfaces to use, which window the ring follows
(current session, or the one closest to its limit), whether per-model weekly windows are listed, and
whether live sessions show. A thin arc turns inside the Claude ring while a Claude Code session is
working anywhere on the Mac, and goes amber when one is waiting for you.

Adapted from [Codenotch](https://github.com/vinzdg/codenotch) (MIT).

## Supervised servers and resources

Everything Portly does, kept as-is.

Projects hold long-lived, reusable services. Builds, tests, previews and other one-off commands are
**temporary jobs**, made for agents and kept out of the sidebar: `portly temp 'pnpm run build'`
starts the command in its own PTY and prints a job id, `portly wait <id>` blocks until it ends, prints
the captured output and exits with the command's own code (`124` after a timeout, which kills the
whole process group), `portly logs <id>` peeks meanwhile, `portly jobs` lists them and
`portly stop <id>` ends one early. `--port` exports `PORT` to a short preview server and refuses a
busy port. Jobs never persist; a finished one stays readable for an hour.

A busy configured port makes the server start on the next free one (`PORT` and an explicit
`-p`/`--port` are rewritten), with a banner to take the configured port back; every port the process
tree listens on shows in the sidebar and in the Open menu.

Two projects may be configured on the same port. Old projects pile up, and the one that used 3000
months ago should not keep it from everything since: `add-server` and `update-server` only refuse a
port that another Portly server holds *right now*. Whichever of the two starts second is handled as
any busy port is.

The native **Resources** screen opens on **This Mac**: live charts, two per row, of the whole
machine rather than Portly alone, sampled every second while the screen is visible and never
otherwise. CPU (user / system, every core grouped by performance and efficiency cluster, load
average), memory (app, wired, compressed, cached, pressure, swap), GPU (device, renderer and tiler
utilization, memory in use), network (download and upload, totals since the screen opened), disk
(read / write throughput, IOPS, free space), chip, SSD and battery temperatures on Apple silicon, and
power (battery, health, cycle count, adapter, system draw, thermal state). The readings follow
[exelban/stats](https://github.com/exelban/stats); a source a Mac does not offer hides its card
rather than showing zeros.

Below it, the **Portly** section samples every Portly-owned process tree every two seconds and keeps a
five-minute memory history: physical footprint, resident RAM, CPU, project trends, and the current
user's heaviest processes running outside Portly. The optional global project limit and the
per-project inherit / off / custom overrides live in **Settings → Memory**. A project restarts after
three consecutive over-limit footprint samples, then sampling starts fresh on the replacement
processes.

Those measurements turn into machine-aware recommendations rather than one fixed limit: unusually
large servers and processes, sustained growth while ignoring isolated build spikes, and duplicate dev
sessions outside Portly. Advice is tailored to common Next.js, Vite, Node, TypeScript, browser,
Docker, Redis and Postgres failure modes. Managed servers can be restarted or stopped from the
recommendation card. External process cards show the validated stop target, parent, working
directory, listening ports, and the gap between footprint and resident RAM; an explicit confirmation
can send `SIGTERM`, but Portly never terminates them automatically and never escalates to `SIGKILL`.

When Docker Desktop owns a published host port, Portly resolves the actual container through the
Docker CLI, so **Stop** and **Move to Portly** act on that container instead of signalling the global
`com.docker.backend` process.

---

## CLI

Every CLI command launches Portly automatically when it is closed. `status` is compact by default:
only active servers and problems. Use `--details` for the full human inventory and `--json` for
complete machine-readable data.

```bash
portly status
portly status --details
portly status --json

portly memory-limit 5GB
portly memory-limit 3GB --project my-app
portly memory-limit inherit --project my-app
portly memory-limit off

portly add-project \
  --name my-app \
  --path ~/Developer/my-app \
  --icon globe \
  --color '#0A84FF' \
  --json

portly add-server \
  --project my-app \
  --name web \
  --command 'pnpm run dev' \
  --port 5173 \
  --start \
  --json

portly logs my-app/web --tail 100
portly restart my-app/web --json
portly update-server my-app/web --action 'clear-cache=trash .next/cache'
portly action my-app/web clear-cache
portly take-over my-app/web --json
portly stop --project my-app --json
```

The other commands are `action`, `memory-limit` (`ram-limit`), `start`, `stop`, `restart`,
`take-over` (`adopt`), `update-server`, `remove`, `port`, `kill-port`, `open`, `quit`, `forever` and
`config`. `action` runs a configured maintenance command beside a server without restarting it; its
output lands in that server's terminal and logs. `memory-limit` shows or changes the global default
and the project overrides, and is off by default. `take-over` stops an external listener on the
configured port and relaunches the server under Portly. `forever` manages the per-user macOS
LaunchAgent — `forever enable` preserves and restarts the servers active during the handoff to
`launchd`, `forever disable` removes the LaunchAgent recoverably and leaves them running under a
regular launch. `quit` stops every managed server, because the app is the supervisor.

Run `portly <command> --help` for the exact flags.

## Configuration

The source of truth is `~/.config/portly/config.json`, watched for external changes. Terminal
layouts live beside it in `studio.json`, and server logs in `~/.config/portly/logs/`.

```json
{
  "version": 1,
  "apiPort": 7737,
  "healthIntervalSeconds": 10,
  "maxRestartAttempts": 5,
  "logBufferLines": 5000,
  "logFileMaxMB": 10,
  "projects": [
    {
      "id": "prj_example",
      "name": "Example",
      "icon": "globe",
      "color": "#0A84FF",
      "root": "/absolute/path/to/project",
      "servers": [
        {
          "id": "srv_example",
          "name": "web",
          "command": "pnpm run dev",
          "port": 5173,
          "directory": null,
          "env": {},
          "healthURL": null,
          "healthStatus": null,
          "autoRestart": true,
          "actions": [{ "name": "clear-cache", "command": "trash .next/cache" }]
        }
      ]
    }
  ]
}
```

`directory` may be absolute or relative to the project root. Portly provides `PORT`, `PORTLY=1` and
`PORTLY_SERVER` to child processes and configured actions. Actions run beside the server, in its
working directory and with its environment, streaming into its terminal and logs without restarting
it; one action at a time per server. A bare port check connects to `localhost` over IPv4 or IPv6;
`healthURL` may be a path such as `/api/health` or a complete URL.

## Local API

The control API listens only on `127.0.0.1:7737`. It can start processes, so it is deliberately
unavailable to the network.

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/ping` | Version and availability |
| `GET` | `/status` | Projects and live server state |
| `GET` | `/config` | Current configuration |
| `GET` | `/logs?server=web&tail=200` | Recent output of a server or a temporary job |
| `GET` | `/temporary/status?id=tmp_…`, `/temporary/list` | One temporary job, or all of them |
| `POST` | `/temporary/run`, `/temporary/stop` | Start or end a temporary job |
| `GET` | `/ports?port=5173` | Process occupying a port |
| `POST` | `/start`, `/stop`, `/restart` | Act on a server or project |
| `POST` | `/actions/run` | Run a configured server action beside it, into its terminal |
| `POST` | `/memory-limit` | Configure the global default or a project memory guard |
| `POST` | `/projects/add`, `/projects/remove` | Mutate projects |
| `POST` | `/servers/add`, `/servers/update`, `/servers/remove` | Mutate servers |
| `POST` | `/servers/take-over` | Move an external listener under Portly |
| `POST` | `/ports/kill` | Send `SIGTERM` to a port occupant |
| `POST` | `/open`, `/quit` | Control the app |

Responses are JSON envelopes with `ok`, `data` and `error`. The CLI is the supported agent-facing
interface and handles launching the app and encoding requests.

## Agent skill

The distributable skill is in [`skills/portly`](skills/portly). The installer copies it to the
canonical personal root at `~/.agents/skills/portly`, shared by Codex and Cursor and exposed to
Claude through the standard `~/.claude/skills` compatibility link.

The installer also maintains a marker-delimited rule in `~/.agents/AGENTS.md`; the app's onboarding
adds the same rule to `~/.claude/CLAUDE.md`. During project setup the skill requires that rule in the
repository's own root `AGENTS.md`, which makes the behaviour portable to collaborators and other
machines. Every write is idempotent and preserves existing instructions.

---

## What this fork changes

Compared to upstream Portly:

- **Added** — coding sessions and split agent terminals, the free terminal with its tabs, the
  agent launch screen, workspace trust, the quick terminal, the `.env` panel, keep-awake, the drop
  zone, the Git readout and its history graph, the Talvo mirror, Nucleo icons, sidebar search,
  menu-bar-only mode, and the AI usage rings.
- **Changed** — temporary jobs (`portly temp` / `portly wait`) are headless: an agent's tool,
  never a sidebar entry; server actions run beside a server, streaming into its terminal.
- **Removed** — the Sparkle auto-updater and its feed (which would replace this build with the
  stock release), launch telemetry, the landing page, and the Mac App Store companion target.

Upstream Portly is by [Melvynx](https://github.com/Melvynx/portly). AI usage is adapted from
[Codenotch](https://github.com/vinzdg/codenotch). Both are MIT, and so is this fork — see
[LICENSE](LICENSE).
