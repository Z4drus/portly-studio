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
- **Relaunch** — every session respawns at launch and the last selection comes back. Claude Code
  panes carry a session id (`--session-id`) and resume their conversation (`--resume`) after a quit
  or a reboot; a *Reset* button in the pane header starts a fresh chat.
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
- **Quick terminal** — one scratch shell per project, floating top-right, toggled with ⌘J from any
  screen.
- **Environment files** — every `.env*` at the project root in a floating panel (⇧⌘E) with dotenv
  colouring (keys, strings, comments, `${vars}`, unclosed quotes flagged), plus "create `.env` from
  `.env.example`" and the reverse.
- **Keep awake** — the mug in the toolbar holds the Mac awake (power assertion, plus
  `pmset disablesleep` with an administrator so a closed lid keeps Wi-Fi and agents alive). It
  releases by itself once every terminal has been quiet for N minutes, after 90 s offline, under 10 %
  battery, and always on quit. The first activation asks for your password once to install a sudo
  rule limited to those two `pmset` commands.
- **Activity** — a spinner next to a session while any of its terminals produces output, a dot once
  it went quiet and you have not looked yet. Claude Code's animated title glyph is stripped.
- **Drop zone** — drop files anywhere on a project screen to copy them to its root, then
  *Tell the agent* types the file list into the focused terminal.
- **Dependencies** — a Node server whose `node_modules` is missing shows an *Install dependencies*
  button (pnpm, bun, yarn or npm, detected from the lockfile) and greys out *Start* until the install
  finishes.
- **Icons and colours** — Nucleo glyph-duo icons everywhere, a project icon picker that searches
  3 400 glyphs in French or English, and a twenty-colour project palette.

## AI usage

How much of each coding assistant's limit you have burned, read from the credential the tool already
holds on the machine — Claude Code's keychain token by default; Codex, Cursor and Grok are opt-in in
Settings → AI Usage. Nothing is sent anywhere except to each vendor's own usage endpoint.

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

Projects hold long-lived, reusable services. Builds, tests and other one-off commands are not
Portly's job: run them directly, in the foreground, with a timeout.

A busy configured port makes the server start on the next free one (`PORT` and an explicit
`-p`/`--port` are rewritten), with a banner to take the configured port back; every port the process
tree listens on shows in the sidebar and in the Open menu.

The native **Resources** screen samples every Portly-owned process tree every two seconds and keeps a
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
  --command 'pnpm dev' \
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
          "command": "pnpm dev",
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
| `GET` | `/logs?server=web&tail=200` | Recent server output |
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

- **Added** — coding sessions and split agent terminals, workspace trust, the quick terminal, the
  `.env` panel, keep-awake, the drop zone, Nucleo icons, sidebar search, menu-bar-only mode, and the
  AI usage rings.
- **Removed** — temporary jobs (`portly temp` / `portly wait` and their API routes; server actions
  still run beside a server, streaming into its terminal), the Sparkle auto-updater and its feed
  (which would replace this build with the stock release), launch telemetry, the landing page, and
  the Mac App Store companion target.

Upstream Portly is by [Melvynx](https://github.com/Melvynx/portly). AI usage is adapted from
[Codenotch](https://github.com/vinzdg/codenotch). Both are MIT, and so is this fork — see
[LICENSE](LICENSE).
