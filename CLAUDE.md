# Vesper — agent harness

This file governs every AI session that touches this repo (human-run coding agents and the overseer runner alike).

## Invariants — read before any change
- `kernel/` is frozen: clock/tick scheduler, checkpoint format + migration, budget ledger, content limits, watchdog, smoke test, overseer safety rails. Only a human edits it, explicitly. Don't touch it; if a task seems to require it, stop and say so.
- Canonical time never rewinds. Never change genesis time, tick length, or checkpoint semantics.
- Adding a field to any serialized entity requires a default so old checkpoints load.
- No secrets in the repo. Keys live in `.env` on the server only. The viewer never holds a key.
- Every LLM output passes the kernel content filter before it enters world state.

## Definition of done for any change
- `make smoke` passes (headless boot, 10-minute run, determinism replay).
- Commit message states the hypothesis; overseer commits carry an `Overseer: <role>/<model>` trailer.
- Decisions with trade-offs are appended to `docs/DECISIONS.md` (one line each).

## Policy for overseers
- Merge by default. Veto only on hard-limit violations. Roll back automatically if stability metrics degrade within 24 h, and record the rollback in `journal/`.
- Spend is recorded in the ledger every call; never bypass the Steward's model assignment.

## Conventions
- Godot 4.x, GDScript, one project, two modes (`--headless` server / web viewer).
- Python runner in `overseers/`, systemd units in `ops/`, newspaper in `journal/`, checkpoints in `checkpoints/`.
- Prefer boring and stable; the town must survive weeks of nobody touching it.
