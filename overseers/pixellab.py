#!/usr/bin/env python3
"""PixelLab v2 client + the viewer's art cache. Standard library only, like the rest of the runner.

Every paid request goes `rails.check_spend("art", est)` -> request -> `rails.record(..., category="art")` with the
real `usage.usd`, so PixelLab spend sits in the same ledger as the models. Assets live in viewer/art/ and are listed
in viewer/art/manifest.json; an asset that is in the manifest is never regenerated. Image checks (palette, magenta,
coverage) run in Godot: viewer/art_check.gd.

  python3 overseers/pixellab.py --balance
  python3 overseers/pixellab.py --style                  # viewer/art/style_ref.png + palette.json from the VISION prompt
  python3 overseers/pixellab.py --citizen "Wren Halloway"   # one villager: 4 rotations + walk + idle (use default for the shared fallback)
  python3 overseers/pixellab.py --building house_3x2 --tileset ground --tileset streets
  python3 overseers/pixellab.py --batch [--max-citizens N]   # everything the world needs that the manifest lacks
  python3 overseers/pixellab.py --eval                   # make art-eval: coverage, palette, size limit, web export
"""
import argparse, base64, glob, json, os, re, shutil, subprocess, sys, time, urllib.error, urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "kernel"))
import rails  # noqa: E402

API = "https://api.pixellab.ai/v2"
ART = os.path.join(ROOT, "viewer", "art")
MANIFEST = os.path.join(ART, "manifest.json")
# docs/VISION.md — the only statement of taste
STYLE_PROMPT = ("cozy top-down farming RPG pixel art, 32x32 villager, south-facing, muted earthy palette with warm highlights, "
                "soft shading, Stardew Valley / Harvest Moon spirit, clean 1px outline, transparent background")
STYLE = {"outline": "single color black outline", "shading": "basic shading", "detail": "medium detail", "view": "low top-down"}
EST = {"character": 0.3, "animation": 0.5, "image": 0.08, "tileset": 0.6}   # pre-call estimates for check_spend; the ledger records the real usage.usd
ART_SIZE_LIMIT_MB = 12.0
TILE = 16
log = rails.log


# ---------------------------------------------------------------- http
def key():
    return os.environ.get("PIXELLAB_API_KEY", "")


def api(method, path, body=None, timeout=180):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={"Authorization": f"Bearer {key()}", "Content-Type": "application/json", "User-Agent": "vesper-artisan"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.load(r)
        if os.environ.get("PIXELLAB_DEBUG"):
            os.makedirs(os.path.join(ROOT, "state", "pixellab"), exist_ok=True)
            json.dump(data, open(os.path.join(ROOT, "state", "pixellab", f"{int(time.time() * 1000)}-{method}-{path.strip('/').replace('/', '_')}.json"), "w"), indent=1)
        return data
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"pixellab {method} {path}: HTTP {e.code} {e.read()[:400]!r}") from None


def bill(u, kind, path, label):
    """One ledger line per charge. Sync endpoints report usage on the response, async ones on the finished job.
    Subscription plans bill in "generations": amortised at pixellab_usd_per_generation (config/budget.json; 0 = covered by the plan)."""
    u = u or {}
    gens = float(u.get("generations") or 0.0)
    usd = float(u.get("usd") or 0.0) if u.get("type", "usd") == "usd" else gens * float(rails.budget_config().get("pixellab_usd_per_generation", 0.0))
    if usd or gens:
        rails.record("pixellab", f"art:{kind}", "pixellab" + path, int(gens), 0, usd, "art")
    log(f"pixellab {path} [{label}]: ${usd:.4f} ({u.get('type', '-')}: usd={u.get('usd')} generations={u.get('generations')})")


def paid(method, path, body, kind, label):
    """A paid request: budget check before (category art), ledger line after with the real cost."""
    if not key():
        raise rails.BudgetExhausted("no PIXELLAB_API_KEY")
    rails.check_spend("art", EST[kind])
    r = api(method, path, body)
    bill(r.get("usage"), kind, path, label)
    return r


def wait_job(job_id, kind="job", label="", timeout=900):
    t0 = time.time()
    while time.time() - t0 < timeout:
        j = api("GET", f"/background-jobs/{job_id}")
        if j.get("status") in ("completed", "failed"):
            if j.get("status") == "failed":
                raise RuntimeError(f"pixellab job {job_id} failed: {json.dumps(j.get('last_response'))[:300]}")
            bill(j.get("usage"), kind, f"/background-jobs", label)
            return j
        time.sleep(5)
    raise TimeoutError(f"pixellab job {job_id} still running after {timeout}s")


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "vesper-artisan"}), timeout=120) as r:
        return r.read()


def save(rel, data):
    full = os.path.join(ART, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, "wb").write(data)
    return rel


def b64img(rel):
    return {"type": "base64", "base64": base64.b64encode(open(os.path.join(ART, rel), "rb").read()).decode(), "format": "png"}


# ---------------------------------------------------------------- manifest
def manifest():
    try:
        return json.load(open(MANIFEST, encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"_comment": "viewer/art cache, written by overseers/pixellab.py. Never regenerate an asset listed here. Sprites generated with PixelLab.",
                "style_ref": "", "palette": [], "citizens": {}, "buildings": {}, "tilesets": {}}


def write_manifest(m):
    os.makedirs(ART, exist_ok=True)
    json.dump(m, open(MANIFEST, "w", encoding="utf-8"), indent=1, sort_keys=True)


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", str(name).lower()).strip("-") or "citizen"


# ---------------------------------------------------------------- godot-side checks
def godot():
    return shutil.which("godot") or ("/Applications/Godot.app/Contents/MacOS/Godot" if os.path.exists("/Applications/Godot.app/Contents/MacOS/Godot") else "/usr/local/bin/godot")


def art_check(*args):
    """Runs viewer/art_check.gd headless; returns its JSON report."""
    r = subprocess.run([godot(), "--headless", "--path", ROOT, "-s", "viewer/art_check.gd", "--", *args], capture_output=True, text=True, timeout=300)
    for line in reversed(r.stdout.splitlines()):
        if line.startswith("{"):
            return json.loads(line)
    raise RuntimeError(f"art_check produced no report: {(r.stdout + r.stderr)[-800:]}")


def style_ok(rels, m):
    """The style check: every opaque pixel near the shared palette, no magenta. Rejected files go to state/art_rejected/, never into the manifest."""
    rep = art_check("--check", *[os.path.join("viewer", "art", r) for r in rels])
    bad = [f for f, v in rep.get("files", {}).items() if not v.get("ok")]
    if bad:
        dest = os.path.join(ROOT, "state", "art_rejected")
        os.makedirs(dest, exist_ok=True)
        for f in bad:
            log(f"art: palette check failed for {f}: {json.dumps(rep['files'][f])[:200]}")
            shutil.move(os.path.join(ROOT, f), os.path.join(dest, os.path.basename(f)))
    return not bad


# ---------------------------------------------------------------- generation
def gen_style(m):
    if m.get("style_ref") and os.path.exists(os.path.join(ART, m["style_ref"])):
        return m
    r = paid("POST", "/create-image-pixflux", {"description": STYLE_PROMPT, "image_size": {"width": 64, "height": 64}, "no_background": True, **STYLE}, "image", "style_ref")
    m["style_ref"] = save("style_ref.png", base64.b64decode(r["image"]["base64"]))
    refresh_palette(m)
    log(f"art: style reference + palette of {len(m['palette'])} colours")
    return m


def refresh_palette(m):
    """The shared palette = the style reference's colours plus the tilesets' (same outline/shading/view settings, so they define the
    style as much as the reference does; the sea needs its blues). Citizens and buildings are checked against it."""
    # per source, so 4096 tile pixels cannot crowd out the reference's skin and cloth colours the villagers are forced to use
    groups = ([(["viewer/art/" + m["style_ref"]], 40)] if m.get("style_ref") else []) + \
             [(["viewer/art/" + r for r in ts.get("tiles", {}).values()], 20) for ts in m.get("tilesets", {}).values()]
    pal = []
    for files, n in groups:
        for c in art_check("--palette", *files)["palette"][:n]:
            if c not in pal:
                pal.append(c)
    m["palette"] = pal
    json.dump({"palette": m["palette"], "tolerance": 40, "min_share": 0.9, "_from": "style_ref.png + tilesets"}, open(os.path.join(ART, "palette.json"), "w"), indent=1)
    write_manifest(m)


def palette_args(m, force=True):
    """characters accept force_colors; pixflux (buildings) only color_image; tilesets get neither (the sea must stay blue)."""
    return ({"color_image": b64img(m["style_ref"]), **({"force_colors": True} if force else {})}) if m.get("style_ref") else {}


def gen_citizen(m, name, desc_hint=""):
    k = slug(name)
    if k in m["citizens"]:
        return m
    desc = (f"{STYLE_PROMPT}; {desc_hint}" if desc_hint else STYLE_PROMPT)[:1900]
    r = paid("POST", "/create-character-with-4-directions", {"description": desc, "image_size": {"width": 32, "height": 32}, **STYLE, **palette_args(m)}, "character", k)
    cid = r["character_id"]
    wait_job(r["background_job_id"], "character", k)
    for anim, template in (("walk", "walk"), ("idle", "breathing-idle")):
        ra = paid("POST", "/animate-character", {"character_id": cid, "template_animation_id": template, "animation_name": anim, "mode": "template", **palette_args(m)}, "animation", f"{k}/{anim}")
        for jid in ra.get("background_job_ids", []):
            wait_job(jid, "animation", f"{k}/{anim}")
    detail = api("GET", f"/characters/{cid}")
    entry = {"dir": f"citizens/{k}", "character_id": cid, "size": [int(detail["size"]["width"]), int(detail["size"]["height"])], "rotations": {}, "animations": {}}
    rels = []
    for d, url in (detail.get("rotation_urls") or {}).items():
        if url and d in ("south", "north", "east", "west"):
            entry["rotations"][d] = save(f"citizens/{k}/{d}.png", fetch(url))
            rels.append(entry["rotations"][d])
    for g in detail.get("animations") or []:
        anim = str(g.get("display_name") or g.get("animation_type"))
        anim = "walk" if "walk" in anim else "idle" if ("idle" in anim or "breath" in anim) else anim
        for dd in g.get("directions", []):
            frames = []
            for i, url in enumerate(dd.get("frames", [])):
                frames.append(save(f"citizens/{k}/{anim}_{dd['direction']}_{i}.png", fetch(url)))
            entry["animations"].setdefault(anim, {})[dd["direction"]] = frames
            rels += frames
    if not style_ok(rels, m):
        log(f"art: {k} rejected by the style check; not cached")
        shutil.rmtree(os.path.join(ART, "citizens", k), ignore_errors=True)
        return m
    m["citizens"][k] = entry
    write_manifest(m)
    log(f"art: citizen {k}: {len(entry['rotations'])} rotations, animations {[a + ':' + str(len(v)) for a, v in entry['animations'].items()]}")
    return m


def gen_building(m, kind, w, h):
    k = f"{kind}_{w}x{h}"
    if k in m["buildings"]:
        return m
    desc = (f"cozy top-down farming RPG pixel art {kind} building seen from above, roof that shows it is a {kind}, front door at the bottom edge, "
            f"warm window, Stardew Valley / Harvest Moon spirit, muted earthy palette with warm highlights, soft shading, clean 1px outline, transparent background")
    r = paid("POST", "/create-image-pixflux", {"description": desc, "image_size": {"width": max(w * TILE, 32), "height": max(h * TILE, 32)}, "no_background": True,   # pixflux canvas minimum is 32x32
                                              **{**STYLE, "view": "high top-down"}, **palette_args(m, False)}, "image", k)
    rel = save(f"buildings/{k}.png", base64.b64decode(r["image"]["base64"]))
    if not style_ok([rel], m):
        return m
    m["buildings"][k] = rel
    write_manifest(m)
    return m


TILESETS = {"ground": ("deep blue sea water with soft ripples", "soft green meadow grass"), "streets": ("soft green meadow grass", "grey cobblestone street")}


def gen_tileset(m, name):
    if name in m["tilesets"]:
        return m
    lower, upper = TILESETS[name]
    r = paid("POST", "/create-tileset", {"lower_description": lower, "upper_description": upper, "tile_size": {"width": TILE, "height": TILE}, "view": "high top-down",
                                        "outline": STYLE["outline"], "shading": STYLE["shading"], "detail": STYLE["detail"]}, "tileset", name)
    tid = r.get("tileset_id") or (r.get("tileset") or {}).get("id")
    if r.get("background_job_id"):
        wait_job(r["background_job_id"], "tileset", name)
    data = r if r.get("tileset") and (r["tileset"].get("tiles")) else api("GET", f"/tilesets/{tid}")
    ts = data["tileset"]
    terrains = ts.get("terrain_types") or []
    entry = {"dir": f"tiles/{name}", "lower": lower, "upper": upper, "terrain_types": terrains, "tiles": {}}
    rels = []
    for t in ts["tiles"]:
        corners = t.get("corners") or {}
        # normalise the four corners to "upper"/"lower" so the renderer never needs the terrain names
        up = [c for c in ("NW", "NE", "SW", "SE") if str(corners.get(c, "")).lower() not in ("", "lower", terrains[0].lower() if terrains else "lower")]
        kname = "+".join(up) if up else "none"
        rel = save(f"tiles/{name}/{kname}.png", base64.b64decode(t["image"]["base64"]))
        entry["tiles"][kname] = rel
        rels.append(rel)
    entry["raw_corners"] = {t.get("name"): t.get("corners") for t in ts["tiles"]}
    m["tilesets"][name] = entry
    refresh_palette(m)
    log(f"art: tileset {name}: {len(entry['tiles'])} tiles; palette now {len(m['palette'])} colours")
    return m


# ---------------------------------------------------------------- what the world needs
def world():
    for p in (os.path.join(ROOT, "checkpoints", "latest.json"), *sorted(glob.glob(os.path.join(ROOT, "checkpoints", "daily", "*.json")), reverse=True), os.path.join(ROOT, "world", "seed.json")):
        try:
            return json.load(open(p, encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
    return {}


def needs(m):
    """(citizens, buildings, tilesets) the current world has and the manifest lacks."""
    s = world()
    cits = [(c["name"], f"{int(c.get('age', 30))} year old {c.get('occupation', 'villager')}, {c.get('innate', '')}; {c.get('lifestyle', '')}".strip())
            for c in s.get("citizens", []) if c.get("alive", True) and slug(c["name"]) not in m["citizens"]]
    blds = sorted({(b["kind"], int(b["w"]), int(b["h"])) for b in s.get("map", {}).get("buildings", []) if f"{b['kind']}_{int(b['w'])}x{int(b['h'])}" not in m["buildings"]})
    sets = [n for n in TILESETS if n not in m["tilesets"]]
    return cits, blds, sets


def attempt(label, fn, *args):
    """One asset at a time; a dropped job or a network error costs that asset this run, not the batch (the next `make art` retries it)."""
    try:
        return fn(*args)
    except rails.BudgetExhausted as e:
        log(f"art: {label}: {e}; stopping the batch")
        raise
    except Exception as e:  # noqa: BLE001
        log(f"art: {label} failed ({str(e)[:200]}); continuing")
        return manifest()


def batch(max_citizens):
    m = gen_style(manifest())
    if "default" not in m["citizens"]:
        m = attempt("default citizen", gen_citizen, m, "default", "an ordinary villager, plain clothes")
    cits, blds, sets = needs(m)
    for name in sets:
        m = attempt(f"tileset {name}", gen_tileset, m, name)
    for kind, w, h in blds:
        m = attempt(f"building {kind} {w}x{h}", gen_building, m, kind, w, h)
    for name, hint in cits[:max_citizens]:
        m = attempt(f"citizen {name}", gen_citizen, m, name, hint)
    cits, blds, sets = needs(m)
    log(f"art: batch done; still missing: {len(cits)} citizens, {len(blds)} buildings, {len(sets)} tilesets")


# ---------------------------------------------------------------- make art-eval
def evaluate():
    """Mechanical checks before the pairwise Judge: coverage (no magenta), palette, size limit, web export boots."""
    m = manifest()
    s = world()
    problems = []
    kinds = sorted({b["kind"] for b in s.get("map", {}).get("buildings", [])})
    for b in s.get("map", {}).get("buildings", []):
        if f"{b['kind']}_{int(b['w'])}x{int(b['h'])}" not in m["buildings"]:
            problems.append(f"no art for building {b['kind']} {b['w']}x{b['h']}")
    for name in TILESETS:
        if name not in m["tilesets"]:
            problems.append(f"no tileset {name}")
    if "default" not in m["citizens"]:
        problems.append("no _default citizen sprite")
    size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(ART) for f in fs) / 1e6
    if size > ART_SIZE_LIMIT_MB:
        problems.append(f"viewer/art is {size:.1f} MB > {ART_SIZE_LIMIT_MB} MB")
    pngs = [os.path.relpath(os.path.join(dp, f), ROOT) for dp, _, fs in os.walk(ART) for f in fs if f.endswith(".png")]
    if pngs and m.get("palette"):
        rep = art_check("--check", *pngs)
        problems += [f"style check: {f}" for f, v in rep.get("files", {}).items() if not v.get("ok")]
    r = subprocess.run(["make", "-s", "export-web"], cwd=ROOT, capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        problems.append(f"web export failed: {(r.stderr or r.stdout)[-300:]}")
    fps = fps_probe()
    if fps is not None and fps < 30:
        problems.append(f"viewer at {fps:.0f} fps < 30 with the current population")
    missing_cits = len([c for c in s.get("citizens", []) if c.get("alive", True) and slug(c["name"]) not in m["citizens"]])
    print(json.dumps({"ok": not problems, "problems": problems, "art_mb": round(size, 2), "fps": fps, "kinds": kinds, "citizens_with_art": len(m["citizens"]), "citizens_without_art": missing_cits}, indent=1))
    return not problems


def fps_probe():
    """Boots the throwaway world, shoots the viewer once (`make screenshot` prints `viewer: fps N`), kills the world. None without a display."""
    import signal
    if sys.platform != "darwin" and not os.environ.get("DISPLAY") and not shutil.which("xvfb-run"):
        return None
    srv = subprocess.Popen(["make", "-s", "dev"], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        time.sleep(5)
        r = subprocess.run(["make", "-s", "screenshot", "OUT=state/art-eval.png"], cwd=ROOT, capture_output=True, text=True, timeout=90)
        m = re.search(r"viewer: fps (\d+)", r.stdout + r.stderr)
        return float(m.group(1)) if m else None
    except subprocess.TimeoutExpired:
        return None
    finally:
        os.killpg(srv.pid, signal.SIGTERM)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--balance", action="store_true")
    ap.add_argument("--style", action="store_true")
    ap.add_argument("--palette", action="store_true", help="rebuild palette.json from the style reference and the tilesets")
    ap.add_argument("--citizen", action="append", default=[])
    ap.add_argument("--building", action="append", default=[], help="kind_WxH, e.g. house_3x2")
    ap.add_argument("--tileset", action="append", default=[], choices=list(TILESETS))
    ap.add_argument("--batch", action="store_true")
    ap.add_argument("--max-citizens", type=int, default=4)
    ap.add_argument("--eval", action="store_true")
    a = ap.parse_args()
    for k, v in (line.split("=", 1) for line in open(os.path.join(ROOT, ".env"), encoding="utf-8") if "=" in line and not line.startswith("#")) if os.path.exists(os.path.join(ROOT, ".env")) else []:
        os.environ.setdefault(k.strip(), v.strip().strip('"'))
    rails.begin_session()
    if a.eval:
        sys.exit(0 if evaluate() else 1)
    if a.balance:
        print(json.dumps(api("GET", "/balance")))
    m = manifest()
    if a.style or a.citizen or a.building or a.tileset:
        m = gen_style(m)
    if a.palette:
        refresh_palette(m)
        log(f"art: palette rebuilt: {len(m['palette'])} colours")
    for name in a.tileset:
        m = gen_tileset(m, name)
    for spec in a.building:
        kind, wh = spec.rsplit("_", 1)
        w, h = wh.split("x")
        m = gen_building(m, kind, int(w), int(h))
    for name in a.citizen:
        hint = next((f"{int(c.get('age', 30))} year old {c.get('occupation', 'villager')}, {c.get('innate', '')}; {c.get('lifestyle', '')}" for c in world().get("citizens", []) if c.get("name") == name), "an ordinary villager, plain clothes" if name == "default" else "")
        m = gen_citizen(m, name, hint)
    if a.batch:
        batch(a.max_citizens)


if __name__ == "__main__":
    main()
