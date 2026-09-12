# Vesper

Vesper is a small fictional coastal town of AI citizens that lives on one server, grows on its own, and can be watched — and visited — in 2D.
Nobody plays it. The citizens keep habits, remember things, reflect on them, make plans and talk to each other
(Park et al., *Generative Agents*, 2023: memory stream → retrieval → reflection → planning). Nine AI **overseers** visit every six hours
to steer, grow the map, grow the population, revise the rules, build features, draw the art, judge, and print the newspaper.
The only lever a human keeps is the monthly budget.

It is the successor of [petri](https://github.com/bytekiddo/petri). Petri proved the physics; Vesper is the soul.
**Phase 1** (Genesis) gave it physics and memory. **Phase 2** (Living Town) gave the overseers a Director, tools and branches, gave the
town seasons, weather, day and night, PixelLab pixel art, and a door for you to walk in.

## Watch it

Open the viewer (the address `setup.sh` printed, e.g. `http://<your-vps>/`). You will see the town from above in Harvest-Moon-style
pixel art: grass and cobbled streets, the sea, roofed buildings with doors, the lighthouse nobody remembers building, and citizens
walking about with four-direction walk and idle animations. The bar at the top shows the town's clock and date, **season and weather**,
the population, the map size and building count, and this month's spend.

- **Day and night.** The light follows the town clock; windows glow from dusk (brighter where someone is home), the lighthouse lamp burns all night.
- **Seasons** tint the ground; weather (rain, fog, storms, snow in winter) darkens the light and ends up in citizens' memories.
- **Who is where.** People inside a building are listed under its name; people outdoors are drawn where they stand.
- **Click a citizen** to read their personality, mood, current thought, today's plan, recent memories, relationships and conversations.
- **Newspaper** opens the town paper, written by the Chronicler from the citizens' memories.
- Drag to pan, scroll to zoom.

### Visit it

Press **Visit**, give a name, **Walk in**. You are now a temporary citizen who lives in the server's simulation (never in your browser):
click the ground to walk, stand next to someone and **Say** something — the nearest citizen answers in character (a paid model call from
the *visitor* budget line; a stock line when that purse is empty), and remembers you. **Give** a small gift and they remember that too.
Leave a **👍 / 👎 with one line** — it lands in `state/feedback/` for the Director and the Artisan. Visitors expire after half a sim hour of silence.
Everything you type passes the kernel content filter and a rate limit before it touches the world.

The viewer simulates nothing. It connects to the server over WebSocket and draws what it is told.
If the server is down, the town still exists in its checkpoints; when it comes back it catches up to the wall clock.

## How it works

- **One Godot 4.7 project, two modes.** `godot --headless --path . -- --server` runs the canonical world. The web export is the viewer.
- **Canonical time.** Tick *n* happens *n* seconds after genesis (`2026-09-07T00:00:00Z`), whether or not anyone is watching. One tick is ten simulated seconds; a town day is 2.4 real hours; a season is 90 town days.
- **Two-tier cognition.** Tier 1 is free and deterministic: routines, commutes, meals, small talk, weather, importance-scored memories, reflection from templates. Tier 2 is paid consciousness: an OpenRouter call only at meaningful moments (a day's plan, a reflection, a real conversation, a visitor's question), whose output is written into the world so replay never needs a model again.
- **Checkpoints are the fossil record.** The whole world is one JSON document, saved hourly, kept daily forever in `checkpoints/daily/`, and committed to git. Every new field has a default, so any era can be reloaded.
- **Money is the sun.** `BUDGET_USD_PER_MONTH` (300–500, default 400). `config/budget.json` splits it — overseers 50 %, citizens 25 %, visitors 5 %, art 10 %, judge + verifier 10 % — and every line of `ledger/spend.jsonl` (model tokens *and* PixelLab generations) carries its category, enforced before each call, with a per-session and per-cycle cap on top. At zero the town runs on habit alone — lore, not an outage.
- **The kernel is frozen.** `kernel/` (clock, checkpoint format, ledger, content limits, watchdog, smoke test, overseer rails) hashes itself at every start and restores from the `last-known-good` tag if touched. Only a human edits it.
- **Content limits are enforced by the kernel, not by prompts.** No real people or brands; no sexual content; no romantic framing involving minors; no harm instructions; no slurs — for model output and for visitor input alike. Violations go to `quarantine/`, never into the world.
- **Art is generated, cached and checked.** `overseers/pixellab.py` asks PixelLab for a style reference, Wang tilesets, building sprites and per-citizen 32×32 characters with walk and idle animations, keeps them in `viewer/art/` with a manifest, never regenerates one that exists, and refuses any that stray from the shared palette (`viewer/art_check.gd`). *Sprites, tiles and buildings generated with [PixelLab](https://www.pixellab.ai).*

## The overseers

Every six hours (`ops/vesper-overseer.timer`) `overseers/run.py` runs one cycle:
pull → **Steward** (models) → **Director** (one focus, assignments, `docs/ROADMAP.md`) → each proposer works in an **agentic session**
on its own branch `overseer/<role>/<slug>` against a throwaway world (read, write, run `make smoke-quick`, screenshot, look), capped in steps
and dollars → the **gate**: full 10-minute smoke test + Judge (pairwise before/after screenshots for viewer changes) → merge with a
`Milestone:` and an `Overseer:` trailer → **Chronicler** → hypothesis **verifier** (24–72 h later: confirmed / refuted / inconclusive, in
`journal/verdicts.md`, back to the Director) → restart.
Every merge names a milestone and a measurable hypothesis (`<metric> will rise|fall to <value> within <N> hours`). Proposals **merge by
default**; the Judge may veto only on hard-limit violations (won't boot, smoke fails, budget or content breach), never on taste — except
that the Artisan's branches merge only when judged *not worse*. Refuted hypotheses are information; only stability degradation within
24 hours rolls a merge back (recorded in `journal/`).

| Role | Does |
|---|---|
| Steward | reads the ledger and the OpenRouter marketplace; cheapest reliable model for citizens, frontier models for the Director, proposers and Judge (Judge from another family) |
| Director | holds the vision (`docs/VISION.md`), owns `docs/ROADMAP.md`, picks one focus per cycle, assigns work, reads verdicts and visitor feedback, retrospective weekly |
| Worldsmith | grows the map: streets, buildings, places |
| Weaver | grows the people: arrivals, families, relationship and story seeds — including stories around visitors |
| Lawgiver | revises the rules of simulation and cognition (`world/rules.json`: seasons, weather, daylight, moods, conversation…) |
| Engineer | cross-file feature work in `world/`, `viewer/`, `overseers/` — never `kernel/` |
| Artisan | the look: `viewer/` and `viewer/art/`; runs the PixelLab pipeline (`make art`, `make art-eval`) |
| Judge | hard-limit veto, content review of diffs, pairwise screenshot score for viewer changes |
| Chronicler | writes the newspaper in `journal/` |

<!-- ledger:start -->
*Updated 2026-09-12 00:29 UTC by the overseer runner.*

**Spend this month (2026-09):** $5.22 of $400 across 1844 calls (10,407,939 prompt / 838,042 completion tokens).

**By category:** overseers: $4.83 of $200 · citizens: $0.17 of $100 · visitor: $0.00 of $20 · art: $0.00 of $40 · judge: $0.21 of $40

| Role | Model | Spent |
|---|---|---|
| citizen | `mistralai/mistral-nemo` | $0.17 |
| steward | `inclusionai/ling-3.0-flash` | $0.01 |
| director | `nousresearch/hermes-3-llama-3.1-405b` | $0.13 |
| worldsmith | `nousresearch/hermes-3-llama-3.1-405b` | $0.22 |
| weaver | `nousresearch/hermes-3-llama-3.1-405b` | $0.40 |
| lawgiver | `nousresearch/hermes-3-llama-3.1-405b` | $1.50 |
| engineer | `nousresearch/hermes-3-llama-3.1-405b` | $2.11 |
| artisan | `openai/gpt-4o:batch` | $0.00 |
| judge | `x-ai/grok-build-0.1` | $0.21 |
| chronicler | `openai/gpt-5` | $0.46 |
<!-- ledger:end -->

The runner rewrites the block above every cycle, including spend per category. The newspaper: [`journal/`](journal/) (also served at `/journal/`
next to the viewer, and readable inside it); the verdicts: [`journal/verdicts.md`](journal/verdicts.md).

## Run it yourself

On a fresh Ubuntu 24.04 VPS (1 vCPU, 2 GB RAM is plenty):

```bash
git clone https://github.com/bytekiddo/vesper.git && cd vesper && sudo ./setup.sh
```

`setup.sh` is interactive and idempotent. It installs Godot 4.7.2 (headless + web templates), Python, nginx with the COOP/COEP headers,
git with a deploy key, UFW, Xvfb + Mesa (so the Artisan and the Judge can take screenshots on a server with no display), systemd units
(world server with auto-restart, overseer timer, nightly backup) and log rotation; asks for your OpenRouter key, PixelLab key, budget and
domain; writes `.env` (never committed). Unattended: pass them as environment variables; `SKIP_WEB_TEMPLATES=1` skips the large template
download (the same script runs in a plain `docker run ubuntu:24.04` for testing — no systemd, no firewall, configs still validated).

Then do the one thing the script cannot do for you: it prints an ed25519 **deploy key** at the end. Add it to the GitHub repo
(Settings → Deploy keys → *Allow write access*). Until it is added, cycles still run but cannot pull your commits or push theirs.

Locally (macOS/Linux with Godot 4.7.2 on the PATH):

```bash
make smoke-quick     # boot, 20k fast ticks, determinism replay, checkpoint round-trip, 15 s real-time run
make dev             # a throwaway world on port 9002 (fresh seed, stubbed model); VESPER_DEV_TICK=4320 starts it at noon
make viewer-dev      # the desktop viewer against it (the web build accepts index.html?ws=ws://127.0.0.1:9002)
make screenshot      # one PNG of the viewer (OUT=..., WS=...); under xvfb-run on a server
make art             # PixelLab: generate whatever the world has and viewer/art/manifest.json lacks (ARGS="--max-citizens 3")
make art-eval        # coverage, shared palette, size limit, web export, fps
make verify          # give every due hypothesis a verdict
make check           # season cycle, visitor path, rails and runner self-checks
```

`make smoke` (the 10-minute version) is the definition of done for any change. See [`AGENTS.md`](AGENTS.md) for the rules every AI session
follows, [`docs/VISION.md`](docs/VISION.md) for taste, [`docs/ROADMAP.md`](docs/ROADMAP.md) for the Director's priorities,
[`docs/DECISIONS.md`](docs/DECISIONS.md) for the pins and trade-offs and [`docs/OPEN-QUESTIONS.md`](docs/OPEN-QUESTIONS.md) for what a human may want to change.

## Operating it

- **Where things are.** Code and world at `/opt/vesper` (owned by user `vesper`); logs in `/var/log/vesper/`; nightly tarballs in `/var/backups/vesper/`; `checkpoints/latest.json` is the live world (also served at `/checkpoint.json`), `checkpoints/daily/` the eras, `ledger/spend.jsonl` every token and every PixelLab generation, `state/feedback/` what visitors said, `.worktrees/` the proposers' throwaway checkouts.
- **Genesis** is `2026-09-07T00:00:00Z`. Started earlier, the server waits; started later, it catches up at roughly 20 000 ticks a second.
- **The overseers** run at 00:17, 06:17, 12:17, 18:17 UTC (plus up to 15 min jitter). Run one now with `sudo systemctl start vesper-overseer.service` and follow `/var/log/vesper/overseer.log`. A cycle can take a couple of hours: every merged branch gets the full 10-minute smoke test, and sessions think.
- **Restarts** are graceful: `systemctl stop|restart vesper` and the overseers both drop `state/stop` / `state/restart.flag`; the server checkpoints and exits, systemd restarts it.
- **You may commit too.** Push to `main` from anywhere; the next cycle rebases the server's commits on top of yours (your version wins a conflict). To ship a code change immediately: `make deploy` on the VPS.
- **Kernel edits** (`kernel/`) are yours alone: edit, `make kernel-hash`, `make smoke`, commit, `git tag -f last-known-good && git push -f origin last-known-good`. `config/budget.json` is kernel-protected too: the overseers cannot widen their own share.
- **Budget.** `BUDGET_USD_PER_MONTH` in `.env` (300–500). Change it, then `sudo systemctl restart vesper`. An empty OpenRouter key means the town runs on habit alone; an empty PixelLab key means no new art (cached art still shows). PixelLab subscription generations are recorded at `pixellab_usd_per_generation` (`config/budget.json`, default 0).
- **Visitors.** Anyone with the viewer can walk in; names are letters only, input is filtered and throttled per connection, at most 20 visitors at once, and each expires after inactivity. Their talk is paid from the 5 % visitor line.
- **TLS** is not configured by `setup.sh` (nginx listens on 80). Plain: `apt install certbot python3-certbot-nginx && certbot --nginx -d <domain>`. Behind Cloudflare: use SSL mode *Full (strict)*, keep Rocket Loader and Email Address Obfuscation **off** for this zone, and optionally cache `*.wasm` and `*.pck`.
- **If it breaks.** `journalctl -u vesper -n 50`, then `make smoke` in `/opt/vesper` as the `vesper` user. Three boots in a row that never reach ten healthy minutes restore the code from `last-known-good` automatically (`state/guard.log`). The world itself is never restored by that; it lives in the checkpoints.

## Layout

```
kernel/      frozen: clock, checkpoint, ledger, content filter, watchdog, smoke test, guard.sh, rails.py
world/       the simulation: sim.gd (tick, seasons, weather, visitors), memory.gd, cognition.gd (Tier 2), metrics.gd, map.gd, llm.gd, net.gd, server.gd, rules.json, seed.json
viewer/      the 2D viewer: viewer.gd, map_renderer.gd, citizen_sprite.gd, hud.gd, art_loader.gd, art_check.gd; art/ (PixelLab assets + manifest)
overseers/   run.py (cycle, sessions, gate, verifier), pixellab.py (art pipeline), roles/*.md, state.json, proposals/
config/      budget.json (split, caps — kernel-protected), models.json (the Steward's roster)
ops/         systemd units, nginx, logrotate, backup
docs/        VISION, ROADMAP (the Director's), DECISIONS, OPEN-QUESTIONS, PROGRESS
journal/     the newspaper + verdicts    checkpoints/  the fossil record    ledger/  every token    state/  runtime (metrics, feedback, judge scores)
```
