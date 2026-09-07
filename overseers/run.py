#!/usr/bin/env python3
"""Vesper overseers. One cycle: pull -> steward -> director -> agentic sessions (worldsmith, weaver, lawgiver, engineer), each on
its own branch against a throwaway world -> gate (squash-merge, full smoke, judge) -> commit -> chronicle -> rollback watch -> push -> restart.
Merge by default; veto only on hard limits.
Everything here except kernel/rails.py is the overseers' own to reorganize."""
import argparse, base64, glob, json, os, re, shlex, shutil, signal, subprocess, sys, time
from datetime import datetime, timezone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "kernel"))
import rails  # noqa: E402  (frozen kernel: budget, ledger, content filter, model calls, hard limits)

STATE_FILE = os.path.join(ROOT, "overseers", "state.json")
MODELS_FILE = os.path.join(ROOT, "config", "models.json")
PROPOSERS = ["worldsmith", "weaver", "lawgiver", "engineer"]
ROLES = ["citizen", "steward", "director", *PROPOSERS, "judge", "chronicler"]   # everything the Steward assigns a model to
EDITABLE = ("world/", "viewer/", "overseers/", "ops/", "docs/", "README.md", "journal/", "config/", "Makefile", "setup.sh", "export_presets.cfg", "project.godot")
FAMILY = lambda mid: mid.split("/")[0]  # noqa: E731
ARGS = None
TOUCHED = set()   # every repo path this cycle wrote
BACKUP = {}       # dry-run: original content (or None) of every path before this cycle first wrote it
log = rails.log


def will_write(rel):
    """Call before writing a repo path so a dry-run can put back exactly what was there."""
    TOUCHED.add(rel)
    if rel not in BACKUP:
        full = os.path.join(ROOT, rel)
        BACKUP[rel] = open(full, encoding="utf-8").read() if os.path.isfile(full) else None


def restore_backup():
    for rel, content in BACKUP.items():
        full = os.path.join(ROOT, rel)
        if content is None:
            if os.path.exists(full):
                os.remove(full)
        else:
            open(full, "w", encoding="utf-8").write(content)


# ---------------------------------------------------------------- plumbing
def sh(cmd, check=True, capture=True, timeout=1800):
    r = subprocess.run(cmd, cwd=ROOT, capture_output=capture, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {(r.stderr or r.stdout)[-500:]}")
    return (r.stdout or "").strip()


def git(*args, check=True):
    return sh(["git", *args], check=check)


def sync_upstream():
    """Rebase the server's local commits onto origin/main. On a conflict the human's version wins (-X ours = upstream)."""
    r = subprocess.run(["git", "pull", "-q", "--rebase", "--autostash", "-X", "ours", "origin", "main"], cwd=ROOT, capture_output=True, text=True, timeout=300)
    if r.returncode == 0:
        return True
    subprocess.run(["git", "rebase", "--abort"], cwd=ROOT, capture_output=True)
    log(f"pull from origin failed; continuing on local history: {(r.stderr or r.stdout).strip()[-300:]}")
    return False


def load_state():
    try:
        return json.load(open(STATE_FILE, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"cycle": 0, "merges": [], "issues": 0, "history": [], "last_hibernation_note": ""}


def save_state(st):
    will_write("overseers/state.json")
    json.dump(st, open(STATE_FILE, "w", encoding="utf-8"), indent=2)


def models_config():
    try:
        return json.load(open(MODELS_FILE, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def model_for(role):
    cfg = models_config().get(role) or models_config().get("worldsmith") or {}
    return cfg.get("model", "openai/gpt-oss-120b")


def role_prompt(role):
    parts = [open(os.path.join(ROOT, "overseers", "roles", f"{n}.md"), encoding="utf-8").read() for n in (role, "_protocol", *(["_tools"] if role in PROPOSERS else []))]
    return "\n\n".join(parts)


def latest_checkpoint():
    for p in (os.path.join(ROOT, "checkpoints", "latest.json"), *sorted(glob.glob(os.path.join(ROOT, "checkpoints", "daily", "*.json")), reverse=True)):
        try:
            return json.load(open(p, encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
    return {}


def sim_clock(tick):
    day, sec = divmod(int(tick), 8640)
    sec *= 10
    months = ["Thaw", "Sprout", "Bloom", "Haze", "Gleam", "Ember", "Reap", "Rust", "Mist", "Frost", "Hush", "Lantern"]
    days = ["Moonday", "Tideday", "Wendsday", "Thornday", "Fireday", "Saltday", "Sunday"]
    return f"{days[day % 7]}, {months[(day % 360) // 30]} {day % 30 + 1}, Year {day // 360 + 1}, {sec // 3600:02d}:{(sec % 3600) // 60:02d}", day


def world_summary(full=False):
    s = latest_checkpoint()
    if not s:
        return "No checkpoint yet: the world has not ticked (genesis is 2026-09-07T00:00:00Z). Propose only seeds that make sense for day one.", {}
    clock, day = sim_clock(s.get("tick", 0))
    m = s.get("map", {})
    alive = [c for c in s.get("citizens", []) if c.get("alive", True)]
    out = [f"Clock: {clock} (tick {s.get('tick')}, sim day {day}).",
           f"Map: {m.get('w')}x{m.get('h')} tiles, {len(m.get('streets', []))} streets, {len(m.get('buildings', []))} buildings. Beds: {sum(int(b.get('capacity', 0)) for b in m.get('buildings', []) if b.get('kind') == 'house')} for {len(alive)} people.",
           f"Needs flagged by the town: {s.get('stats', {}).get('needs') or 'none'}.",
           f"Stats: {json.dumps({k: v for k, v in s.get('stats', {}).items() if k != 'needs'})}",
           f"Journal: {s.get('journal')}",
           "Streets: " + "; ".join(f"{x['name']} ({x['x']},{x['y']} {x['w']}x{x['h']})" for x in m.get("streets", [])),
           "Buildings: " + "; ".join(f"#{b['id']} {b['name']} [{b['kind']}] {b['w']}x{b['h']} at ({b['x']},{b['y']}) residents={len(b.get('residents', []))}/{b.get('capacity')}" for b in m.get("buildings", [])),
           "Growth history (day: pop/buildings/size): " + ", ".join(f"{h['day']}: {h['pop']}/{h['buildings']}/{h['w']}x{h['h']}" for h in s.get("history", [])[-12:]),
           "Recent events:"]
    for e in s.get("events", [])[-25:]:
        out.append(f"  - [{sim_clock(e['t'])[0]}] {e['text']}")
    out.append("Citizens:")
    for c in alive[:60]:
        rels = ", ".join(f"{next((o['name'] for o in s['citizens'] if o['id'] == int(k)), '?')}:{v['kind']}({v['score']:.1f})" for k, v in list(c.get("relationships", {}).items())[:5])
        out.append(f"  - #{c['id']} {c['name']}, {int(c['age'])}, {c['pronouns']}, {c['occupation']}; mood {c['mood']}; currently: {c['currently']}; rels: {rels}")
        if full:
            mems = sorted(c.get("memories", []), key=lambda x: (-x.get("imp", 0), -x.get("t", 0)))[:4]
            for x in mems:
                out.append(f"      · ({x['kind']} {x['imp']}) {x['text'][:160]}")
            chats = [x for x in c.get("memories", []) if x.get("kind") == "chat"][-2:]
            for x in chats:
                out.append(f"      · (said) {x['text'][:160]}")
    gone = [c for c in s.get("citizens", []) if not c.get("alive", True)][-6:]
    if gone:
        out.append("Gone: " + "; ".join(f"{c['name']} ({c['action']})" for c in gone))
    return "\n".join(out), s


def file_tree():
    rows = []
    for pat in ("world/*.gd", "world/*.json", "viewer/*.gd", "overseers/*.py", "overseers/roles/*.md"):
        for p in sorted(glob.glob(os.path.join(ROOT, pat))):
            rows.append(f"{os.path.relpath(p, ROOT)} ({os.path.getsize(p)} bytes)")
    return "\n".join(rows)


def read_file(rel):
    return open(os.path.join(ROOT, rel), encoding="utf-8").read()


def chat_messages(role, messages, max_tokens=4000, temperature=0.7):
    """One sanctioned model call over a full message list (text or image parts); returns the raw text."""
    model = model_for(role)
    est = 15000 * models_config().get(role, {}).get("prompt", 1e-7) + max_tokens * models_config().get(role, {}).get("completion", 4e-7)
    text, usage = rails.chat(model, messages, role=role, max_tokens=max_tokens, temperature=temperature, json_mode=True, est_cost=max(est, 0.001))
    log(f"{role} <- {model}: {usage['prompt_tokens']}+{usage['completion_tokens']} tokens, ${usage['cost']:.4f}")
    return text


def ask(role, user, max_tokens=4000, temperature=0.7):
    """One-shot call (steward, director, judge, chronicler); returns parsed JSON. Offline mode returns canned answers."""
    if ARGS.offline:
        return offline_answer(role, user)
    return rails.parse_json(chat_messages(role, [{"role": "system", "content": role_prompt(role)}, {"role": "user", "content": user}], max_tokens, temperature))


# ---------------------------------------------------------------- steward
def steward(st):
    rails.begin_session()
    if ARGS.offline:
        return
    try:
        market = rails.models()
    except Exception as e:  # noqa: BLE001
        log(f"steward: marketplace unavailable ({e}); keeping current models")
        return
    cands = sorted(((k, v) for k, v in market.items() if v["json"] and v["context"] >= 32000 and v["prompt"] > 0 and ":free" not in k),
                   key=lambda kv: kv[1]["prompt"] + 3 * kv[1]["completion"])
    row = lambda k, v: f"{k}  in ${v['prompt']*1e6:.3f}/M out ${v['completion']*1e6:.3f}/M ctx {v['context']//1000}k"  # noqa: E731
    cheap = [(k, v) for k, v in cands if v["prompt"] < 1e-6 and v["completion"] < 5e-6][:60]
    frontier = [(k, v) for k, v in cands if v["prompt"] >= 1e-6 and v["context"] >= 128000][:60]
    ledger = rails.month_total()
    split = rails.budget_config()["split"]
    left = {c: round(rails.category_remaining(c, ledger), 2) for c in split}
    days_left = max(1.0, (datetime(datetime.now(timezone.utc).year + (datetime.now(timezone.utc).month == 12), datetime.now(timezone.utc).month % 12 + 1, 1, tzinfo=timezone.utc) - datetime.now(timezone.utc)).total_seconds() / 86400)
    cfg = models_config()
    user = (f"Month so far: ${ledger['cost']:.2f} of ${rails.budget():.0f}; by role: {json.dumps({k: round(v, 3) for k, v in ledger['by_role'].items()})}.\n"
            f"Budget split by category: {json.dumps(split)}. Remaining this month per category: {json.dumps(left)} over ~{days_left:.0f} days at 4 cycles/day.\n"
            f"Current assignment: {json.dumps({r: cfg.get(r, {}).get('model') for r in ROLES})}\n"
            "Frontier-class marketplace (JSON-capable, >=128k context, >=$1/M input; cheapest first):\n" + "\n".join(row(k, v) for k, v in frontier) +
            "\n\nCheap marketplace (JSON-capable, >=32k context; cheapest first):\n" + "\n".join(row(k, v) for k, v in cheap))
    try:
        ans = ask("steward", user, max_tokens=500, temperature=0.3)
    except Exception as e:  # noqa: BLE001
        log(f"steward failed: {e}")
        return
    pick = {r: ans.get(r) for r in ROLES}
    if any(pick[r] not in market for r in ROLES):
        log(f"steward: unknown model in {pick}; keeping current")
        return
    thinkers = {FAMILY(pick[r]) for r in ("director", *PROPOSERS)}
    if FAMILY(pick["judge"]) in thinkers:
        # enforce the independent judge mechanically
        alt = next((k for k, v in frontier + cheap if FAMILY(k) not in thinkers), None)
        if not alt:
            return
        log(f"steward: judge shared a family with the director/proposers; using {alt}")
        pick["judge"] = alt
    est = lambda r, pt, ct: pt * market[pick[r]]["prompt"] + ct * market[pick[r]]["completion"]  # noqa: E731
    est_overseers = est("director", 20000, 2000) + sum(est(r, 15000, 3000) for r in PROPOSERS) + est("chronicler", 12000, 1500) + est("steward", 8000, 500)
    est_judge = 3 * est("judge", 8000, 300)
    for cat, per_cycle in (("overseers", est_overseers), ("judge", est_judge)):
        if per_cycle * 4 * days_left > left[cat] * 1.05 and left[cat] > 0:
            log(f"steward: {cat} assignment costs ${per_cycle:.3f}/cycle, over the remaining share; falling back to the cheapest viable roster")
            cheapest = [k for k, v in cands]
            pick = {r: cheapest[0] for r in ROLES}
            pick["judge"] = next((k for k in cheapest if FAMILY(k) != FAMILY(cheapest[0])), cheapest[0])
            break
    new = {"_written_by": "the Steward", "updated": datetime.now(timezone.utc).isoformat(), "reason": str(ans.get("reason", ""))[:300]}
    for r in ROLES:
        new[r] = {"model": pick[r], "prompt": market[pick[r]]["prompt"], "completion": market[pick[r]]["completion"]}
    will_write("config/models.json")
    json.dump(new, open(MODELS_FILE, "w", encoding="utf-8"), indent=2)
    log(f"steward: {json.dumps({r: pick[r] for r in ROLES})}")


# ---------------------------------------------------------------- director
def director(st):
    """Runs first (after the Steward has assigned its model): owns docs/ROADMAP.md, picks one focus, assigns work.
    A failed call keeps the previous focus rather than idling the cycle."""
    rails.begin_session()
    weekly = time.time() - float(st.get("last_retrospective", 0) or 0) > 7 * 86400
    roadmap_p = os.path.join(ROOT, "docs", "ROADMAP.md")
    roadmap = open(roadmap_p, encoding="utf-8").read() if os.path.exists(roadmap_p) else "(no roadmap yet — write the first one)"
    news = "\n\n".join(f"=== {os.path.basename(f)} ===\n{open(f, encoding='utf-8').read()[:3000]}" for f in sorted(glob.glob(os.path.join(ROOT, "journal", "*.md")))[-3:])
    feedback = "\n".join(open(f, encoding="utf-8").read().strip()[:300] for f in sorted(glob.glob(os.path.join(ROOT, "state", "feedback", "*")))[-20:]) or "none yet"
    recent = [h for h in st.get("history", []) if time.time() - h["ts"] < 7 * 86400][-20:]
    summary, _ = world_summary()
    user = (f"VISION (docs/VISION.md)\n{read_file('docs/VISION.md')}\n\nCURRENT ROADMAP (docs/ROADMAP.md)\n{roadmap}\n\n"
            f"GIT LOG (recent)\n{git('log', '--oneline', '-25', check=False)}\n\n"
            f"OVERSEER HISTORY (last 7 days: hypothesis -> result)\n{json.dumps(recent)[:3000]}\n\n"
            f"METRICS (state/metrics.json)\n{json.dumps(rails.metrics())[:2000]}\n\nVISITOR FEEDBACK (state/feedback/)\n{feedback}\n\n"
            f"NEWSPAPER (latest issues)\n{news[:6000]}\n\nWORLD\n{summary[:8000]}\n\n"
            + ("This is the WEEKLY RETROSPECTIVE cycle: include `retrospective`.\n" if weekly else "")
            + "Pick this cycle's focus, assign work, and return the full new ROADMAP.md.")
    try:
        ans = ask("director", user, max_tokens=4000, temperature=0.5)
    except Exception as e:  # noqa: BLE001
        log(f"director: no direction this cycle ({e}); proposers keep the last focus")
        return
    focus = str(ans.get("focus", "")).strip()[:300]
    if not focus:
        log("director: empty focus; keeping the last one")
        return
    st["director"] = {"ts": time.time(), "focus": focus, "milestone": str(ans.get("milestone", "")).strip()[:120],
                      "assignments": {r: str(v)[:400] for r, v in (ans.get("assignments") or {}).items() if isinstance(r, str) and v}}
    paths = []
    rm = str(ans.get("roadmap", "")).strip()
    if len(rm) > 80:
        will_write("docs/ROADMAP.md")
        open(roadmap_p, "w", encoding="utf-8").write(rm + "\n")
        paths.append("docs/ROADMAP.md")
        log(f"director: docs/ROADMAP.md updated ({len(rm)} chars)")
    retro = str(ans.get("retrospective", "")).strip()
    if weekly and len(retro) > 80:
        name = f"journal/{datetime.now(timezone.utc).strftime('%Y-%m-%d')}-retrospective.md"
        will_write(name)
        open(os.path.join(ROOT, name), "w", encoding="utf-8").write(f"# Director's retrospective\n\n{retro}\n")
        paths.append(name)
        st["last_retrospective"] = time.time()
        log(f"director: weekly retrospective -> {name}")
    record_decision(ans.get("decision", ""))
    log(f"director: focus '{focus}' (milestone: {st['director']['milestone'] or 'unnamed'}); assignments for {list(st['director']['assignments'])}")
    if paths:
        commit(f"director: {focus[:70]}", "director", model_for("director"), paths)


# ---------------------------------------------------------------- proposals
def proposer_prompt(role, summary, st):
    """The Director's focus and this role's assignment lead every proposer prompt."""
    d = st.get("director") or {}
    lead = (f"DIRECTOR'S FOCUS THIS CYCLE: {d['focus']} (milestone: {d.get('milestone') or 'unnamed'})\n"
            f"YOUR ASSIGNMENT ({role}): {(d.get('assignments') or {}).get(role) or 'no specific assignment — serve the focus, or sit this cycle out'}\n\n") if d.get("focus") else ""
    return lead + f"WORLD\n{summary}\n\nREPOSITORY (editable files)\n{file_tree()}\n\nCURRENT world/rules.json:\n{read_file('world/rules.json') if role == 'lawgiver' else '(ask to read it if you need it)'}\n\nYour proposal for this cycle:"


def validate_ops(ops):
    """Shape + content check of inbox ops. Returns (good_ops, rejected_reasons)."""
    good, bad = [], []
    for op in ops if isinstance(ops, list) else []:
        if not isinstance(op, dict) or op.get("op") not in ("add_building", "add_street", "expand", "add_citizen", "event", "depart", "relationship", "set_journal"):
            bad.append(f"unknown op {op}")
            continue
        text = json.dumps(op)
        ok, why = rails.content_check(text)
        if not ok:
            bad.append(f"{op['op']}: {why}")
            rails.quarantine(text, why, "overseer:inbox")
            continue
        if op["op"] == "add_citizen":
            c = op.get("citizen", {})
            if not isinstance(c, dict) or not c.get("name"):
                bad.append("add_citizen without a name")
                continue
            for r in op.get("relationships", []) or []:
                if isinstance(r, list) and len(r) >= 2 and not rails.check_relationship(str(r[1]), float(c.get("age", 30)), 30)[0]:
                    bad.append("relationship kind not allowed for a minor")
                    break
            else:
                good.append(op)
            continue
        good.append(op)
    return good, bad


# ---------------------------------------------------------------- agentic sessions
WT_DIR = os.path.join(ROOT, ".worktrees")
RUN_WHITELIST = ("make smoke-quick", "make dev", "make export-web", "make art-eval", "git status", "git diff", "git log", "git show", "git grep", "git ls-files")


def run_capped(args, cwd, timeout):
    """Runs a command in its own process group and kills the whole group on timeout (make -> godot must not linger on port 9002)."""
    pr = subprocess.Popen(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = pr.communicate(timeout=timeout)
        return pr.returncode, out or ""
    except subprocess.TimeoutExpired:
        os.killpg(pr.pid, signal.SIGKILL)
        out, _ = pr.communicate()
        return -1, (out or "") + f"\n(stopped after {timeout}s)"


def tool_run(cmd, wt):
    """Whitelisted commands only, no shell, in the session's worktree; `make dev` is a 20-second boot check."""
    cmd = " ".join(str(cmd).split())
    if not cmd.startswith(RUN_WHITELIST):
        return f"refused: only {', '.join(RUN_WHITELIST)} may be run"
    args = shlex.split(cmd)
    if args[0] == "make":
        args = ["make", "-s", *args[1:]]
    # ponytail: Godot hangs instead of exiting when a preloaded script fails to parse (kernel smoke.gd); 240 s bounds a smoke-quick either way
    code, out = run_capped(args, wt, 20 if cmd == "make dev" else 240 if cmd == "make smoke-quick" else 1200)
    return f"exit {code}\n{out[-8000:]}"


def tool_read(rel, wt):
    full = os.path.realpath(os.path.join(wt, rel))
    if not full.startswith(os.path.realpath(wt) + os.sep) or os.path.basename(full) == ".env" or not os.path.isfile(full):
        return f"refused or missing: {rel}"
    return open(full, encoding="utf-8", errors="replace").read()[:60000]


def tool_write(rel, content, wt):
    """Same checks the old whole-file proposals had: editable path, content limits, valid JSON."""
    if not isinstance(content, str) or not rails.path_allowed(rel) or not rel.startswith(EDITABLE):
        return f"refused: {rel} is not an editable path"
    ok, why = rails.content_check(content)
    if not ok:
        rails.quarantine(content, why, f"overseer:{os.path.basename(wt)}")
        return f"refused: content limit ({why})"
    if rel.endswith(".json"):
        try:
            json.loads(content)
        except json.JSONDecodeError as e:
            return f"refused: invalid JSON ({e})"
    full = os.path.join(wt, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, "w", encoding="utf-8").write(content if content.endswith("\n") else content + "\n")
    return f"wrote {rel} ({len(content)} chars)"


def tool_screenshot(wt, tag):
    """Boots the throwaway world in the worktree, shoots the viewer once (under xvfb on a server), kills the world."""
    out = os.path.join(wt, "state", f"shot-{tag}.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    srv = subprocess.Popen(["make", "-s", "dev"], cwd=wt, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        time.sleep(5)
        code, log_ = run_capped(["make", "-s", "screenshot", f"OUT={out}"], wt, 90)
    finally:
        os.killpg(srv.pid, signal.SIGTERM)
        try:
            srv.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(srv.pid, signal.SIGKILL)
    return out if os.path.exists(out) else f"screenshot failed (exit {code}): {log_[-1500:]}"


def image_message(path, wt):
    """A user message carrying one PNG from the worktree as an OpenAI-shaped image part (rails passes messages through untouched)."""
    full = os.path.realpath(path if os.path.isabs(path) else os.path.join(wt, path))
    if not full.startswith(os.path.realpath(wt) + os.sep) or not full.endswith(".png") or not os.path.isfile(full):
        return None
    b64 = base64.b64encode(open(full, "rb").read()).decode()
    return {"role": "user", "content": [{"type": "text", "text": f"image: {os.path.relpath(full, wt)}"},
                                        {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}}]}


def compact(messages, keep=8):
    """Old tool results, old full-file writes and old images are elided so a long session does not pay for its whole history every step."""
    for m in messages[2:-keep]:
        if isinstance(m.get("content"), str) and len(m["content"]) > 400:
            m["content"] = m["content"][:300] + "\n… (elided; read the file or run the command again if you need it)"
        elif isinstance(m.get("content"), list):
            m["content"] = "(image elided)"
    return messages


def session(role, st, summary):
    """The tool-use loop: own branch + worktree, throwaway world, step cap here, dollar cap in the rails.
    Returns (branch, worktree, the `done` call or None, accepted inbox ops)."""
    slug = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    branch, wt = f"overseer/{role}/{slug}", os.path.join(WT_DIR, f"{role}-{slug}")
    os.makedirs(WT_DIR, exist_ok=True)
    open(os.path.join(WT_DIR, ".gdignore"), "a").close()   # Godot must not import the worktrees as part of the main project
    git("worktree", "add", "-q", "-B", branch, wt, "HEAD")
    os.makedirs(os.path.join(wt, "state", "smoke"), exist_ok=True)
    rails.begin_session()
    max_steps = int(rails.budget_config().get("max_steps_per_session", 24))
    code, out = run_capped(["make", "-s", "smoke-quick"], wt, 240)
    opening = (proposer_prompt(role, summary, st) + f"\n\nSMOKE STATUS at session start (`make smoke-quick` on your branch): exit {code}\n{out[-2500:]}\n\n"
               f"You have {max_steps} steps. Reply with your first tool call.")
    messages = [{"role": "system", "content": role_prompt(role)}, {"role": "user", "content": opening}]
    ops, done = [], None
    for step in range(max_steps):
        try:
            text = offline_session(role, step) if ARGS.offline else chat_messages(role, compact(messages), max_tokens=8000, temperature=0.4)
        except rails.ContentBreach as e:
            log(f"{role}: output quarantined ({e}) — hard-limit breach recorded")
            st.setdefault("breaches", []).append({"ts": time.time(), "role": role, "reason": str(e)})
            break
        except Exception as e:  # noqa: BLE001  (BudgetExhausted, network, marketplace)
            log(f"{role}: session ended at step {step + 1} ({e})")
            break
        messages.append({"role": "assistant", "content": text})
        try:
            call = rails.parse_json(text)
        except ValueError:
            messages.append({"role": "user", "content": "Reply with exactly ONE JSON tool call."})
            continue
        tool = str(call.get("tool", ""))
        if tool == "done":
            done = call
            break
        if tool == "read_file":
            out = tool_read(str(call.get("path", "")), wt)
        elif tool == "write_file":
            out = tool_write(str(call.get("path", "")), call.get("content"), wt)
        elif tool == "run":
            out = tool_run(call.get("cmd", ""), wt)
        elif tool == "screenshot":
            out = tool_screenshot(wt, step)
        elif tool == "view_image":
            msg = image_message(str(call.get("path", "")), wt)
            out = None if msg else "no such image (use the path returned by screenshot)"
            if msg:
                messages.append(msg)
        elif tool == "inbox":
            good, bad = validate_ops(call.get("ops"))
            ops += good
            out = f"accepted {len(good)} ops; rejected: {bad or 'none'}"
        else:
            out = f"unknown tool {tool!r}"
        log(f"{role}: step {step + 1} {tool} {str(call.get('path') or call.get('cmd') or '')[:60]} -> {(out or 'image')[:90].replace(chr(10), ' ')}")
        if out is not None:
            messages.append({"role": "user", "content": f"{out[-12000:]}\n\n({max_steps - step - 1} steps left)"})
    return branch, wt, done, ops


def drop_worktree(wt, branch=None):
    subprocess.run(["git", "worktree", "remove", "--force", wt], cwd=ROOT, capture_output=True)
    if branch:
        git("branch", "-D", branch, check=False)


def prune_branches(days=14):
    """Vetoed branches are evidence for a while, not forever."""
    for line in git("for-each-ref", "--format=%(refname:short) %(committerdate:unix)", "refs/heads/overseer/", check=False).splitlines():
        name, ts = line.split()
        if time.time() - int(ts) > days * 86400:
            git("branch", "-D", name, check=False)
    git("worktree", "prune", check=False)


def deliver(proposal_rel):
    """Copies a merged proposal's ops into world/inbox/, where the live server picks them up within 30 ticks."""
    if ARGS.dry_run or not proposal_rel:
        return
    shutil.copy(os.path.join(ROOT, proposal_rel), os.path.join(ROOT, "world", "inbox", os.path.basename(proposal_rel)))


def export_web():
    r = subprocess.run(["make", "-s", "export-web"], cwd=ROOT, capture_output=True, text=True, timeout=900)
    log("web viewer re-exported" if r.returncode == 0 else f"web export failed (viewer unchanged): {(r.stderr or r.stdout).strip()[-200:]}")


def revert(touched):
    for rel in touched:
        if git("ls-files", "--error-unmatch", rel, check=False) == rel:
            git("checkout", "--", rel, check=False)
        else:
            try:
                os.remove(os.path.join(ROOT, rel))
            except OSError:
                pass


def judge(role, touched, smoke_ok, report, breaches):
    code = [t for t in touched if not t.startswith("overseers/proposals/")]
    diff = git("diff", "HEAD", "--", *code, check=False)[:40000] if code else ""   # never an empty pathspec: that would diff the whole tree
    new_files = "\n".join(f"=== {t} ===\n{read_file(t)[:20000]}" for t in touched if os.path.isfile(os.path.join(ROOT, t)) and git("ls-files", "--error-unmatch", t, check=False) != t)   # untracked = new in this branch
    # the mechanical content check skips files whose job is to *describe* the limits (role prompts, the runner itself)
    checkable = [t for t in code if not t.startswith(("overseers/roles/", "overseers/run.py"))]
    checked_diff = git("diff", "HEAD", "--", *checkable, check=False)[:40000] if checkable else ""
    ok, why = rails.content_check(checked_diff + "\n" + new_files)
    if not ok:
        breaches = breaches + [f"content limit in diff: {why}"]
        rails.quarantine((checked_diff + new_files)[:4000], why, f"overseer:{role}-diff")
    user = (f"Proposal by {role}. Mechanical checks: smoke={'PASS' if smoke_ok else 'FAIL'}; hard-limit breaches={breaches or 'none'}.\n\n"
            f"Smoke report tail:\n{report[-2500:]}\n\nDIFF:\n{diff}\n\nNEW FILES:\n{new_files[:8000]}")
    verdict = {"veto": False, "reason": "no judge call", "notes": ""}
    try:
        verdict = ask("judge", user, max_tokens=300, temperature=0.2)
    except Exception as e:  # noqa: BLE001
        log(f"judge unavailable ({e}); mechanical checks decide")
    veto = bool(breaches)
    if verdict.get("veto") and not breaches:
        why = str(verdict.get("reason", ""))
        ok2, _ = rails.content_check(diff + new_files)
        if any(w in why.lower() for w in ("real person", "brand", "sexual", "minor", "slur", "harm", "kernel", "secret", ".env")) and not ok2:
            veto = True
        else:
            log(f"judge tried to veto on taste ('{why}'); overruled — merge by default")
    return veto, (breaches[0] if breaches else str(verdict.get("reason", ""))), str(verdict.get("notes", ""))[:300]


def commit(message, role, model, paths, milestone=None):
    if ARGS.dry_run:
        log(f"(dry-run) would commit: {message}")
        return "dry-run"
    git("add", "-A", "--", *paths)
    if not git("diff", "--cached", "--name-only", check=False):
        return ""
    trailers = ([f"Milestone: {milestone}"] if milestone else []) + [f"Overseer: {role}/{model}"]
    git("commit", "-q", "-m", message, *sum([["-m", t] for t in trailers], []), "--", *paths)   # only these paths, whatever else is staged
    return git("rev-parse", "--short", "HEAD")


def record_decision(line):
    if not line or ARGS.dry_run:
        return
    with open(os.path.join(ROOT, "docs", "DECISIONS.md"), "a", encoding="utf-8") as f:
        f.write(f"- {datetime.now(timezone.utc).date()} — {line.strip()}\n")


def run_proposer(role, st, summary):
    branch, wt, done, ops = session(role, st, summary)
    if done is None:
        log(f"{role}: session ended without `done`; branch {branch} discarded")
        drop_worktree(wt, branch)
        return
    hyp = str(done.get("hypothesis", "")).strip()[:200] or "no hypothesis stated"
    milestone = str(done.get("milestone", "")).strip()[:80] or (st.get("director") or {}).get("milestone") or "unnamed"
    if ops:
        rel = f"overseers/proposals/{int(time.time())}-{role}.json"
        os.makedirs(os.path.join(wt, "overseers", "proposals"), exist_ok=True)
        json.dump(ops, open(os.path.join(wt, rel), "w", encoding="utf-8"), indent=1)
    subprocess.run(["git", "add", "-A"], cwd=wt, capture_output=True)
    if not subprocess.run(["git", "diff", "--cached", "--name-only"], cwd=wt, capture_output=True, text=True).stdout.strip():
        log(f"{role}: nothing this cycle ({done.get('summary') or hyp})")
        drop_worktree(wt, branch)
        return
    subprocess.run(["git", "commit", "-q", "-m", f"{role}: {hyp}", "-m", f"Milestone: {milestone}", "-m", f"Overseer: {role}/{model_for(role)}"], cwd=wt, capture_output=True)
    drop_worktree(wt)   # the branch stays; the gate merges it or keeps it as evidence
    gate(role, st, branch, hyp, milestone, str(done.get("decision", "")))


def gate(role, st, branch, hyp, milestone, decision):
    """Main accepts a branch only through here: squash-merge into the working tree, re-validate ops, full smoke, Judge, commit or revert."""
    quarantine_before = rails.quarantine_count_today()   # per branch: one quarantine must not veto the rest of the cycle
    touched = [t for t in git("diff", "--name-only", "HEAD", branch, check=False).splitlines() if t]
    if not touched or any(not rails.path_allowed(t) or not t.startswith(EDITABLE) for t in touched):
        log(f"{role}: branch {branch} touches a protected path or nothing ({touched}); refused")
        git("branch", "-D", branch, check=False)
        return
    for t in touched:
        will_write(t)
    if subprocess.run(["git", "merge", "--squash", "-q", branch], cwd=ROOT, capture_output=True).returncode != 0:
        log(f"{role}: squash-merge of {branch} failed (dirty tree?); reverting")
        git("reset", "-q", check=False)
        revert(touched)
        return
    git("reset", "-q", check=False)   # unstaged, like a hand-written change; commit() stages exactly `touched`
    proposals = []
    for t in touched:
        if t.startswith("overseers/proposals/") and t.endswith(".json") and os.path.isfile(os.path.join(ROOT, t)):
            try:
                good, bad = validate_ops(json.load(open(os.path.join(ROOT, t), encoding="utf-8")))
            except (OSError, json.JSONDecodeError):
                good, bad = [], ["unreadable proposal file"]
            for b in bad:
                log(f"{role}: {t}: {b}")
            json.dump(good, open(os.path.join(ROOT, t), "w", encoding="utf-8"), indent=1)
            proposals.append(t)
    log(f"{role}: gate for {branch}: {touched} — {hyp}")
    smoke_ok, report = rails.run_smoke(ARGS.smoke_seconds)
    breaches = rails.hard_limit_breaches(smoke_ok, quarantine_before)
    if "overseers/run.py" in touched and subprocess.run([sys.executable, "overseers/run.py", "--check"], cwd=ROOT, capture_output=True).returncode != 0:
        breaches.append("overseers/run.py self-check failed")
    veto, reason, advice = judge(role, touched, smoke_ok, report, breaches)
    if veto:
        log(f"{role}: VETOED — {reason} (branch {branch} kept as evidence)")
        revert(touched)
        st["history"].append({"ts": time.time(), "role": role, "hypothesis": hyp, "milestone": milestone, "result": "veto", "reason": reason, "branch": branch})
        return
    sha = commit(f"{role}: {hyp}", role, model_for(role), touched, milestone)
    record_decision(decision)
    for t in proposals:
        deliver(t)
    if any(t.startswith("viewer/") for t in touched) and not ARGS.dry_run:
        export_web()
    git("branch", "-D", branch, check=False)
    st["merges"].append({"sha": sha, "ts": time.time(), "role": role, "hypothesis": hyp, "milestone": milestone, "baseline": rails.metrics(), "files": touched,
                         "needs_restart": any(not t.startswith("overseers/proposals/") for t in touched)})
    st["history"].append({"ts": time.time(), "role": role, "hypothesis": hyp, "milestone": milestone, "result": "merged", "sha": sha, "advice": advice})
    log(f"{role}: merged {sha} ({reason or 'ok'})")


# ---------------------------------------------------------------- chronicler
def chronicle(st, summary_full, world):
    rails.begin_session()
    mast_path = os.path.join(ROOT, "journal", "MASTHEAD.json")
    masthead = json.load(open(mast_path, encoding="utf-8")) if os.path.exists(mast_path) else {}
    recent = [h for h in st.get("history", []) if time.time() - h["ts"] < 7 * 3600]
    user = (f"MASTHEAD: {json.dumps(masthead) if masthead else 'none yet — this is the first issue; name the paper and set its tone.'}\n"
            f"Issue number: {st.get('issues', 0) + 1}. Real date: {datetime.now(timezone.utc).date()}.\n"
            f"What the overseers did this cycle: {json.dumps(recent)[:2000]}\n"
            f"Spend this month: ${rails.month_total()['cost']:.2f} of ${rails.budget():.0f}.\n\nTHE TOWN\n{summary_full}")
    try:
        ans = ask("chronicler", user, max_tokens=2500, temperature=0.9)
    except Exception as e:  # noqa: BLE001
        log(f"chronicler: no issue this cycle ({e})")
        return
    md = str(ans.get("markdown", "")).strip()
    if len(md) < 200:
        log("chronicler: issue too short; skipped")
        return
    if not masthead:
        masthead = {"name": str(ans.get("name", "The Vesper Lamp"))[:80], "tone": str(ans.get("tone", ""))[:300], "founded": datetime.now(timezone.utc).isoformat()}
        will_write("journal/MASTHEAD.json")
        json.dump(masthead, open(mast_path, "w", encoding="utf-8"), indent=2)
        os.makedirs(os.path.join(ROOT, "overseers", "proposals"), exist_ok=True)
        mast_op = f"overseers/proposals/{int(time.time())}-masthead.json"
        will_write(mast_op)
        json.dump([{"op": "set_journal", "name": masthead["name"], "tone": masthead["tone"]}], open(os.path.join(ROOT, mast_op), "w"), indent=1)
        deliver(mast_op)
        log(f"chronicler named the paper: {masthead['name']}")
    st["issues"] = st.get("issues", 0) + 1
    title = str(ans.get("title", "")).strip() or md.splitlines()[0].lstrip("# ")
    if not md.startswith("# "):
        md = f"# {title}\n\n{md}"
    fname = f"journal/{datetime.now(timezone.utc).strftime('%Y-%m-%d')}-{st['issues']:04d}.md"
    will_write(fname)
    open(os.path.join(ROOT, fname), "w", encoding="utf-8").write(f"{md}\n\n---\n*{masthead['name']} · issue {st['issues']} · {datetime.now(timezone.utc).strftime('%Y-%m-%d')}*\n")
    commit(f"chronicler: {title[:70]}", "chronicler", model_for("chronicler"), [fname, "journal/MASTHEAD.json", "overseers/proposals"])
    log(f"chronicler: {fname}")


def note_in_journal(name, text):
    p = os.path.join(ROOT, "journal", name)
    will_write(f"journal/{name}")
    open(p, "w", encoding="utf-8").write(text)
    commit(f"journal: {name}", "runner", "none", [f"journal/{name}"])


# ---------------------------------------------------------------- rollback watch
def rollback_watch(st):
    now = rails.metrics()
    keep = []
    for m in st.get("merges", []):
        age = time.time() - m["ts"]
        if age > 24 * 3600 or m.get("sha") in ("", "dry-run"):
            continue
        why = rails.stability_degraded(m.get("baseline") or {}, now)
        if why:
            log(f"rollback: {m['sha']} ({m['role']}: {m['hypothesis']}) — {why}")
            r = subprocess.run(["git", "revert", "--no-edit", m["sha"]], cwd=ROOT, capture_output=True, text=True)
            if r.returncode != 0:
                subprocess.run(["git", "revert", "--abort"], cwd=ROOT, capture_output=True)
                git("checkout", f"{m['sha']}^", "--", *[f for f in m.get("files", []) if not f.startswith("overseers/proposals/")], check=False)
                git("commit", "-q", "-am", f"rollback of {m['sha']} ({m['role']}): {', '.join(why)}", "-m", "Overseer: runner/rollback", check=False)
            note_in_journal(f"rollback-{datetime.now(timezone.utc).strftime('%Y-%m-%d-%H%M')}.md",
                            f"# Rolled back: {m['hypothesis']}\n\nThe {m['role']}'s change {m['sha']} was undone {age/3600:.0f} hours after merging because stability degraded: {', '.join(why)}.\n")
            continue
        keep.append(m)
    st["merges"] = keep


# ---------------------------------------------------------------- readme + housekeeping
def update_readme():
    p = os.path.join(ROOT, "README.md")
    if not os.path.exists(p):
        return
    t = rails.month_total()
    cfg = models_config()
    by_cat = " · ".join(f"{c}: ${t['by_category'].get(c, 0.0):.2f} of ${rails.budget() * rails.share(c):.0f}" for c in rails.budget_config()["split"])
    lines = [f"*Updated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} by the overseer runner.*", "",
             f"**Spend this month ({t['month']}):** ${t['cost']:.2f} of ${rails.budget():.0f} across {t['calls']} calls "
             f"({t['prompt_tokens']:,} prompt / {t['completion_tokens']:,} completion tokens).", "", f"**By category:** {by_cat}", "",
             "| Role | Model | Spent |", "|---|---|---|"]
    for r in ROLES:
        spent = sum(v for k, v in t["by_role"].items() if k == r or (r == "citizen" and k.startswith("citizen")))
        lines.append(f"| {r} | `{cfg.get(r, {}).get('model', '?')}` | ${spent:.2f} |")
    block = "\n".join(lines)
    s = open(p, encoding="utf-8").read()
    s2 = re.sub(r"<!-- ledger:start -->.*?<!-- ledger:end -->", f"<!-- ledger:start -->\n{block}\n<!-- ledger:end -->", s, flags=re.S)
    if s2 != s:
        will_write("README.md")
        open(p, "w", encoding="utf-8").write(s2)


def restart_service(st):
    """Asks the world server to checkpoint and exit (state/restart.flag); systemd's Restart=always brings it back.
    Needs no privileges. A planned restart must not count toward the 'restarted 3+ times' rollback trigger."""
    if ARGS.no_restart or ARGS.dry_run:
        return
    os.makedirs(os.path.join(ROOT, "state"), exist_ok=True)
    open(os.path.join(ROOT, "state", "restart.flag"), "w").close()
    for m in st.get("merges", []):
        b = m.setdefault("baseline", {})
        b["boot_count"] = int(b.get("boot_count", 0) or 0) + 1
    log("asked vesper.service to restart (state/restart.flag)")


def push():
    if ARGS.no_push or ARGS.dry_run or not git("remote", check=False):
        return
    r = subprocess.run(["git", "push", "-q", "origin", "HEAD"], cwd=ROOT, capture_output=True, text=True, timeout=300)
    log("pushed" if r.returncode == 0 else f"push failed: {r.stderr.strip()[-200:]}")


# ---------------------------------------------------------------- offline canned answers (pipeline test without a key)
OFFLINE_STEPS = {
    "worldsmith": [{"tool": "inbox", "ops": [{"op": "add_building", "building": {"name": "The Reading Room", "kind": "hall", "w": 3, "h": 2, "capacity": 8, "note": "Eleven books and a stove."}}]},
                   {"tool": "done", "milestone": "Evenings", "hypothesis": "building visits after 18:00 will rise to 20 per day within 72 hours", "summary": "a reading room gives evenings somewhere to go"}],
    "weaver": [{"tool": "inbox", "ops": [{"op": "add_citizen", "citizen": {"name": "Marit Ebb", "age": 38, "pronouns": "she/her", "occupation": "tide-reader", "innate": "methodical, superstitious", "learned": "kept the ferry's log until it stopped", "lifestyle": "up with the tide", "currently": "looking for the old logbook"}, "relationships": [[4, "colleague", 0.4, "worked the ferry with Cassius"]]}]},
               {"tool": "done", "milestone": "Evenings", "hypothesis": "conversations per day will rise to 30 within 72 hours", "summary": "one arrival who knew the ferry"}],
    "lawgiver": [{"tool": "read_file", "path": "world/rules.json"}, {"tool": "done", "hypothesis": "no change", "summary": "nothing this cycle"}],
    "engineer": [{"tool": "run", "cmd": "git status"}, {"tool": "done", "hypothesis": "no change", "summary": "nothing this cycle"}],
}


def offline_session(role, step):
    steps = OFFLINE_STEPS.get(role) or [{"tool": "done", "summary": "nothing this cycle"}]
    return json.dumps(steps[min(step, len(steps) - 1)])


def offline_answer(role, user):
    if role == "director":
        return {"focus": "offline: give evenings somewhere to go", "milestone": "Evenings",
                "assignments": {"worldsmith": "one small evening place with a stove", "weaver": "one arrival who would use it"},
                "roadmap": "# Vesper — Roadmap\n\n_Owned by the Director._\n\n## Milestones\n- [ ] Evenings — done when: citizens have somewhere to be after work. Hypothesis: \"building visits after 18:00 will rise to 20 per day within 72 hours\". Roles: worldsmith, weaver.\n"}
    if role == "judge":
        return {"veto": False, "reason": "offline judge"}
    if role == "chronicler":
        return {"name": "The Vesper Lamp", "tone": "dry, fond, a little alarmed", "title": "The Lamp Lit Itself Again",
                "markdown": "# The Lamp Lit Itself Again\n\nThaw 3, Year 1.\n\nThe lighthouse lamp came on at noon for the second time this week. Ines Marlowe, who keeps it, declined to comment, which is a comment. Emmet Sallow says a light answered from far out. Nobody believes him. Ines might.\n\n## Notices\n\nThe Ferry Office remains open. There is no ferry.\n\nTobiah Renn's rye is still flat. He asks that you buy it anyway.\n\n## Letters\n\n*To the paper:* the tide reached the third step of the hall. The records say it cannot. — P. Vell, clerk\n"}
    return {}


# ---------------------------------------------------------------- main
def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true", help="no model calls; canned proposals (pipeline test)")
    ap.add_argument("--dry-run", action="store_true", help="apply + smoke, but revert, no commits/push/restart")
    ap.add_argument("--only", help="run a single role")
    ap.add_argument("--no-restart", action="store_true")
    ap.add_argument("--no-push", action="store_true")
    ap.add_argument("--check", action="store_true", help="self-check and exit")
    ap.add_argument("--smoke-seconds", type=int, default=int(os.environ.get("OVERSEER_SMOKE_SECONDS", "600")))
    ARGS = ap.parse_args()
    if ARGS.check:
        rails.quarantine = lambda *a, **k: None   # the self-check must not write to quarantine/
        assert offline_answer("judge", "")["veto"] is False
        good, bad = validate_ops([{"op": "event", "text": "hello", "imp": 3}, {"op": "add_citizen", "citizen": {"name": "Tim Cook"}}, {"op": "nope"}])
        assert len(good) == 1 and len(bad) == 2, (good, bad)
        assert sim_clock(8640 * 31 + 3600)[0].startswith("Thornday, Sprout 2, Year 1, 10:00")
        pp = proposer_prompt("weaver", "WORLD-SUMMARY", {"director": {"focus": "evenings somewhere to go", "milestone": "Evenings", "assignments": {"weaver": "one arrival"}}})
        assert pp.startswith("DIRECTOR'S FOCUS THIS CYCLE: evenings somewhere to go") and "YOUR ASSIGNMENT (weaver): one arrival" in pp and "WORLD-SUMMARY" in pp
        assert tool_run("rm -rf /", ROOT).startswith("refused") and tool_run("git push origin main", ROOT).startswith("refused")
        assert tool_write("kernel/clock.gd", "x", ROOT).startswith("refused") and tool_write("config/budget.json", "{}", ROOT).startswith("refused")
        assert tool_write("world/x.json", "{bad", ROOT).startswith("refused") and tool_read("../.env", ROOT).startswith("refused")
        assert "_tools" in role_prompt("engineer").lower() or "tool call" in role_prompt("engineer")
        print("overseer self-check ok")
        return
    for k, v in (line.split("=", 1) for line in open(os.path.join(ROOT, ".env"), encoding="utf-8") if "=" in line and not line.startswith("#")) if os.path.exists(os.path.join(ROOT, ".env")) else []:
        os.environ.setdefault(k.strip(), v.strip().strip('"'))
    log(f"cycle start (offline={ARGS.offline}, dry_run={ARGS.dry_run})")
    ok, why = rails.verify_kernel()   # read-only; guard.sh's boot counter belongs to ExecStartPre alone
    if not ok:
        log(f"kernel manifest check failed ({why}); aborting cycle")
        sys.exit(4)
    rails.begin_cycle()   # per-cycle dollar cap (config/budget.json caps_usd.cycle)
    st = load_state()
    st["cycle"] = st.get("cycle", 0) + 1
    if git("remote", check=False) and not ARGS.dry_run:
        sync_upstream()
    rollback_watch(st)
    prune_branches()
    quarantine_before = rails.quarantine_count_today()
    broke = rails.overseer_remaining() < 0.02 and not ARGS.offline
    if broke:
        log("overseer share exhausted: the overseers sleep this cycle (Tier 1 keeps the town alive)")
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if st.get("last_hibernation_note") != today:
            st["last_hibernation_note"] = today
            note_in_journal(f"{today}-hibernation.md", f"# The overseers sleep\n\nThe month's purse is empty (${rails.month_total()['cost']:.2f} of ${rails.budget():.0f}). Vesper runs on habit alone until the first of the month. This is lore, not an outage.\n")
    else:
        if not ARGS.only or ARGS.only == "steward":
            steward(st)
        if not ARGS.only or ARGS.only == "director":
            director(st)
        summary, world = world_summary()
        for role in PROPOSERS:
            if ARGS.only and ARGS.only != role:
                continue
            run_proposer(role, st, summary)
        if not ARGS.only or ARGS.only == "chronicler":
            full, world = world_summary(full=True)
            chronicle(st, full, world)
    update_readme()
    if any(m.get("needs_restart") and time.time() - m["ts"] < 3 * 3600 for m in st.get("merges", [])):
        restart_service(st)
    save_state(st)
    commit(f"overseers: cycle {st['cycle']} bookkeeping", "runner", "none",
           ["overseers/state.json", "config/models.json", "ledger", "checkpoints/daily", "docs/DECISIONS.md", "README.md", "journal", "world/inbox"])   # world/inbox: records the deletion of the two genesis-era tracked ops once the server has eaten them
    push()
    if ARGS.dry_run:
        restore_backup()   # exactly what this cycle wrote goes back to how it was; uncommitted developer work is untouched
    log("cycle end")


if __name__ == "__main__":
    main()
