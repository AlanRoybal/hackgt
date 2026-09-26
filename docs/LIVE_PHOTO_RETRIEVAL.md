# Live photo retrieval

The old client discarded partial Transcribe results and waited another three seconds
after a final result. Continuous speech could reset that timer indefinitely.

The client now enables medium partial-result stabilization, consumes only the stable
word prefix, and sends up to the last 48 words on a fixed 1.2-second timer once at least
five words are available. New words replace the pending snapshot without restarting
the timer. Finals send immediately and remain the only text stored in call history.
Earlier final segments remain backend context for resolving references across sentences.

The backend allows one retrieval per speaker at a time using a conditional DynamoDB
lease. Competing partials are skipped; finals wait up to 12 seconds for a turn. A final
that arrives during partial retrieval suppresses that partial's result. Work older than
12 seconds and results for ended calls are suppressed. Stable words are still incomplete
thoughts, so partial suggestions require a tap even in automatic photo-sharing mode.

Image and caption searches execute concurrently. Embeddings no longer have the city
appended to every search view. The reranker gets the actual spoken words and requires
the concrete subject, not just a matching location. Already suggested photos stay in the
candidate pool; selecting one suppresses a duplicate rather than promoting an unrelated
runner-up. Invalid/unavailable reranking returns no suggestion instead of guessing.

## Validation

- Unit tests: stable/unstable ASR words, replacement of partial revisions, immediate finals,
  continuous speech timer, concurrent retrieval, manual partial suggestions, repeated photos,
  and reranker failure.
- Live Nova metadata fixture: ramen meal vs. Houston skyline selects ramen (0.95 confidence);
  skyline alone returns no match. Observed model times: 514 ms and 324 ms. This is not an
  evaluation of the user's actual photo library or an end-to-end latency measurement.
- Device acceptance: talk continuously about the Houston Chinatown ramen meal; the card
  should appear without a pause. Repeat the same reference (no unrelated runner-up), switch
  topics, and try a location-only reference and a correction. Confirm both participants'
  calls and transcription continue normally.

Remaining limits: stable ASR words can still be wrong; captions may omit food details;
the correct image may not be indexed or may miss the candidate pool. Measure real-call
stage latency and top-1 accuracy before claiming a speed/accuracy improvement. The 1.2-second
window bounds client scheduling after stable words arrive, not total suggestion latency.
