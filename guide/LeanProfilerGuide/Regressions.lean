/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import VersoManual
import LeanProfiler
import LeanProfiler.Proofs

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Compare two runs" =>
%%%
tag := "regressions"
%%%

The regression example increases the requested `source.analyze` delay from four milliseconds
to ten. Both runs keep three steps and the two-millisecond read delay.

Generate the captures and compare them.

```
lake exe leanprofiler_regression_example
```

The executable writes its artifacts under `build/regression-walkthrough`. To compare existing
summaries directly, use the command-line interface:

```
lake exe leanprofiler compare \
  build/regression-walkthrough/baseline-summary.json \
  build/regression-walkthrough/candidate-summary.json \
  --metric p95_ns \
  --absolute-tolerance 500000 \
  --relative-tolerance-bps 1000 \
  --json build/regression-walkthrough/comparison.json
```

In the saved comparison, `source.analyze` and the root span exceed both tolerances. The read row
stays within tolerance.

[![A paired-dot plot comparing baseline and candidate p95 values for the three nested example rows](Assets/p95-comparison.svg)](Assets/p95-comparison.svg)

The additional analysis time also increases the root duration. The figure uses the saved
[baseline summary](Assets/nested-spans-summary.json),
[candidate summary](Assets/comparison-candidate-summary.json), and
[comparison JSON](Assets/comparison.json).

# Schedule a capture
%%%
tag := "capture-schedule"
%%%

Use a schedule to record selected steps after startup and warmup. `Schedule.create` classifies
zero-based steps as skip, warmup, record, or record-and-save.

```
let .ok schedule := Schedule.create
    (skipFirst := 2)
    (wait := 1)
    (warmup := 2)
    (active := 3)
    (repeatCount := 2)
  | throw <| IO.userError "active must be positive"
```

The example schedule creates two short active captures inside one longer run:

[![Two repeated capture cycles with skipped, warmup, recorded, and save steps](Assets/capture-schedule.svg)](Assets/capture-schedule.svg)

After the initial skip, each cycle is:

```
wait → warmup → active
```

The last active step returns `recordAndSave`. With `active = 1`, that only active step records and
saves. A zero repeat count continues cycling; a positive repeat count eventually returns `skip`
for every later step.

`Schedule.actionAt` only classifies. The loop may own capture state itself:

```
let action := schedule.actionAt step
if action.records then
  recordStep step
else
  runStep step
if action.saves then
  saveCycle
```

`runScheduledCycle` runs one complete cycle and opens the session around the active interval:

```
let ran ← runScheduledCycle schedule cycle config captureName fun step action =>
  runStep step action
```

Skipped, waiting, and warmup callbacks run before capture begins and can update application
state. Give each recorded cycle its own trace and summary paths.

The schedule lemmas establish its boundary behavior:

```lean
open LeanProfiler

#check Schedule.cycleLength_pos
#check Schedule.actionAt_eq_skip_of_lt_skipFirst
#check ProfilerAction.records_of_saves
```

# Pick the metric that matches the question
%%%
tag := "comparison-metrics"
%%%

Available metrics are:

```
total_ns             self_ns
mean_ns              median_ns
p95_ns               max_ns
total_heartbeats     self_heartbeats
alloc_bytes          peak_live_bytes
```

Use mean, median, or p95 for call latency, and total or self time for aggregate cost. Check call
counts when comparing either. For memory comparisons, confirm both runs measured the same
allocator counters. Missing counters contribute zero to grouped rows.

# Set both tolerances
%%%
tag := "comparison-tolerances"
%%%

A comparison threshold has an absolute allowance in the metric's native unit and a relative
allowance in basis points:

```
let config : ComparisonConfig := {
  metric := .p95Ns
  threshold := {
    absolute := 500_000
    relativeBps := 1000
  }
}
```

For a nanosecond metric, these allowances are 0.5 milliseconds and 10%. An increase is a regression
when it exceeds both. The absolute tolerance handles small noisy spans, and the relative tolerance
scales with the baseline.

When the baseline is zero, only the absolute allowance can be evaluated.

# Match the whole key
%%%
tag := "comparison-keys"
%%%

Comparisons match name, phase, activity, backend, dtype, device, and module. A row found only in the
baseline is `missing`; one found only in the candidate is `new`.

Use `--fail-on-new` or `--fail-on-missing` to require a stable set of keys. Otherwise the
comparison reports those rows and evaluates the matched rows.

The result stores the baseline and candidate values, signed delta, basis-point change, call counts,
and one of:

- `improvement`;
- `within_tolerance`;
- `regression`.

# Validate comparison inputs
%%%
tag := "strict-summary-input"
%%%

The command returns:

:::table +header
*
  * Exit
  * Meaning
*
  * `0`
  * selected policy passed
*
  * `1`
  * a regression or requested key policy failed
*
  * `2`
  * arguments or artifacts were invalid
:::

It refuses summaries with dropped events or analyzer issues. `--allow-incomplete` is available for
deliberate diagnosis and is recorded in the comparison JSON.

# Collect defensible samples
%%%
tag := "repeatable-measurement"
%%%

A report's p95 summarizes calls within one process. Compare several process runs under the
following conditions.

1. pin the Lean toolchain and Lake manifests;
2. use the same build settings and machine;
3. fix workload, seed, backend, dtype, device, and synchronization policy;
4. isolate warmup from active samples;
5. collect several independent baseline and candidate runs;
6. inspect the distribution before setting a tolerance;
7. retain traces and summaries for failed comparisons.

Use the same completion policy in both captures. Synchronizing a GPU changes which work falls
inside the measured interval.
