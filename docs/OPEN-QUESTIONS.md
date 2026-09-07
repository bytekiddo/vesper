# Open questions

Loop mode never asks. Each entry: the safest default that was chosen, and what a human might want to change.

- 2026-09-07 (M1) — Session/cycle dollar caps: chose $2.5 per session and $8 per cycle (`config/budget.json` → `caps_usd`). The overseers' share is ~$200/month ≈ $1.67 per cycle at 4 cycles/day; the caps bound one runaway session or cycle, the category share bounds the month. Raise them if agentic sessions (M3) need more headroom.
- 2026-09-07 (M1) — Per-category overrun is enforced before each call and is *not* a Judge hard limit: a citizen overshoot (provisional vs actual cost) would otherwise veto every proposal for the rest of the month. Total-budget overrun stays a hard limit. Say so if category overrun should veto too.
- 2026-09-07 (M1) — Seed roster in `config/models.json` (director/proposers `anthropic/claude-sonnet-5`, judge `openai/gpt-5.4`) only matters offline and on the first live cycle; the Steward overwrites it every cycle from the marketplace.
- 2026-09-07 (M3) — Screenshots on the VPS need a display: `make screenshot` wraps Godot in `xvfb-run -a` when it exists, but `xvfb` (and Mesa's llvmpipe) are not in `setup.sh` yet — M8 adds them. Until then `screenshot` returns a clear failure on the server and sessions proceed without it.
- 2026-09-07 (M3) — The M3 check ran a real engineer session in a throwaway copy of the repo (no remote), so its OpenRouter spend is recorded in that copy's ledger, not the live one; the amount is noted in PROGRESS.md. Say so if dev-checkout spend should be appended to the live ledger.
