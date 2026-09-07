## Phase 2 — Living Town (started 2026-09-07)
Milestones: see docs/VESPER_EVOLUTION_PROMPT.md § Loop mode. Branch: `phase-2` (dev checkout; never the live world).
- [x] M1 budget & rails — 2026-09-07. `config/budget.json` (400 USD, range 300–500; overseers 50 / citizens 30 / art 10 / judge+verifier 10; caps session $2.5 / cycle $8, kernel-protected). Ledger lines carry `category` (old lines categorised on read; `by_category` totals in both languages). Rails: `check_spend(category, est)` before every paid call (category share + session/cycle caps), `record(…, category=)` for PixelLab later, `begin_cycle()/begin_session()` called by the runner. Steward policy flipped (`roles/steward.md`, `run.py steward()`: cheap citizens, frontier director/proposers/judge, judge family independent, per-category affordability). `world/llm.gd` reads the citizens share. Kernel manifest regenerated, `last-known-good` moved. Checks passed: rails + runner self-checks, smoke-quick, full `make smoke`, offline dry-run cycle.
- [ ] M2 Director
- [ ] M3 agentic proposers + branch workflow
- [ ] M4 metrics, verifier, multimodal Judge
- [ ] M5 viewer foundation + Artisan + PixelLab
- [ ] M6 living-world hooks
- [ ] M7 Visitor + feedback
- [ ] M8 ops, README, dry run on main
Next step: M2 — `overseers/roles/director.md`; `director()` runs first in `run.py` (reads VISION, ROADMAP, git log, journal/, state/metrics.json, state/feedback/), writes `docs/ROADMAP.md`, its `focus` + `assignments` are injected into every proposer prompt; weekly retrospective. Check: an offline dry-run cycle writes a ROADMAP entry and every proposer prompt contains the focus.
