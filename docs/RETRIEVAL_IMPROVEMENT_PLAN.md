# Photo retrieval improvement plan

## Goal

When a person mentions a recent photo during a call, suggest the photo they mean with a clear confidence signal. A wrong suggestion should be rare; uncertainty should result in no suggestion or a small choice set.

## Current pipeline

`Amazon Transcribe → Nova reference detector → one Titan text embedding → S3 Vectors top 5 → highest cosine score above 0.37`

Photos are indexed with a Titan image embedding. Nova captions and photo date/place metadata are saved, but the live search currently relies almost entirely on one image-vector similarity score.

## Plan

### 1. Measure real failures

**Implement**

- Log each retrieval attempt with a privacy-safe event: detected query, detector confidence, top 10 similarity scores, date/place hints, selected result, and outcome (`no_reference`, `no_match`, `suggested`, `shared`, `dismissed`).
- Add **Not this** and **Show alternatives** actions to the suggestion card.
- Build a consented evaluation set from real camera-roll photos and natural spoken references, including Transcribe output, near duplicates, vague language, date/place references, and true negatives.

**Success measure**

Report detector recall, top-1/top-3 retrieval accuracy, suggestion acceptance rate, and wrong-suggestion rate separately. Do not tune against the current small curated image set alone.

### 2. Send complete spoken thoughts to the detector

**Implement**

- Buffer final transcript segments for 2–4 seconds and merge adjacent segments from the same speaker.
- Preserve the current guardrail: only the newest completed thought can trigger a suggestion; earlier speech is context only.
- Ignore duplicate transcript events and very short fragments.

**Why**

Live transcription often splits a meaningful reference across several final segments. A complete phrase produces a better detection decision and search query.

### 3. Retrieve with multiple query views

**Implement**

- Ask the detector for three short fields: `literalQuery`, `visualQuery`, and `entityQuery`.
- Embed each field with Titan and retrieve the top 10 candidates for each.
- Combine candidates with reciprocal-rank fusion, then remove duplicates and already-suggested photos.

**Example**

For “remember the restaurant with all the lanterns?” search both `restaurant with lanterns` and `dim restaurant interior with hanging lanterns`, plus a detected venue or neighborhood when available.

### 4. Use captions, time, and place in ranking

**Implement**

- Create a second S3 Vector index for caption-text embeddings. Keep the existing image-only index unchanged.
- Retrieve from both indexes and combine image similarity with caption similarity.
- Apply date and normalized-place matches as a ranking boost, not a strict filter. Retain the current fallback when an exact date/place filter produces no candidates.
- Group near-duplicate photos from the same capture window so the UI suggests one representative first.

**Why**

The image vector matches visual concepts; the caption and metadata better capture names, activities, venues, and time references spoken on a call.

After the infrastructure change is deployed, run `npm run backfill:captions` with the deployed table, vector-bucket, and caption-index environment variables so existing indexed photos receive a caption vector too.

### 5. Rerank only the finalists

**Implement**

- Pass the top 5–10 fused candidates to Nova Lite with the spoken reference, caption, date, and place.
- Require structured output: best candidate, confidence, and `no_match` when none is sufficiently related.
- Send one suggestion only when reranker confidence and the top-result margin are both high. Otherwise offer the best 2–3 photos or send nothing.

**Why**

Cosine similarity is a good recall stage. A small, bounded reasoning pass is better at resolving which of several visually similar photos the person meant.

### 6. Tune thresholds with feedback

**Implement**

- Replace the global `0.37` cutoff with values calibrated on the real evaluation set.
- Tune three decisions independently: detector confidence, retrieval score/margin, and reranker confidence.
- Review false positives before lowering any threshold; avoid suggestions when confidence is uncertain.

## Delivery order

1. Add retrieval-attempt events and the feedback UI.
2. Assemble the real evaluation set and baseline its metrics.
3. Add transcript buffering and multi-query retrieval.
4. Add caption index, metadata scoring, and duplicate grouping.
5. Add Nova Lite reranking and tune thresholds.
6. Run the same evaluation after every change and keep only changes that improve top-1 accuracy without raising wrong suggestions.

## Non-goal

Do not replace Titan or add a GPU-hosted model until this improved pipeline is measured. If results remain weak after these steps, A/B test dedicated image-text embedding models on the same real evaluation set and select one based on accuracy, latency, cost, and operational complexity.

## Backlog: make suggestions feel immediate

Observed device testing shows roughly five seconds between a spoken reference and a card appearing. Before changing the pipeline, trace one real call end-to-end using the existing client and CloudWatch stage metrics: Transcribe finalization, transcript batching, detector, embedding/vector retrieval, Nova rerank, WebSocket delivery, and thumbnail fetch/render. Keep the accuracy guardrails above intact, then target the largest measured contributor. Likely candidates are reducing the 3-second transcript quiet window when speech has clearly ended, parallelizing independent retrieval requests, and displaying the suggestion shell before the thumbnail finishes downloading.
