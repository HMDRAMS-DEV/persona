# Persona

Create, tune and share AI personas for Muse Glimmer, steered by persona vectors instead of prompts.

Answer five questions about how you like to be helped. Muse Wonder designs a persona with two or three traits, Glimmer reads a direction for each trait out of its own hidden state, and Muse Image paints the persona as a version of Jolly. The result is a `.persona` file of about 200 KB that anyone can open, tune with sliders, and share again.

Built for the Meta Global AI Developer Hackathon (Oct 26 to Nov 4, 2026).

## How it works

A persona vector is the difference in Glimmer's residual stream between replies that show a trait and replies that don't (Chen et al. 2025, [arXiv 2507.21509](https://arxiv.org/abs/2507.21509)). Adding it back during generation, `h ← h + αv`, moves the model's personality without a word of prompt.

1. **Design.** Muse Wonder turns the interview answers into a name, a tagline, a portrait brief and 2 or 3 stylistic traits.
2. **Write.** For each trait, Muse Wonder writes 12 contrast pairs: the same answer with and without the trait.
3. **Read.** Glimmer runs both sides of every pair. The mean difference at layer 31 of 52 is the trait's vector (6656 numbers).
4. **Paint.** Muse Image edits a Jolly reference into the persona's outfit and prop.
5. **Check.** Glimmer writes a steered hello. Steering can wear down the model's manners, so Muse Wonder checks the hello and the server retries at 20% softer steering, up to four times.
6. **Chat.** Every reply adds the slider-weighted sum of the trait vectors at layer 31, capped so stacked traits stay coherent.

## Meta models used

| Model | Where | Role |
| --- | --- | --- |
| Muse Glimmer 30B (`mlx-community/Muse-Glimmer-30B-4bit`) | Local, Apple silicon, MLX | Chat, trait reading, steering |
| Muse Wonder (`muse-wonder-1.0`) | Meta Model API or OpenRouter | Persona design, contrast pairs, judging |
| Muse Image (`muse-image-1.0`) | Meta Model API or OpenRouter | Persona portraits (image to image) |

## Run it

Needs an Apple silicon Mac with 32 GB of memory or more, Python 3.12, and the Xcode Command Line Tools (macOS 26 SDK).

```sh
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
./build.sh                    # builds build/Persona.app, no Xcode project
open build/Persona.app        # starts the server; the first load of the weights takes about a minute
```

The first time you make a persona, the app asks for a [Meta Model API](https://dev.meta.ai) key or an [OpenRouter](https://openrouter.ai/keys) key and saves it to `.env`. You can also set `MODEL_API_KEY` or `OPENROUTER_API_KEY` there yourself (see `.env.example`). The starter personas chat without a key.

The server alone: `.venv/bin/python server/persona.py` (port 4410). Reseed the starter gallery with `.venv/bin/python scripts/starters.py`.

## Layout

- `Persona/`: SwiftUI Mac app (gallery, create walkthrough, chat, tuning sliders, import and export).
- `server/persona.py`: FastAPI server. Glimmer on MLX, steering hook, persona build pipeline.
- `server/assets/jolly.jpg`: Jolly reference image, generated with Muse Image.
- `personas/`: the four starter personas, preloaded with their portraits.
- `scripts/sweep.py`: the layer sweep that picked layer 31.
- `deck/`: the pitch deck, a single static HTML page.

## The `.persona` file

Self-contained JSON (`format: "persona/1"`): name, tagline, intro, portrait (base64 JPEG), the model and layer it was read from, and per trait its description, slider value, vector (base64 float32) and the contrast pairs it came from. Import checks the model's layer and hidden size, and re-importing a file with the same id replaces the older version.

## Licence

Apache 2.0, see `LICENSE`. Muse Glimmer weights are Apache 2.0 (Meta). Jolly is Meta's Muse mascot.
