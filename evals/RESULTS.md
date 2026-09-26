# Eval results

Run date: 2026-09-26, us-east-1, production prompt modules from `backend/src/ai/*`. Re-run from `backend/`:

```sh
npx tsx ../evals/detector/run.ts
npx tsx ../evals/retrieval/run.ts      # images already downloaded; generate.ts rebuilds them
npx tsx ../evals/safety/run.ts
```

## Reference detector (SPEC REF-2) — Amazon Nova Lite

140 labeled two-speaker windows: 62 positives, 40 plain negatives, 30 hard negatives (future plans, the friend's experiences, media/hearsay, long ago, "didn't take pictures", questions), and 8 multi-topic context cases.

| Metric | Result | Target |
|---|---|---|
| Precision | **1.000** (TP 60, FP 0) | ≥ 0.85 |
| Recall | **0.896** (FN 7) | ≥ 0.60 |
| Hard-negative false positives | 0 / 30 | — |
| Context cases: query is about the last line | 5 / 5 | — |
| Detector latency | p50 467 ms, p95 695 ms | — |

Misses are events the model judged too generic (graduation caps, a recital, porch visit, a study-session whiteboard, latte art, moving boxes, a thunderstorm). The gate is `isReference && confidence ≥ 0.5`.

History: the first run scored 0 recall because Nova Lite wrote `"isReference": yes` (invalid JSON) and copied the prompt's example query; fixed by a stricter output spec and a tolerant parser. An integration test then showed earlier references in the same minute leaking into later queries; fixed by presenting the newest line separately (D-108) and adding the context cases.

## Retrieval (SPEC REF-3) — Titan Multimodal Embeddings G1, 1024 dims

60 CC0 / public-domain photos (Openverse, `retrieval/CREDITS.json`), one spoken-style query each, plus 15 negative queries with no matching photo.

| Strategy | Top-1 | Top-3 | Threshold (Youden) | TPR / FPR at threshold |
|---|---|---|---|---|
| **Image only (production)** | **1.000** | **1.000** | 0.375 | 1.00 / 0.00 |
| Image + Nova caption fused | 0.950 | 0.967 | 0.52 | 0.72 / 0.20 |
| Caption text only | 0.683 | 0.800 | 0.63 | 0.10 / 0.00 |

Targets: top-1 ≥ 0.7, top-3 ≥ 0.9 — met. Production threshold **0.37** (positives' min similarity 0.379, negatives' max 0.373). The margin is thin; see D-105.

Caveat: queries were written after looking at the photos, and a real camera roll has many more near-duplicates than 60 mixed photos, so real-world top-1 will be lower. The live integration test (6 photos + unrelated fixtures, detector-generated queries from natural sentences) got 6/6 correct.

## Photo safety (SPEC PHO-2) — Rekognition moderation + DetectText, rules, Nova Lite second opinion

16 locally rendered fixtures (no explicit imagery): 9 with fake sensitive data, 7 benign.

| | Result |
|---|---|
| Sensitive excluded | **9 / 9 (100%)** — card (Luhn), driver's license, bank app balance, OTP SMS, Wi-Fi password, medical record, SSN, IBAN, passport |
| Benign wrongly excluded | **0 / 7** — menu, street sign, birthday card, book page (text-heavy → LLM said not sensitive), market poster, grocery list, whiteboard |

Moderation-label filtering (Explicit, Non-Explicit Nudity, Violence, Visually Disturbing, Hate Symbols, Rude Gestures) is covered by unit tests with mocked Rekognition responses (`backend/test/safety.test.ts`); no explicit imagery is committed.

## Cost

About 200 Nova Lite calls, about 300 Titan embeddings, and 16 Rekognition image pairs. Well under $1 at list price, all first-party and credit-eligible.
