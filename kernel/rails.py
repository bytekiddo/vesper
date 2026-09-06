"""KERNEL — frozen. Safety rails for the overseer runner.

Every model call the runner makes goes through `chat()` here: the budget is checked before,
the spend is appended to the shared ledger after, and the output passes the content filter
before the caller ever sees it. Proposals may not touch PROTECTED paths.
Only the standard library is used, on purpose.
"""
import hashlib, json, os, re, subprocess, sys, time, urllib.request, urllib.error
from datetime import datetime, timezone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROTECTED = ("kernel/", ".env", "ledger/", "checkpoints/", "quarantine/", "state/", ".git/", "KERNEL.sha256")
OVERSEER_SHARE = 0.3          # of BUDGET_USD_PER_MONTH; citizens get the rest (kernel/ledger.gd CITIZEN_SHARE)
OPENROUTER = "https://openrouter.ai/api/v1"
MAX_DRIFT_MS = 1000.0
MEMORY_CEILING_MB = 768.0


def p(*parts):
    return os.path.join(ROOT, *parts)


def log(msg):
    print(f"[{datetime.now(timezone.utc).strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------- kernel integrity ----------
def verify_kernel():
    manifest = p("kernel", "KERNEL.sha256")
    if not os.path.exists(manifest):
        return False, "kernel/KERNEL.sha256 missing"
    for line in open(manifest, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        want, rel = line.split()[0], line.split()[-1].lstrip("*")
        try:
            got = hashlib.sha256(open(p(rel), "rb").read()).hexdigest()
        except FileNotFoundError:
            return False, f"{rel} missing"
        if got != want:
            return False, f"{rel} modified"
    return True, "ok"


def guard():
    """Same as systemd's ExecStartPre; restores kernel/ from last-known-good when touched."""
    r = subprocess.run(["bash", p("kernel", "guard.sh")], cwd=ROOT)
    return r.returncode == 0


def path_allowed(rel):
    rel = rel.replace("\\", "/")
    if rel.startswith("/") or ".." in rel.split("/"):
        return False
    while rel.startswith("./"):
        rel = rel[2:]
    return not any(rel.startswith(x) or x in rel for x in PROTECTED)


# ---------- content limits (same rules file as content_filter.gd) ----------
_rules = None
_compiled = {}


def rules():
    global _rules
    if _rules is None:
        _rules = json.load(open(p("kernel", "content_rules.json"), encoding="utf-8"))
        for key in ("sexual", "minor_terms", "romance_terms", "harm", "slurs"):
            _compiled[key] = [re.compile(pat, re.I) for pat in _rules.get(key, [])]
    return _rules


def _any(key, text):
    rules()
    return any(r.search(text) for r in _compiled[key])


def content_check(text):
    """Returns (ok, reason). Mirrors kernel/content_filter.gd exactly."""
    if len(text) > 200000:
        return False, "length"
    if _any("slurs", text):
        return False, "slur"
    if _any("sexual", text):
        return False, "sexual"
    if _any("harm", text):
        return False, "harm"
    if _any("minor_terms", text) and _any("romance_terms", text):
        return False, "minor_romance"
    low = text.lower()
    for key in ("real_people", "brands"):
        for name in rules().get(key, []):
            n = name.lower()
            if len(n) < 4:
                if re.search(r"\b" + re.escape(n) + r"\b", text, re.I):
                    return False, f"{key}:{name}"
            elif n in low:
                return False, f"{key}:{name}"
    return True, ""


def check_relationship(kind, age_a, age_b):
    adult = rules().get("adult_age", 18)
    if kind in ("partner", "romantic", "lover", "spouse", "crush", "flirt") and (age_a < adult or age_b < adult):
        return False, "minor_romance_edge"
    return True, ""


def quarantine(text, reason, source):
    os.makedirs(p("quarantine"), exist_ok=True)
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    with open(p("quarantine", f"{day}.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": int(time.time()), "source": source, "reason": reason, "text": text[:4000]}) + "\n")


def quarantine_count_today():
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    f = p("quarantine", f"{day}.jsonl")
    return sum(1 for l in open(f, encoding="utf-8") if l.strip()) if os.path.exists(f) else 0


# ---------- ledger ----------
def budget():
    try:
        b = float(os.environ.get("BUDGET_USD_PER_MONTH", "75"))
    except ValueError:
        b = 75.0
    return max(50.0, min(100.0, b))


def month_key(ts=None):
    return datetime.fromtimestamp(ts or time.time(), timezone.utc).strftime("%Y-%m")


def month_total(month=None):
    month = month or month_key()
    out = {"month": month, "cost": 0.0, "calls": 0, "prompt_tokens": 0, "completion_tokens": 0, "by_role": {}, "by_model": {}, "by_source": {}}
    f = p("ledger", "spend.jsonl")
    if not os.path.exists(f):
        return out
    for line in open(f, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("month") != month:
            continue
        c = float(e.get("cost", 0) or 0)
        out["cost"] += c
        out["calls"] += 1
        out["prompt_tokens"] += int(e.get("prompt_tokens", 0) or 0)
        out["completion_tokens"] += int(e.get("completion_tokens", 0) or 0)
        for k, field in (("by_role", "role"), ("by_model", "model"), ("by_source", "source")):
            out[k][str(e.get(field, "?"))] = out[k].get(str(e.get(field, "?")), 0.0) + c
    return out


def record(source, role, model, prompt_tokens, completion_tokens, cost):
    os.makedirs(p("ledger"), exist_ok=True)
    with open(p("ledger", "spend.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": int(time.time()), "month": month_key(), "source": source, "role": role, "model": model,
                            "prompt_tokens": int(prompt_tokens), "completion_tokens": int(completion_tokens), "cost": float(cost)}) + "\n")


def overseer_remaining():
    """USD the overseers may still spend this month (their share minus what overseers spent)."""
    t = month_total()
    spent = t["by_source"].get("overseer", 0.0)
    remaining_total = budget() - t["cost"]
    return max(0.0, min(budget() * OVERSEER_SHARE - spent, remaining_total))


# ---------- model calls ----------
class BudgetExhausted(Exception):
    pass


def models():
    """Live marketplace: id -> {prompt, completion (USD per token), context}."""
    req = urllib.request.Request(OPENROUTER + "/models", headers={"User-Agent": "vesper-overseer"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)["data"]
    out = {}
    for m in data:
        pr = m.get("pricing") or {}
        try:
            out[m["id"]] = {"prompt": float(pr.get("prompt", 0)), "completion": float(pr.get("completion", 0)),
                            "context": int(m.get("context_length") or 0), "name": m.get("name", m["id"]),
                            "json": "response_format" in (m.get("supported_parameters") or [])}
        except (TypeError, ValueError):
            continue
    return out


def chat(model, messages, role, max_tokens=2000, temperature=0.7, json_mode=False, est_cost=0.05, retries=2):
    """The only sanctioned way to call a model. Returns (text, usage). Raises BudgetExhausted."""
    key = os.environ.get("OPENROUTER_API_KEY", "")
    if not key:
        raise BudgetExhausted("no OPENROUTER_API_KEY")
    if overseer_remaining() < est_cost:
        raise BudgetExhausted(f"overseer share exhausted ({overseer_remaining():.4f} USD left)")
    body = {"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature}
    if json_mode:
        body["response_format"] = {"type": "json_object"}
    req = urllib.request.Request(OPENROUTER + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                                          "HTTP-Referer": "https://github.com/bytekiddo/vesper", "X-Title": "Vesper overseers"})
    last = None
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                data = json.load(r)
            break
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as e:
            last = e
            time.sleep(3 * (attempt + 1))
    else:
        raise RuntimeError(f"openrouter failed: {last}")
    usage = data.get("usage") or {}
    pt, ct = int(usage.get("prompt_tokens", 0) or 0), int(usage.get("completion_tokens", 0) or 0)
    cost = usage.get("cost")
    if cost is None:
        cost = est_cost
    record("overseer", role, model, pt, ct, float(cost))
    text = ((data.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
    ok, reason = content_check(text)
    if not ok:
        quarantine(text, reason, f"overseer:{role}")
        raise ContentBreach(reason)
    return text, {"prompt_tokens": pt, "completion_tokens": ct, "cost": float(cost), "model": model}


class ContentBreach(Exception):
    pass


def parse_json(text):
    """LLMs wrap JSON in fences or prose; find the outermost object."""
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    a, b = text.find("{"), text.rfind("}")
    if a >= 0 and b > a:
        return json.loads(text[a:b + 1])
    raise ValueError("no JSON object in model output")


# ---------- hard limits ----------
def run_smoke(seconds=None):
    env = dict(os.environ)
    if seconds:
        env["SMOKE_SECONDS"] = str(seconds)
    r = subprocess.run(["make", "-s", "smoke"], cwd=ROOT, env=env, capture_output=True, text=True, timeout=3600)
    report = (r.stdout + "\n" + r.stderr)[-6000:]
    return r.returncode == 0, report


def metrics():
    f = p("state", "metrics.json")
    try:
        return json.load(open(f, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def hard_limit_breaches(smoke_ok, quarantine_before):
    """List of hard-limit breaches for this cycle. Empty list == the Judge has nothing to veto on."""
    b = []
    if not smoke_ok:
        b.append("smoke test failed")
    if quarantine_count_today() > quarantine_before:
        b.append("content limit breached by an overseer output")
    if month_total()["cost"] > budget():
        b.append("budget overrun")
    m = metrics()
    if m and float(m.get("drift_ms_max", 0)) > MAX_DRIFT_MS:
        b.append(f"tick drift {m.get('drift_ms_max')} ms")
    if m and float(m.get("memory_mb", 0)) > MEMORY_CEILING_MB:
        b.append(f"memory {m.get('memory_mb')} MB over ceiling")
    return b


def stability_degraded(baseline, now):
    """Compares live metrics against a merge-time baseline (both dicts from metrics())."""
    if not baseline or not now:
        return None
    reasons = []
    if int(now.get("boot_count", 0)) - int(baseline.get("boot_count", 0)) >= 3:
        reasons.append("restarted 3+ times")
    if float(now.get("drift_ms_max", 0)) > MAX_DRIFT_MS:
        reasons.append("tick drift over 1 s")
    if float(now.get("memory_mb", 0)) > MEMORY_CEILING_MB:
        reasons.append("memory over ceiling")
    if int(now.get("quarantine_today", 0)) > int(baseline.get("quarantine_today", 0)) + 5:
        reasons.append("content quarantines rising")
    return reasons or None


if __name__ == "__main__":
    # self-check: content rules and ledger arithmetic
    assert content_check("Wren sold bread to Tobiah at the Salt Kettle.")[0]
    assert not content_check("A citizen named Elon Musk moved in.")[0]
    assert not content_check("They drank Coke on the pier.")[0]
    assert content_check("The lighthouse lamp came on at noon.")[0]
    assert not content_check("the child had a crush on him")[0]
    assert check_relationship("partner", 17, 30)[0] is False
    assert check_relationship("friend", 12, 30)[0] is True
    assert path_allowed("world/rules.json") and not path_allowed("kernel/clock.gd") and not path_allowed("../x")
    assert 50.0 <= budget() <= 100.0
    print("rails self-check ok; kernel:", verify_kernel())
