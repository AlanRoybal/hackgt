// CloudWatch Embedded Metric Format for pipeline latency (namespace Nudge/Latency).

export function emitLatency(stages: Record<string, number>, dims: { pipeline: string }, props: Record<string, unknown> = {}) {
  const metrics = Object.keys(stages).map((Name) => ({ Name, Unit: 'Milliseconds' }));
  console.log(
    JSON.stringify({
      _aws: {
        Timestamp: Date.now(),
        CloudWatchMetrics: [{ Namespace: 'Nudge/Latency', Dimensions: [['pipeline']], Metrics: metrics }],
      },
      pipeline: dims.pipeline,
      ...stages,
      ...props,
    }),
  );
}

/** Stopwatch that records named stage durations. */
export function stopwatch() {
  const t0 = Date.now();
  let last = t0;
  const stages: Record<string, number> = {};
  return {
    lap(name: string) {
      const now = Date.now();
      stages[name] = now - last;
      last = now;
    },
    total() {
      stages.total = Date.now() - t0;
      return stages;
    },
    stages,
  };
}
