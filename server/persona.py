"""Persona server: Muse Glimmer 30B on MLX with persona-vector steering.

A persona is one self-contained .persona file: a name, a portrait from Muse Image, and a few
traits, each a persona vector at one layer plus its slider value. Muse Wonder (OpenRouter)
designs personas from an interview, writes contrast data for each trait, and judges replies.
Glimmer reads that data; the mean activation difference at one layer is the vector. Chat adds
sum(value * vector) to that layer's output. Sharing a persona is sending its file.
"""
import base64, json, os, queue, re, subprocess, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx
import mlx.core as mx
import mlx.nn as nn
import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response, StreamingResponse
from mlx_vlm import load, stream_generate
from mlx_vlm.utils import load_config

ROOT = Path(__file__).resolve().parent.parent
PERSONAS = ROOT / "personas"
PERSONAS.mkdir(exist_ok=True)
FORMAT = "persona/1"
MODEL = os.environ.get("PERSONA_MODEL", "mlx-community/Muse-Glimmer-30B-4bit")
WONDER = os.environ.get("PERSONA_WONDER", "meta/muse-wonder")
IMAGE = os.environ.get("PERSONA_IMAGE", "meta/muse-image")
ENV = ROOT / ".env"
# Muse Wonder and Muse Image run through OpenRouter or Meta Model API, whichever has a key. Meta wins if both do.
PROVIDERS = {
    "openrouter": {"var": "OPENROUTER_API_KEY", "check": "https://openrouter.ai/api/v1/key"},
    "meta": {"var": "MODEL_API_KEY", "check": "https://api.meta.ai/v1/models"},
}
META = "https://api.meta.ai/v1"


def env_key(var):
    lines = ENV.read_text().splitlines() if ENV.exists() else []
    return os.environ.get(var) or next((l.split("=", 1)[1].strip() for l in lines if l.startswith(var + "=")), "")


KEYS = {name: env_key(p["var"]) for name, p in PROVIDERS.items()}


def provider():
    return "meta" if KEYS["meta"] else "openrouter"


class Steer(nn.Module):
    """Wraps one decoder layer: records its output, or adds the steering vector."""
    def __init__(self, layer):
        super().__init__()
        self.layer = layer
        self.is_sliding = layer.is_sliding
        self.add = None      # (hidden,) array or None
        self.record = None   # list to append outputs to, or None

    def __call__(self, x, mask=None, cache=None):
        h = self.layer(x, mask=mask, cache=cache)
        if self.record is not None:
            self.record.append(h)
        if self.add is not None:
            h = h + self.add.astype(h.dtype)
        return h


# MLX keeps freed GPU buffers for reuse, which grew past 25 GB wired on a 64 GB Mac. Cap that cache.
mx.set_cache_limit(int(float(os.environ.get("PERSONA_CACHE_GB", 2)) * 2**30))
model, processor = load(MODEL)
tok = processor.tokenizer if hasattr(processor, "tokenizer") else processor
layers = model.language_model.model.layers
N = len(layers)
LAYER = int(os.environ.get("PERSONA_LAYER", round(N * 0.6)))
steer = Steer(layers[LAYER])
layers[LAYER] = steer
# MLX streams belong to the thread that made them, so all model work runs on the main thread,
# one job at a time, and uvicorn serves from a side thread.
jobs = queue.Queue()
HIDDEN = load_config(MODEL)["text_config"]["hidden_size"]


def on_gpu(gen):
    """Runs a generator on the main thread and yields its items here. Stops it if the client leaves."""
    out, stop = queue.Queue(), threading.Event()
    jobs.put((gen, out, stop))
    try:
        while (item := out.get()) is not None:
            if isinstance(item, Exception):
                raise item
            yield item
    finally:
        stop.set()

personas = {}  # slug -> the stored persona, plus "_vecs": {trait name: mx.array}


def encode(vec):
    return base64.b64encode(np.asarray(vec, dtype=np.float32).tobytes()).decode()


def decode(text):
    return mx.array(np.frombuffer(base64.b64decode(text), dtype=np.float32))


def save(p):
    """Writes the shareable file: everything but the loaded vectors."""
    p["updated"] = time.time()
    (PERSONAS / f"{p['slug']}.persona").write_text(json.dumps({k: v for k, v in p.items() if k != "_vecs"}))


def load_persona(text):
    p = json.loads(text)
    if p.get("format") != FORMAT:
        raise ValueError("This isn't a Persona file.")
    # A vector only means something in the model and layer it was read from.
    if p.get("layer") != LAYER or p.get("hidden") != HIDDEN:
        raise ValueError(f"This persona was made for another model ({p.get('model')}, layer {p.get('layer')}).")
    p["_vecs"] = {t["name"]: decode(t["vector"]) for t in p["traits"]}
    return p


def summary(p):
    """What the app lists: no vectors, no portrait bytes."""
    return {"slug": p["slug"], "name": p["name"], "tagline": p["tagline"], "intro": p.get("intro", ""),
            "version": p["version"], "bytes": (PERSONAS / f"{p['slug']}.persona").stat().st_size,
            "portrait": bool(p.get("portrait")),
            "traits": [{k: t[k] for k in ("name", "description", "value")} for t in p["traits"]]}


def free_slug(name):
    base = re.sub(r"\W+", "-", name.lower()).strip("-") or "persona"
    slug, n = base, 2
    while slug in personas:
        slug, n = f"{base}-{n}", n + 1
    return slug


for f in sorted(PERSONAS.glob("*.persona")):
    try:
        p = load_persona(f.read_text())
        personas[p["slug"]] = p
    except ValueError as e:
        print(f"skipping {f.name}: {e}", flush=True)


def template(messages, gen=True):
    text = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=gen)
    # Glimmer opens with a hidden "to=self" reasoning turn. Prefill the answer turn to skip it,
    # which also matches the format the trait vectors were read in.
    return text + " to=user<|message|>" if gen else text


def auth():
    if not KEYS[provider()]:
        raise RuntimeError("Add your OpenRouter or Meta API key first.")
    return {"Authorization": f"Bearer {KEYS[provider()]}"}


def wonder(system, user, max_tokens=12000):
    messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
    if provider() == "meta":
        r = httpx.post(f"{META}/chat/completions", timeout=180, headers=auth(),
                       json={"model": "muse-wonder-1.0", "max_completion_tokens": max_tokens,
                             "reasoning_effort": "low", "messages": messages})
    else:
        r = httpx.post("https://openrouter.ai/api/v1/chat/completions", timeout=180, headers=auth(),
                       json={"model": WONDER, "max_tokens": max_tokens, "reasoning": {"effort": "low"},
                             "response_format": {"type": "json_object"}, "messages": messages})
    r.raise_for_status()
    text = r.json()["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", text, re.S)
    return json.loads(m.group(0))


JOLLY = "data:image/jpeg;base64," + base64.b64encode((ROOT / "server/assets/jolly.jpg").read_bytes()).decode()
PORTRAIT_STYLE = (" Keep this exact plush character, Jolly: fluffy cream fur hood, rosy cheeks, dot eyes, small smile. "
                  "Square portrait, centered, looking at the viewer, soft plain pastel background, no text.")


def paint(prompt):
    """Muse Image edits the Jolly reference into this persona -> a 512 px JPEG portrait, base64."""
    if provider() == "meta":
        r = httpx.post(f"{META}/images/edits", timeout=240, headers=auth(),
                       json={"model": "muse-image-1.0", "prompt": prompt + PORTRAIT_STYLE, "n": 1,
                             "images": [{"image_url": JOLLY}]})
    else:
        r = httpx.post("https://openrouter.ai/api/v1/images", timeout=240, headers=auth(),
                       json={"model": IMAGE, "prompt": prompt + PORTRAIT_STYLE, "n": 1,
                             "input_references": [{"type": "image_url", "image_url": {"url": JOLLY}}]})
    r.raise_for_status()
    with tempfile.TemporaryDirectory() as d:
        src, out = Path(d, "in.webp"), Path(d, "out.jpg")
        src.write_bytes(base64.b64decode(r.json()["data"][0]["b64_json"]))
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82", "-Z", "512", str(src), "--out", str(out)],
                       check=True, capture_output=True)
        return base64.b64encode(out.read_bytes()).decode()


def mix(p, values):
    """Slider values in [-1, 1] -> one vector. Each trait is scaled to the same length, so a full
    slider pushes every trait equally hard. Raw lengths vary (Pirate 56, Anxious 36)."""
    total = None
    for t in p["traits"] if p else []:
        if c := values.get(t["name"], 0):
            v = p["_vecs"][t["name"]] * (c * STRENGTH / t["norm"])
            total = v if total is None else total + v
    if total is not None and (n := float(mx.linalg.norm(total))) > CAP:
        total = total * (CAP / n)
    return total


STRENGTH = float(os.environ.get("PERSONA_STRENGTH", 140))
# Traits in one persona often overlap (Pirate Lingo and Treasure Questing), so their vectors add up.
# Past about one full slider of total push, Glimmer stops making sense, so the mix is capped there.
CAP = float(os.environ.get("PERSONA_CAP", 1.0)) * STRENGTH
STOPS = ("<|eom|>", "<|eot|>", "<|start|>", "<|end_of_text|>")


def say(messages, p, values, max_tokens=400, temperature=0.7):
    """Steered generation. Runs on the GPU thread through on_gpu, which is also where the mix happens:
    MLX math needs the thread's own stream."""
    steer.add = mix(p, values)
    try:
        for r in stream_generate(model, processor, template(messages), max_tokens=max_tokens,
                                 temperature=temperature, top_p=0.95):
            # Glimmer can end a message with <|eom|> and open a hidden "to=self" turn; stop there.
            if any(m in r.text for m in STOPS):
                r.text = r.text.split("<|")[0]
                yield r
                return
            yield r
    finally:
        steer.add = None


def event(**fields):
    return f"data: {json.dumps(fields)}\n\n"


def streamed(steps):
    """SSE response that turns a failure into an error event the app can show."""
    def run():
        try:
            yield from steps
        except httpx.HTTPStatusError as e:
            where = "Meta" if provider() == "meta" else "OpenRouter"
            if e.response.status_code in (401, 403):
                KEYS[provider()] = ""  # /health now reports no key, so the app asks for one
                yield event(error=f"{where} didn't accept your key. Enter a new one.")
            elif e.response.status_code == 402:
                yield event(error=f"Your {where} account is out of credits.")
            else:
                yield event(error=f"{where} error {e.response.status_code}: {e.response.text[:200]}")
        except Exception as e:
            yield event(error=str(e))
    return StreamingResponse(run(), media_type="text/event-stream")


app = FastAPI()


@app.get("/health")
def health():
    return {"model": MODEL, "layer": LAYER, "layers": N, "personas": len(personas),
            "key": bool(KEYS[provider()]), "provider": provider()}


@app.post("/key")
def set_key(body: dict):
    """{key} -> finds which provider accepts it, then saves it to .env in place of any older key."""
    key = body.get("key", "").strip()
    if not key:
        raise HTTPException(400, "Paste an OpenRouter or Meta API key.")
    order = ["openrouter", "meta"] if key.startswith("sk-or-") else ["meta", "openrouter"]
    try:
        name = next((n for n in order if httpx.get(PROVIDERS[n]["check"], timeout=20,
                                                    headers={"Authorization": f"Bearer {key}"}).status_code == 200), None)
    except httpx.HTTPError:
        raise HTTPException(400, "Couldn't reach OpenRouter or Meta. Check your connection.")
    if not name:
        raise HTTPException(400, "Neither OpenRouter nor Meta accepted that key.")
    var = PROVIDERS[name]["var"]
    lines = [l for l in (ENV.read_text().splitlines() if ENV.exists() else [])
             if not any(l.startswith(p["var"] + "=") for p in PROVIDERS.values())]
    ENV.write_text("\n".join(lines + [f"{var}={key}"]) + "\n")
    KEYS.update({n: key if n == name else "" for n in PROVIDERS})
    return {"key": True}


@app.get("/personas")
def list_personas():
    return [summary(p) for p in sorted(personas.values(), key=lambda p: p["created"])]


@app.get("/personas/{slug}/portrait")
def portrait(slug: str):
    if slug not in personas or not personas[slug].get("portrait"):
        raise HTTPException(404)
    return Response(base64.b64decode(personas[slug]["portrait"]), media_type="image/jpeg",
                    headers={"Cache-Control": "no-cache"})


@app.post("/chat")
def chat(body: dict):
    """{messages, persona: slug or null, coefs: {trait: -1..1}, max_tokens} -> SSE of {"t"} then {"done"}."""
    p = personas.get(body.get("persona"))

    def run():
        last = None
        for r in say(body["messages"], p, body.get("coefs", {}), body.get("max_tokens", 400), body.get("temperature", 0.7)):
            last = r
            if r.text:
                yield event(t=r.text)
        yield event(done={"tps": round(last.generation_tps, 1), "tokens": last.generation_tokens})
    return StreamingResponse(on_gpu(run()), media_type="text/event-stream")


DESIGN_SYSTEM = """You design a chat persona from someone's answers about how they like to be talked to.
The persona is made by adding 2 or 3 trait vectors to a language model's hidden state, never by a prompt.
So each trait must be one stylistic or emotional dimension that shows in any reply (tone, attitude, voice,
energy, how it treats the user), not knowledge, facts, or rules. The persona is a genuinely useful assistant
for one job (a coach, an editor, a tutor), and its traits make it better at that job. Fun, but useful.
Return JSON only:
{"name": a fun character name, 1-3 words,
 "tagline": one short line saying what talking to them is like,
 "portrait": how to dress the plush mascot Jolly for this role: outfit, one telling prop, expression,
             background colour. One or two sentences, starting "Jolly as",
 "traits": [{"name": 1-2 word Title Case label,
             "description": one sentence describing the trait as it shows in an assistant's replies,
             "value": strength 0.4 to 0.9}]}
Keep the sum of values at or below 1.6; stacking traits too hard makes the model incoherent.
Write plain text with no em dashes."""


BUILD_SYSTEM = """You design contrast data for extracting a persona vector from a language model's activations.
Given a trait, return JSON only:
{"name": short Title Case label (1-2 words),
 "description": one sentence,
 "questions": [12 varied everyday user questions where the trait could show],
 "positive": [12 assistant answers, one per question, strongly expressing the trait, 60-90 words each],
 "negative": [12 assistant answers, same questions, same length and helpfulness, fully neutral with no trace of the trait]}
Keep content and facts the same between positive and negative; only the trait should differ."""


def direction(data):
    """Mean layer output over response tokens, positive answers minus negative. Runs on the GPU thread."""
    means = {}
    for side in ("positive", "negative"):
        acts = []
        for q, a in zip(data["questions"], data[side]):
            head = template([{"role": "user", "content": q}])
            n_head = len(tok.encode(head))
            ids = mx.array([tok.encode(head + a)])
            steer.record = rec = []
            model.language_model(ids)
            steer.record = None
            acts.append(rec[0][0, n_head:].astype(mx.float32).mean(axis=0))  # response tokens only
        means[side] = mx.stack(acts).mean(axis=0)
    vec = means["positive"] - means["negative"]
    mx.eval(vec)
    yield vec, float(mx.linalg.norm(vec))


def trait(description, value, data):
    """Contrast data from Muse Wonder -> a stored trait with its persona vector."""
    vec, norm = next(on_gpu(direction(data)))
    return {"name": description["name"], "description": description["description"],
            "value": max(-1.0, min(1.0, float(value))), "norm": norm, "vector": encode(vec),
            "pairs": len(data["questions"]),
            "example": {"q": data["questions"][0], "pos": data["positive"][0], "neg": data["negative"][0]}}, vec


HELLO = [{"role": "user", "content": "Hi! We just met. Say hello and tell me how you like to help, in two or three sentences."}]
HELLO_CHECK = """You check a chat persona's first hello before it goes in a public gallery. Reply JSON only:
{"ok": true or false}. ok is true only if the hello is coherent, friendly, safe, makes no claims about who
built it, and offers no harmful help. Strong style and humor are fine."""


@app.post("/personas")
def create(body: dict):
    """{answers: [[question, answer], ...]} or {description} -> SSE steps, then the saved persona.
    Wonder designs it; pair writing and the portrait run in parallel while Glimmer reads each trait."""
    def steps():
        yield event(step="design", label="Muse Wonder is designing your persona")
        brief = body.get("description") or "\n".join(f"{q}\n{a}" for q, a in body["answers"] if a)
        d = wonder(DESIGN_SYSTEM, brief, 4000)
        d["traits"] = d["traits"][:3]
        yield event(step="designed", label=f"Meet {d['name']}", name=d["name"], tagline=d["tagline"],
                    traits=[t["name"] for t in d["traits"]])
        pool = ThreadPoolExecutor(4)
        painting = pool.submit(paint, d["portrait"])
        writing = [pool.submit(wonder, BUILD_SYSTEM, f"{t['name']}: {t['description']}") for t in d["traits"]]
        traits, vecs = [], {}
        for t, w in zip(d["traits"], writing):
            yield event(step="writing", label=f"Muse Wonder is writing {t['name']} contrast answers")
            data = w.result()
            yield event(step="reading", label=f"Glimmer is reading {len(data['questions'])} {t['name']} answer pairs")
            stored, vec = trait(t, t["value"], data)
            traits.append(stored)
            vecs[t["name"]] = vec
        yield event(step="painting", label="Muse Image is painting the portrait")
        try:
            picture = painting.result()
        except Exception as e:  # a persona without a portrait still works
            print(f"portrait failed: {e}", flush=True)
            picture = None
        pool.shutdown(wait=False)
        p = {"format": FORMAT, "id": os.urandom(8).hex(), "model": MODEL, "layer": LAYER, "hidden": HIDDEN,
             "slug": free_slug(d["name"]), "name": d["name"], "tagline": d["tagline"], "portrait": picture,
             "version": 1, "created": time.time(), "traits": traits, "_vecs": vecs}
        yield event(step="hello", label=f"{d['name']} is saying hello")
        # Steering can wear down Glimmer's manners, so Wonder checks the hello. Each retry pushes 20% softer.
        for scale in (1.0, 0.8, 0.6, 0.4):
            values = {t["name"]: t["value"] * scale for t in traits}
            p["intro"] = "".join(r.text for r in on_gpu(say(HELLO, p, values, 120))).strip()
            if wonder(HELLO_CHECK, p["intro"], 2000).get("ok"):
                break
        save(p)
        personas[p["slug"]] = p
        yield event(done=summary(p))
    return streamed(steps())


@app.patch("/personas/{slug}")
def tune(slug: str, body: dict):
    """{values: {trait: -1..1}} -> saves the persona's slider values as a new version."""
    if slug not in personas:
        raise HTTPException(404)
    p = personas[slug]
    for t in p["traits"]:
        if t["name"] in body.get("values", {}):
            t["value"] = max(-1.0, min(1.0, float(body["values"][t["name"]])))
    p["version"] += 1
    save(p)
    return summary(p)


@app.post("/personas/{slug}/traits")
def add_trait(slug: str, body: dict):
    """{trait: plain-English description} -> SSE steps, then the persona with the new trait at 0.5."""
    if slug not in personas:
        raise HTTPException(404)
    p = personas[slug]

    def steps():
        yield event(step="writing", label="Muse Wonder is writing contrast answers")
        data = wonder(BUILD_SYSTEM, body["trait"])
        name = data["name"]
        while name in p["_vecs"]:
            name += "+"
        yield event(step="reading", label=f"Glimmer is reading {len(data['questions'])} answer pairs")
        stored, vec = trait({"name": name, "description": data["description"]}, 0.5, data)
        p["traits"].append(stored)
        p["_vecs"][name] = vec
        p["version"] += 1
        save(p)
        yield event(done=summary(p))
    return streamed(steps())


@app.delete("/personas/{slug}")
def remove(slug: str):
    if personas.pop(slug, None):
        (PERSONAS / f"{slug}.persona").unlink(missing_ok=True)
    return {"ok": True}


@app.post("/personas/import")
def import_persona(body: dict):
    """{path} -> copies a shared .persona file in. A newer copy of one you have replaces it."""
    try:
        p = load_persona(Path(body["path"]).read_text())
    except (ValueError, KeyError, json.JSONDecodeError, UnicodeDecodeError) as e:
        raise HTTPException(400, str(e) if isinstance(e, ValueError) else "This isn't a Persona file.")
    same = next((s for s, q in personas.items() if q["id"] == p["id"]), None)
    if same:
        personas.pop(same)
        (PERSONAS / f"{same}.persona").unlink(missing_ok=True)
    p["slug"] = free_slug(p["name"])
    save(p)
    personas[p["slug"]] = p
    return summary(p)


JUDGE_SYSTEM = """You rate how strongly an assistant reply expresses given traits, 0 (none) to 100 (extreme).
Also flag if the reply is incoherent. Return JSON only: {"scores": {"<trait>": int, ...}, "coherent": int 0-100}"""


@app.post("/judge")
def judge(body: dict):
    """{persona, question, answer} -> Muse Wonder's score for each of the persona's traits."""
    p = personas.get(body.get("persona"))
    desc = {t["name"]: t["description"] for t in p["traits"]} if p else {}
    if not desc:
        return {"scores": {}, "coherent": None}
    try:
        return wonder(JUDGE_SYSTEM, json.dumps({"traits": desc, "question": body["question"], "reply": body["answer"]}), 3000)
    except Exception as e:
        raise HTTPException(502, str(e))


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PERSONA_PORT", 4410))
    threading.Thread(target=uvicorn.run, args=(app,), kwargs={"host": "127.0.0.1", "port": port}, daemon=True).start()
    while True:
        gen, out, stop = jobs.get()
        try:
            for item in gen:
                if stop.is_set():
                    break
                out.put(item)
        except Exception as e:
            out.put(e)
        gen.close()
        out.put(None)
