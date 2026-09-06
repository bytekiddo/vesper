#!/usr/bin/env python3
"""Vesper overseers. One cycle: pull -> steward -> propose (worldsmith, weaver, lawgiver) -> apply -> smoke -> judge
-> commit -> chronicle -> rollback watch -> push -> restart. Merge by default; veto only on hard limits.
Everything here except kernel/rails.py is the overseers' own to reorganize."""
import argparse, glob, json, os, re, shutil, subprocess, sys, time
from datetime import datetime, timezone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "kernel"))
import rails  # noqa: E402  (frozen kernel: budget, ledger, content filter, model calls, hard limits)

STATE_FILE = os.path.join(ROOT, "overseers", "state.json")
MODELS_FILE = os.path.join(ROOT, "config", "models.json")
PROPOSERS = ["worldsmith", "weaver", "lawgiver"]
EDITABLE = ("world/", "viewer/", "overseers/", "ops/", "docs/", "README.md", "journal/", "config/", "Makefile", "setup.sh", "export_presets.cfg", "project.godot")
FAMILY = lambda mid: mid.split("/")[0]  # noqa: E731
ARGS = None
log = rails.log


# ---------------------------------------------------------------- plumbing
def sh(cmd, check=True, capture=True, timeout=1800):
    r = subprocess.run(cmd, cwd=ROOT, capture_output=capture, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {(r.stderr or r.stdout)[-500:]}")
    return (r.stdout or "").strip()


def git(*args, check=True):
    return sh(["git", *args], check=check)


def load_state():
    try:
        return json.load(open(STATE_FILE, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"cycle": 0, "merges": [], "issues": 0, "history": [], "last_hibernation_note": ""}


def save_state(st):
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
    proto = open(os.path.join(ROOT, "overseers", "roles", "_protocol.md"), encoding="utf-8").read()
    body = open(os.path.join(ROOT, "overseers", "roles", f"{role}.md"), encoding="utf-8").read()
    return body + "\n\n" + proto


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


def ask(role, user, max_tokens=4000, temperature=0.7):
    """One sanctioned model call; returns parsed JSON. Offline mode returns canned answers."""
    if ARGS.offline:
        return offline_answer(role, user)
    model = model_for(role)
    est = 15000 * models_config().get(role, {}).get("prompt", 1e-7) + max_tokens * models_config().get(role, {}).get("completion", 4e-7)
    text, usage = rails.chat(model, [{"role": "system", "content": role_prompt(role)}, {"role": "user", "content": user}],
                             role=role, max_tokens=max_tokens, temperature=temperature, json_mode=True, est_cost=max(est, 0.001))
    log(f"{role} <- {model}: {usage['prompt_tokens']}+{usage['completion_tokens']} tokens, ${usage['cost']:.4f}")
    return rails.parse_json(text)


# ---------------------------------------------------------------- steward
def steward(st):
    if ARGS.offline:
        return
    try:
        market = rails.models()
    except Exception as e:  # noqa: BLE001
        log(f"steward: marketplace unavailable ({e}); keeping current models")
        return
    cands = sorted(((v["prompt"], v["completion"], k, v) for k, v in market.items()
                    if v["json"] and v["context"] >= 32000 and 0 < v["prompt"] < 5e-6 and v["completion"] < 2e-5), key=lambda r: (r[0] + 3 * r[1]))
    rows = [f"{k}  in ${p*1e6:.3f}/M out ${c*1e6:.3f}/M ctx {v['context']//1000}k" for p, c, k, v in cands[:90]]
    ledger = rails.month_total()
    remaining = rails.overseer_remaining()
    days_left = max(1.0, (datetime(datetime.now(timezone.utc).year + (datetime.now(timezone.utc).month == 12), datetime.now(timezone.utc).month % 12 + 1, 1, tzinfo=timezone.utc) - datetime.now(timezone.utc)).total_seconds() / 86400)
    cfg = models_config()
    user = (f"Month so far: ${ledger['cost']:.2f} of ${rails.budget():.0f}; by role: {json.dumps({k: round(v, 3) for k, v in ledger['by_role'].items()})}.\n"
            f"Overseer share remaining this month: ${remaining:.2f} over ~{days_left:.0f} days at 4 cycles/day. Citizens get 70% of the budget.\n"
            f"Current assignment: {json.dumps({r: cfg.get(r, {}).get('model') for r in ['citizen', *PROPOSERS, 'judge', 'chronicler', 'steward']})}\n"
            f"Marketplace (cheapest first, JSON-capable, >=32k context):\n" + "\n".join(rows))
    try:
        ans = ask("steward", user, max_tokens=400, temperature=0.3)
    except Exception as e:  # noqa: BLE001
        log(f"steward failed: {e}")
        return
    roles = ["citizen", "steward", "worldsmith", "weaver", "lawgiver", "judge", "chronicler"]
    pick = {r: ans.get(r) for r in roles}
    if any(pick[r] not in market for r in roles):
        log(f"steward: unknown model in {pick}; keeping current")
        return
    if FAMILY(pick["judge"]) in {FAMILY(pick[r]) for r in PROPOSERS}:
        # enforce the independent judge mechanically
        alt = next((k for p, c, k, v in cands if FAMILY(k) not in {FAMILY(pick[r]) for r in PROPOSERS}), None)
        if not alt:
            return
        log(f"steward: judge shared a family with proposers; using {alt}")
        pick["judge"] = alt
    est_cycle = sum(15000 * market[pick[r]]["prompt"] + 3000 * market[pick[r]]["completion"] for r in PROPOSERS) \
        + 3 * (8000 * market[pick["judge"]]["prompt"] + 300 * market[pick["judge"]]["completion"]) \
        + 12000 * market[pick["chronicler"]]["prompt"] + 1500 * market[pick["chronicler"]]["completion"]
    if est_cycle * 4 * days_left > remaining * 1.05 and remaining > 0:
        log(f"steward: assignment costs ${est_cycle:.3f}/cycle, over the remaining share; falling back to the cheapest viable roster")
        cheapest = [k for p, c, k, v in cands]
        pick = {r: cheapest[0] for r in roles}
        pick["judge"] = next((k for k in cheapest if FAMILY(k) != FAMILY(cheapest[0])), cheapest[0])
    new = {"_written_by": "the Steward", "updated": datetime.now(timezone.utc).isoformat(), "reason": str(ans.get("reason", ""))[:300]}
    for r in roles:
        new[r] = {"model": pick[r], "prompt": market[pick[r]]["prompt"], "completion": market[pick[r]]["completion"]}
    json.dump(new, open(MODELS_FILE, "w", encoding="utf-8"), indent=2)
    log(f"steward: {json.dumps({r: pick[r] for r in roles})}")


# ---------------------------------------------------------------- proposals
def propose(role, summary):
    user = f"WORLD\n{summary}\n\nREPOSITORY (editable files)\n{file_tree()}\n\nCURRENT world/rules.json:\n{read_file('world/rules.json') if role == 'lawgiver' else '(ask to read it if you need it)'}\n\nYour proposal for this cycle:"
    ans = ask(role, user)
    if isinstance(ans, dict) and ans.get("read") and not ans.get("files") and not ans.get("inbox"):
        wanted = [p for p in ans["read"] if isinstance(p, str) and rails.path_allowed(p) and os.path.isfile(os.path.join(ROOT, p))][:4]
        shown = "\n\n".join(f"=== {p} ===\n{read_file(p)[:60000]}" for p in wanted)
        ans = ask(role, user + f"\n\nYou asked to read files. Here they are:\n{shown}\n\nNow give your final proposal (no more `read`).")
    return ans if isinstance(ans, dict) else {}


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


def apply_proposal(role, prop):
    """Writes files and the inbox file. Returns (touched paths, inbox path or None, rejected notes)."""
    touched, notes = [], []
    for rel, content in (prop.get("files") or {}).items():
        if not isinstance(content, str) or not rails.path_allowed(rel) or not rel.startswith(EDITABLE):
            notes.append(f"refused file {rel}")
            continue
        ok, why = rails.content_check(content)
        if not ok:
            notes.append(f"content: {rel}: {why}")
            rails.quarantine(content, why, f"overseer:{role}")
            continue
        if rel.endswith(".json"):
            try:
                json.loads(content)
            except json.JSONDecodeError as e:
                notes.append(f"{rel}: invalid JSON ({e})")
                continue
        full = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        open(full, "w", encoding="utf-8").write(content if content.endswith("\n") else content + "\n")
        touched.append(rel)
    inbox = None
    good, bad = validate_ops(prop.get("inbox") or [])
    notes += bad
    if good:
        inbox = f"world/inbox/{int(time.time())}-{role}.json"
        json.dump(good, open(os.path.join(ROOT, inbox), "w", encoding="utf-8"), indent=1)
        touched.append(inbox)
    return touched, inbox, notes


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
    diff = git("diff", "--", *[t for t in touched if not t.startswith("world/inbox/")], check=False)[:40000]
    new_files = "\n".join(f"=== {t} ===\n{read_file(t)[:20000]}" for t in touched if t.startswith("world/inbox/"))
    ok, why = rails.content_check(diff + "\n" + new_files)
    if not ok:
        breaches = breaches + [f"content limit in diff: {why}"]
        rails.quarantine(diff[:4000], why, f"overseer:{role}-diff")
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


def commit(message, role, model, paths):
    if ARGS.dry_run:
        log(f"(dry-run) would commit: {message}")
        return "dry-run"
    git("add", "-A", "--", *paths)
    if not git("diff", "--cached", "--name-only", check=False):
        return ""
    git("commit", "-q", "-m", message, "-m", f"Overseer: {role}/{model}")
    return git("rev-parse", "--short", "HEAD")


def record_decision(line):
    if not line or ARGS.dry_run:
        return
    with open(os.path.join(ROOT, "docs", "DECISIONS.md"), "a", encoding="utf-8") as f:
        f.write(f"- {datetime.now(timezone.utc).date()} — {line.strip()}\n")


def run_proposer(role, st, summary, quarantine_before):
    try:
        prop = propose(role, summary)
    except rails.BudgetExhausted as e:
        log(f"{role}: {e}")
        return
    except rails.ContentBreach as e:
        log(f"{role}: output quarantined ({e}) — hard-limit breach recorded")
        st.setdefault("breaches", []).append({"ts": time.time(), "role": role, "reason": str(e)})
        return
    except Exception as e:  # noqa: BLE001
        log(f"{role}: no proposal ({e})")
        return
    hyp = str(prop.get("hypothesis", "")).strip()[:200] or "no hypothesis stated"
    touched, inbox, notes = apply_proposal(role, prop)
    for n in notes:
        log(f"{role}: {n}")
    if not touched:
        log(f"{role}: nothing to apply ({hyp})")
        return
    log(f"{role}: applying {touched} — {hyp}")
    smoke_ok, report = rails.run_smoke(ARGS.smoke_seconds)
    breaches = rails.hard_limit_breaches(smoke_ok, quarantine_before)
    veto, reason, advice = judge(role, touched, smoke_ok, report, breaches)
    if veto:
        log(f"{role}: VETOED — {reason}")
        revert(touched)
        st["history"].append({"ts": time.time(), "role": role, "hypothesis": hyp, "result": "veto", "reason": reason})
        return
    sha = commit(f"{role}: {hyp}", role, model_for(role), touched)
    record_decision(prop.get("decision", ""))
    st["merges"].append({"sha": sha, "ts": time.time(), "role": role, "hypothesis": hyp, "baseline": rails.metrics(), "files": touched})
    st["history"].append({"ts": time.time(), "role": role, "hypothesis": hyp, "result": "merged", "sha": sha, "advice": advice})
    log(f"{role}: merged {sha} ({reason or 'ok'})")


# ---------------------------------------------------------------- chronicler
def chronicle(st, summary_full, world):
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
        json.dump(masthead, open(mast_path, "w", encoding="utf-8"), indent=2)
        json.dump([{"op": "set_journal", "name": masthead["name"], "tone": masthead["tone"]}], open(os.path.join(ROOT, f"world/inbox/{int(time.time())}-masthead.json"), "w"), indent=1)
        log(f"chronicler named the paper: {masthead['name']}")
    st["issues"] = st.get("issues", 0) + 1
    title = str(ans.get("title", "")).strip() or md.splitlines()[0].lstrip("# ")
    if not md.startswith("# "):
        md = f"# {title}\n\n{md}"
    fname = f"journal/{datetime.now(timezone.utc).strftime('%Y-%m-%d')}-{st['issues']:04d}.md"
    open(os.path.join(ROOT, fname), "w", encoding="utf-8").write(f"{md}\n\n---\n*{masthead['name']} · issue {st['issues']} · {datetime.now(timezone.utc).strftime('%Y-%m-%d')}*\n")
    commit(f"chronicler: {title[:70]}", "chronicler", model_for("chronicler"), [fname, "journal/MASTHEAD.json", "world/inbox"])
    log(f"chronicler: {fname}")


def note_in_journal(name, text):
    p = os.path.join(ROOT, "journal", name)
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
                git("checkout", f"{m['sha']}^", "--", *[f for f in m.get("files", []) if not f.startswith("world/inbox/")], check=False)
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
    roles = ["citizen", "steward", "worldsmith", "weaver", "lawgiver", "judge", "chronicler"]
    lines = [f"*Updated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} by the overseer runner.*", "",
             f"**Spend this month ({t['month']}):** ${t['cost']:.2f} of ${rails.budget():.0f} across {t['calls']} calls "
             f"({t['prompt_tokens']:,} prompt / {t['completion_tokens']:,} completion tokens).", "", "| Role | Model | Spent |", "|---|---|---|"]
    for r in roles:
        spent = sum(v for k, v in t["by_role"].items() if k == r or (r == "citizen" and k.startswith("citizen")))
        lines.append(f"| {r} | `{cfg.get(r, {}).get('model', '?')}` | ${spent:.2f} |")
    block = "\n".join(lines)
    s = open(p, encoding="utf-8").read()
    s2 = re.sub(r"<!-- ledger:start -->.*?<!-- ledger:end -->", f"<!-- ledger:start -->\n{block}\n<!-- ledger:end -->", s, flags=re.S)
    if s2 != s:
        open(p, "w", encoding="utf-8").write(s2)


def restart_service():
    if ARGS.no_restart or ARGS.dry_run or not shutil.which("systemctl"):
        return
    r = subprocess.run(["sudo", "-n", "systemctl", "restart", "vesper"], capture_output=True, text=True)
    if r.returncode != 0:
        r = subprocess.run(["systemctl", "restart", "vesper"], capture_output=True, text=True)
    log("restarted vesper.service" if r.returncode == 0 else f"could not restart vesper.service: {r.stderr.strip()[:200]}")


def push():
    if ARGS.no_push or ARGS.dry_run or not git("remote", check=False):
        return
    r = subprocess.run(["git", "push", "-q", "origin", "HEAD"], cwd=ROOT, capture_output=True, text=True, timeout=300)
    log("pushed" if r.returncode == 0 else f"push failed: {r.stderr.strip()[-200:]}")


# ---------------------------------------------------------------- offline canned answers (pipeline test without a key)
def offline_answer(role, user):
    if role == "worldsmith":
        return {"hypothesis": "offline: a reading room gives evenings somewhere to go", "inbox": [{"op": "add_building", "building": {"name": "The Reading Room", "kind": "hall", "w": 3, "h": 2, "capacity": 8, "note": "Eleven books and a stove."}}]}
    if role == "weaver":
        return {"hypothesis": "offline: one arrival who knew the ferry", "inbox": [{"op": "add_citizen", "citizen": {"name": "Marit Ebb", "age": 38, "pronouns": "she/her", "occupation": "tide-reader", "innate": "methodical, superstitious", "learned": "kept the ferry's log until it stopped", "lifestyle": "up with the tide", "currently": "looking for the old logbook"}, "relationships": [[4, "colleague", 0.4, "worked the ferry with Cassius"]]}]}
    if role == "lawgiver":
        return {"hypothesis": "offline: no rule change"}
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
        assert offline_answer("judge", "")["veto"] is False
        good, bad = validate_ops([{"op": "event", "text": "hello", "imp": 3}, {"op": "add_citizen", "citizen": {"name": "Tim Cook"}}, {"op": "nope"}])
        assert len(good) == 1 and len(bad) == 2, (good, bad)
        assert sim_clock(8640 * 31 + 3600)[0].startswith("Thornday, Sprout 2, Year 1, 10:00")
        print("overseer self-check ok")
        return
    for k, v in (line.split("=", 1) for line in open(os.path.join(ROOT, ".env"), encoding="utf-8") if "=" in line and not line.startswith("#")) if os.path.exists(os.path.join(ROOT, ".env")) else []:
        os.environ.setdefault(k.strip(), v.strip().strip('"'))
    log(f"cycle start (offline={ARGS.offline}, dry_run={ARGS.dry_run})")
    if not rails.guard():
        log("kernel guard failed; aborting cycle")
        sys.exit(4)
    st = load_state()
    st["cycle"] = st.get("cycle", 0) + 1
    if git("remote", check=False) and not ARGS.dry_run:
        subprocess.run(["git", "pull", "-q", "--ff-only"], cwd=ROOT, capture_output=True, timeout=300)
    rollback_watch(st)
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
        summary, world = world_summary()
        for role in PROPOSERS:
            if ARGS.only and ARGS.only != role:
                continue
            run_proposer(role, st, summary, quarantine_before)
        if not ARGS.only or ARGS.only == "chronicler":
            full, world = world_summary(full=True)
            chronicle(st, full, world)
    update_readme()
    save_state(st)
    commit(f"overseers: cycle {st['cycle']} bookkeeping", "runner", "none",
           ["overseers/state.json", "config/models.json", "ledger", "checkpoints/daily", "docs/DECISIONS.md", "README.md", "journal"])
    push()
    if not ARGS.dry_run and any(h.get("result") == "merged" and time.time() - h["ts"] < 3 * 3600 for h in st.get("history", [])):
        restart_service()
    if ARGS.dry_run:
        git("checkout", "--", ".", check=False)
        for f in glob.glob(os.path.join(ROOT, "world/inbox/*.json")) + glob.glob(os.path.join(ROOT, "journal/*.md")) + [mast for mast in [os.path.join(ROOT, "journal/MASTHEAD.json")] if os.path.exists(mast)]:
            if git("ls-files", "--error-unmatch", os.path.relpath(f, ROOT), check=False) != os.path.relpath(f, ROOT):
                os.remove(f)
    log("cycle end")


if __name__ == "__main__":
    main()
