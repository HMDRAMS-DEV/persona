"""Layer sweep: which Glimmer layer steers each trait best?

Imports the server module (loads Glimmer, no HTTP), wraps every swept layer, and for each trait:
fresh contrast pairs from Muse Wonder -> one read records every layer -> steer held-out questions
at each layer -> Muse Wonder scores trait and coherence. Close Persona first; it needs the GPU.

Steering is alpha * raw v_layer with alpha fixed per trait (the paper's h <- h + alpha * v), set so
layer 31 matches the app at +0.8. Run: .venv/bin/python scripts/sweep.py
"""
import json, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server"))
import persona as T  # noqa: E402
import mlx.core as mx  # noqa: E402
from mlx_vlm import stream_generate  # noqa: E402

LAYERS = [16, 21, 26, 31, 36, 41, 46, 50]
QUESTIONS = ["How should I spend my Saturday?", "What's a good way to learn a new language?",
             "Can you explain how a refrigerator works?"]
SLIDER = 0.8
OUT = ROOT / "build" / "sweep"
OUT.mkdir(parents=True, exist_ok=True)

for i in LAYERS:
    if not isinstance(T.layers[i], T.Steer):
        T.layers[i] = T.Steer(T.layers[i])
steers = {i: T.layers[i] for i in LAYERS}


def vectors(data):
    """Mean over response tokens, positive minus negative, at every swept layer in one pass per answer."""
    sums = {side: {i: [] for i in LAYERS} for side in ("positive", "negative")}
    for side in sums:
        for q, a in zip(data["questions"], data[side]):
            head = T.template([{"role": "user", "content": q}])
            n_head = len(T.tok.encode(head))
            for s in steers.values():
                s.record = []
            T.model.language_model(mx.array([T.tok.encode(head + a)]))
            for i, s in steers.items():
                sums[side][i].append(s.record[0][0, n_head:].astype(mx.float32).mean(axis=0))
                s.record = None
    vecs = {i: mx.stack(sums["positive"][i]).mean(0) - mx.stack(sums["negative"][i]).mean(0) for i in LAYERS}
    mx.eval(list(vecs.values()))
    return vecs


def reply(question, layer=None, add=None):
    if layer is not None:
        steers[layer].add = add
    try:
        prompt = T.template([{"role": "user", "content": question + " Answer in about 60 words."}])
        return "".join(r.text for r in stream_generate(T.model, T.processor, prompt, max_tokens=110,
                                                       temperature=0.7, top_p=0.95))
    finally:
        if layer is not None:
            steers[layer].add = None


def judge(trait, desc, question, answer):
    r = T.wonder(T.JUDGE_SYSTEM, json.dumps({"traits": {trait: desc}, "question": question, "reply": answer}), 3000)
    return r["scores"].get(trait, 0), r.get("coherent", 0)


traits = [json.loads(f.read_text()) for f in sorted((ROOT / "vectors").glob("*.json"))]
runs = []  # (trait, layer or None, question, answer)
for q in QUESTIONS:  # one unsteered baseline per question, judged for every trait
    base = reply(q)
    runs += [(t["name"], None, q, base) for t in traits]
for t in traits:
    pairs_file = OUT / f"{t['slug']}-pairs.json"
    if not pairs_file.exists():
        pairs_file.write_text(json.dumps(T.wonder(T.BUILD_SYSTEM, t["description"]), indent=1))
    vecs = vectors(json.loads(pairs_file.read_text()))
    alpha = SLIDER * T.STRENGTH / float(mx.linalg.norm(vecs[31]))
    for i in LAYERS:
        for q in QUESTIONS:
            runs.append((t["name"], i, q, reply(q, i, vecs[i] * alpha)))
            print(f"{t['name']:16} L{i:<3} {runs[-1][3][:70]!r}", flush=True)

desc = {t["name"]: t["description"] for t in traits}
with ThreadPoolExecutor(8) as pool:
    scores = list(pool.map(lambda r: judge(r[0], desc[r[0]], r[2], r[3]), runs))

rows = [{"trait": r[0], "layer": r[1], "question": r[2], "answer": r[3], "trait_score": s[0], "coherent": s[1]}
        for r, s in zip(runs, scores)]
(OUT / "results.json").write_text(json.dumps(rows, indent=1))

print(f"\n{'trait':16} {'layer':>5} {'trait':>6} {'coherent':>9}")
for t in traits:
    for layer in [None] + LAYERS:
        rs = [r for r in rows if r["trait"] == t["name"] and r["layer"] == layer]
        print(f"{t['name']:16} {('base' if layer is None else layer):>5} "
              f"{sum(r['trait_score'] for r in rs) / len(rs):6.0f} {sum(r['coherent'] for r in rs) / len(rs):9.0f}")
