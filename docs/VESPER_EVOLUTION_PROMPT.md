# VESPER — Evolution Prompt (Phase 2: Living Town)

You are evolving **Vesper** (`bytekiddo/vesper`), a town of AI citizens that lives on one server and grows on its own. Phase 1 (the Genesis prompt, `docs/` history, README) is done and running. Phase 2 makes the town's **overseers creative and autonomous** and makes the town **look and feel like Harvest Moon / Stardew Valley**, so that seasons, jobs, buildings, festivals and art keep growing without me.

Read first, in this order: `AGENTS.md`, `docs/VISION.md`, `docs/DECISIONS.md`, `docs/PROGRESS.md`, `README.md`, `overseers/run.py`, `overseers/roles/*.md`, `kernel/rails.py`, `kernel/smoke.gd`, `world/schema.gd`, `viewer/viewer.gd`. `docs/VISION.md` is the only statement of taste; derive every rubric from it.

Work autonomously. Verify anything version- or API-specific on the web before binding it (current stable Godot 4.x, OpenRouter, **PixelLab API v2** at `https://api.pixellab.ai/v2` — read `https://api.pixellab.ai/v2/llms.txt` and the OpenAPI spec). Decide, document in `docs/DECISIONS.md`, keep going. Prefer boring, stable technology; the town must survive weeks of nobody touching it.

## Authority in this run

You act as my hands. **You may edit `kernel/` only at milestones marked [kernel]**; after each such edit run `make kernel-hash`, `make smoke`, and move the `last-known-good` tag. Overseers still never touch the kernel. Do all work on branch `phase-2` in this dev checkout; never against the live world.

## What I want, in order of importance

1. **It still runs and stays running** — unattended, for weeks, within budget. Nothing here may weaken smoke test, rollback, checkpoint or content limits.
2. **Overseers become creative and autonomous** — a Director holds the vision and a roadmap; proposers work in agentic sessions and can run, look and iterate; every hypothesis is verified later; the system learns from verdicts and from my feedback.
3. **The town looks alive** — sprites with animation, tile-based map, day/night, and the hooks for seasons, weather and festivals, so overseers can fill them in.
4. **I can be in it** — as a Visitor who walks, talks and gives gifts, and is remembered.

## Invariants (unchanged from Genesis — change only with a written reason)

One Godot 4.x project, two modes (headless server + web viewer that never simulates). Canonical time. Checkpoints are the fossil record; every new field gets a default in `world/schema.gd`. Two-tier cognition. Money is the sun: `BUDGET_USD_PER_MONTH` is the only lever, every token — **including PixelLab spend** — goes in the public ledger. Content limits are kernel-enforced. Kernel frozen for overseers, self-hashing, restore-from-last-known-good. Hard limits: boots, 10-minute smoke, tick drift < 1 s, memory ceiling, no budget overrun, no content breach.

## Budget

`BUDGET_USD_PER_MONTH` is now 400 (range 300–500). Put the split in `config/budget.json`: overseers 50 %, citizens 30 %, art 10 %, judge + verifier 10 %, and enforce it per category in the ledger. The Steward's policy flips: minimise cost for **citizens**, but Director, proposers and Judge use frontier-class models (Judge from a different family). At zero the town runs on Tier 1 and overseers idle — lore, not outage.

## Overseers, Phase 2

Proposals still **merge by default**; the Judge still vetoes only hard limits. But everything above the rails changes:

- **Director** (new, runs first every cycle). Reads VISION, `docs/ROADMAP.md`, git log, `journal/`, `state/metrics.json`, latest screenshots and `state/feedback/`. Owns ROADMAP: breaks the vision into milestones, picks **one focus per cycle**, assigns work to roles, and its `focus` + `assignments` are injected into every proposer prompt. Weekly retrospective: which milestones moved, which hypotheses were confirmed, revise ROADMAP, record in `docs/DECISIONS.md` if a rubric or weight changes.
- **Agentic proposers.** Replace the one-shot `ask()` for Worldsmith, Weaver, Lawgiver, Artisan and a new **Engineer** (cross-file feature work in `world/`, `viewer/`, `overseers/`, never `kernel/`) with a tool-use loop: `read_file`, `write_file`, `run` (whitelisted: `make smoke-quick`, `make dev`, `make export-web`, `make art-eval`, git), `screenshot`, `view_image`. Sessions run against a throwaway world (`make dev`), are capped in steps and dollars by the rails, and end in a branch `overseer/<role>/<slug>`, not a full-file write. Main accepts a branch only after full `make smoke` + Judge. Multi-cycle features are allowed: the Director tracks them.
- **Prompt policy.** Delete "one to three ops per cycle", "change one thing per cycle", "prefer small over large". Replace with: "as small as possible for this milestone, as large as necessary; prefer data over code for citizens and rules; name the milestone and a measurable hypothesis".
- **Hypothesis verifier** in `rollback_watch`. Hypotheses use the format `"<metric> will <rise|fall> to <value> within <N> hours"`. 24–72 h after merge, compare against `state/metrics.json`, record `confirmed | refuted | inconclusive` in `journal/` and `state/`, and surface it to the Director. Refuted is information, not a rollback trigger; stability degradation remains the only auto-rollback.
- **Metrics.** Extend `state/metrics.json` from the sim: conversations/day, activity diversity, job distribution, building visits, mean mood, and "feature echo" — how many citizens mention a feature introduced in the last N days in their memories. Stability metrics stay as they are.
- **Judge** becomes multimodal and **pairwise**: for viewer changes it compares before/after screenshots against a rubric derived from VISION and records a score into metrics. Veto rights unchanged (hard limits only); the score is signal, not a gate — except for Artisan branches, which merge only if "not worse".
- **Artisan** (new, `viewer/` and `viewer/art/` only). Owns the art pipeline through PixelLab: one style reference (`viewer/art/style_ref.png`; generate it from the VISION style prompt if absent), forced shared palette, every citizen gets a style-matched 32×32 (or 32×48) sprite via character generation → 4 rotations → walk + idle animation; every building `kind` gets tiles; ground gets connected tilesets. Assets are cached in `viewer/art/` with `manifest.json`, never regenerated if present, never committed if the palette check fails. `make art-eval`: no magenta tiles, every `kind` has art, web export boots, ≥ 30 fps with the current population, atlas under a size limit, then the pairwise judge.
- Steward, Chronicler, Judge otherwise keep their roles. Names are suggestions; the runner may reorganise itself.

## World and viewer

- Split `viewer/viewer.gd` into `map_renderer.gd` (TileMapLayer), `citizen_sprite.gd` (AnimatedSprite2D), `hud.gd`, `art_loader.gd` (loads `viewer/art/manifest.json` into textures). Interpolate citizen movement between ticks; the server sends `facing`, `moving`, `activity` per citizen.
- Add to `rules.json` + schema defaults: `season`, `weather`, `daylight` curve; sim exposes them; viewer tints light by clock and swaps ground palette by season. Citizens sit, work, sleep visibly; open buildings show who is inside; windows light at dusk. The **content** of seasons, festivals, new jobs is the overseers' job — build the hooks, seed one season cycle so it is exercised, and stop.
- **Visitor mode.** A user joins from the web viewer as a temporary citizen that lives in the server sim (never viewer-side): walk, talk (Tier 2 from a separate `visitor` budget line), give a small item. Citizens store the encounter as memory; the Weaver may seed stories around visitors. Visitor input is untrusted: kernel content filter + rate limit before it touches world state; many visitors = many temporary citizens; they expire after inactivity. Add 👍/👎 + one-line reason in the viewer, written to `state/feedback/` for the Director and Artisan.

## Ops deliverables

Update `setup.sh` idempotently (PixelLab key prompt, new env, new systemd units/timers if any). `make art-eval`, `make dev` (throwaway world), `make verify` (run the hypothesis verifier once). README: what changed in Phase 2, the new overseer lineup, per-category spend, how to visit, art credits ("sprites generated with PixelLab").

## Loop mode (unattended goal-runner)

- **Never ask.** Write questions to `docs/OPEN-QUESTIONS.md`, pick the safest default, continue.
- **`docs/PROGRESS.md` is your memory.** First action each iteration: read `AGENTS.md`, `docs/PROGRESS.md`, `docs/DECISIONS.md`, `docs/VISION.md`, this file. Last action: update `PROGRESS.md` (milestone status, what was done, the single next step) and commit.
- **One milestone per iteration at most.** If one can't be finished, leave the tree green (`make smoke` passes) and record exactly where you stopped.
- **Milestones, in order** (each ends with a passing check and a commit):
  1. **[kernel] Budget & rails.** `config/budget.json` with per-category enforcement in the ledger; rails add per-session and per-cycle cost caps and a PixelLab spend category; Steward policy flipped. Check: `make smoke` green, one overseer cycle runs on a dev world under the new config.
  2. **Director.** Role file, runs first, injects focus/assignments, maintains `docs/ROADMAP.md`, weekly retrospective. Check: a dry-run cycle writes a ROADMAP entry and every proposer prompt contains the focus.
  3. **Agentic proposers + branch workflow.** Tool-use loop, throwaway world, step/dollar caps, branches, merge only via full smoke, prompt policy rewritten, Engineer role added. Check: on a dev world, deliberately break something small; a proposer session finds and fixes it within its caps and its branch merges through the gate.
  4. **Metrics, verifier, multimodal Judge.** Check: a seeded hypothesis gets a verdict from `make verify`; the Judge scores two screenshots pairwise and the score lands in metrics.
  5. **Viewer foundation + Artisan + PixelLab.** Viewer split, `art_loader`, manifest, PixelLab client with job polling and ledger, style reference, first batch of citizen sprites and building tiles, `make art-eval`. Check: web export shows animated citizens from cached PixelLab assets; `make art-eval` passes; checkpoint round-trip unaffected.
  6. **Living-world hooks.** `facing/moving/activity` over the wire with interpolation; season/weather/daylight in rules + schema + sim + viewer; visible activities and window lights; one full seasonal cycle exercised in dev. Check: changing `season` in rules changes ground palette and light in the viewer; determinism replay still passes.
  7. **Visitor + feedback.** Check: a visitor joins from the web, talks to a citizen through Tier 2, the citizen's memory contains the encounter after the next reflection; a 👍 lands in `state/feedback/`.
  8. **Ops, README, dry run.** `setup.sh` verified in a fresh `docker run -it ubuntu:24.04`; systemd/nginx validated; README updated; then merge `phase-2` into `main` on the dev checkout and run **one complete overseer cycle end-to-end** (Director → proposers → smoke → Judge → merge → verifier scheduled). Check: the cycle completes and commits with an `Overseer:` trailer.
- **Done** = all eight milestones checked in `PROGRESS.md`, `make smoke` green, README updated. Then stop and report. Do **not** start inventing seasons, jobs or festivals yourself — that is the overseers' job now; your job was to make them able to.