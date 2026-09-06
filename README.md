# Vesper

Vesper is a small fictional coastal town of AI citizens that lives on one server, grows on its own, and can be watched in 2D.
Nobody plays it. The citizens keep habits, remember things, reflect on them, make plans and talk to each other
(Park et al., *Generative Agents*, 2023: memory stream → retrieval → reflection → planning). Six AI **overseers** visit every six hours
to grow the map, grow the population, revise the rules, judge, and print the newspaper. The only lever a human keeps is the monthly budget.

It is the successor of [petri](https://github.com/bytekiddo/petri). Petri proved the physics; Vesper is the soul.

## Watch it

Open the viewer (the address is whatever `setup.sh` printed, e.g. `http://<your-vps>/`). You will see the town from above:
streets, buildings, the lighthouse nobody remembers building, and citizens walking about. The bar at the top always shows the town's
clock and date, the population, the map size and building count (growth), and this month's spend.

- **Click a citizen** to read their personality, mood, current thought, today's plan, recent memories, relationships,
  and their conversations — live as speech bubbles, and as a scrollable log.
- **Newspaper** opens the town paper, written by the Chronicler from the citizens' memories. The Chronicler named it on its first run.
- Drag with the mouse to pan, scroll to zoom.

The viewer simulates nothing. It connects to the server over WebSocket and draws what it is told.
If the server is down, the town still exists in its checkpoints; when it comes back it catches up to the wall clock.

## How it works

- **One Godot 4.7 project, two modes.** `godot --headless --path . -- --server` runs the canonical world. The web export is the viewer.
- **Canonical time.** Tick *n* happens *n* seconds after genesis (`2026-09-07T00:00:00Z`), whether or not anyone is watching. One tick is ten simulated seconds; a town day is 2.4 real hours.
- **Two-tier cognition.** Tier 1 is free and deterministic: routines, commutes, meals, small talk, importance-scored memories, reflection from templates. Tier 2 is paid consciousness: an OpenRouter call only at meaningful moments (a day's plan, a reflection when enough has happened, a real conversation), whose output is written into the world so replay never needs a model again.
- **Checkpoints are the fossil record.** The whole world is one JSON document, saved hourly, kept daily forever in `checkpoints/daily/`, and committed to git. Any era can be reloaded.
- **Money is the sun.** `BUDGET_USD_PER_MONTH` (50–100, default 75). Every token is written to `ledger/spend.jsonl`. The Steward moves everyone to cheaper models as the month runs low; at zero the town runs on habit alone — lore, not an outage.
- **The kernel is frozen.** `kernel/` (clock, checkpoint format, ledger, content limits, watchdog, smoke test, overseer rails) hashes itself at every start and restores from the `last-known-good` tag if touched. Only a human edits it.
- **Content limits are enforced by the kernel, not by prompts.** No real people or brands as citizens; no sexual content; no romantic framing involving minors; no harm instructions; no slurs. Violations go to `quarantine/`, never into the world.

## The overseers

Every six hours (`ops/vesper-overseer.timer`) `overseers/run.py` runs one cycle: pull → Steward → Worldsmith, Weaver, Lawgiver each propose → apply → smoke test → Judge → commit with an `Overseer:` trailer → Chronicler → restart.
Proposals **merge by default**; the Judge may veto only on hard-limit violations (won't boot, smoke fails, budget or content breach), never on taste.
Anything that degrades stability within 24 hours is rolled back automatically and recorded in `journal/`.

| Role | Does |
|---|---|
| Steward | reads the ledger and the live OpenRouter marketplace; assigns a model to every role (the Judge from a different family) |
| Worldsmith | grows the map: streets, buildings, places, when the town needs them |
| Weaver | grows the people: arrivals, births, departures, relationship and story seeds |
| Lawgiver | revises the rules of simulation and cognition (`world/rules.json`) with a stated hypothesis |
| Judge | hard-limit veto only, plus content review of diffs |
| Chronicler | writes the newspaper in `journal/` |

<!-- ledger:start -->
*No cycle has run yet. This block is rewritten by the overseer runner with the current lineup and spend.*
<!-- ledger:end -->

The newspaper: [`journal/`](journal/) (also served at `/journal/` next to the viewer, and readable inside it).

## Run it yourself

On a fresh Ubuntu 24.04 VPS:

```bash
git clone https://github.com/bytekiddo/vesper.git && cd vesper && sudo ./setup.sh
```

`setup.sh` is interactive and idempotent. It installs Godot 4.7.2 (headless + web templates), Python, nginx with the COOP/COEP headers,
git with a deploy key, UFW, systemd units (world server with auto-restart, overseer timer, nightly backup) and log rotation; asks for
your OpenRouter key, budget and domain; writes `.env` (never committed).

Locally (macOS/Linux with Godot 4.7.2 on the PATH):

```bash
make smoke-quick     # boot, 20k fast ticks, determinism replay, checkpoint round-trip, 15 s real-time run
make dev             # a throwaway world on port 9002 (fresh seed, stubbed model)
make viewer-dev      # the desktop viewer against it
```

`make smoke` (the 10-minute version) is the definition of done for any change. See [`AGENTS.md`](AGENTS.md) for the rules every AI session follows and [`docs/DECISIONS.md`](docs/DECISIONS.md) for the pins and trade-offs.

## Layout

```
kernel/      frozen: clock, checkpoint, ledger, content filter, watchdog, smoke test, guard.sh, rails.py
world/       the simulation: sim.gd (tick), memory.gd, cognition.gd (Tier 2), map.gd, llm.gd, net.gd, server.gd, rules.json, seed.json
viewer/      the 2D viewer (procedural art; the Worldsmith may improve it)
overseers/   run.py + role prompts + state.json
ops/         systemd units, nginx, logrotate, backup
journal/     the newspaper        checkpoints/  the fossil record        ledger/  every token spent
```
