/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import VersoManual
import LeanProfiler

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Design the capture" =>
%%%
tag := "capture"
%%%

The introductory trace has two phases. A source indexer with separate parsing and writing work
could add spans around those calls too.

```
for (sourcePath, fileIndex) in sourcePaths.zipIdx do
  let contents ← readSource sourcePath
  let syntax ← parseSource contents
  let declarations ← analyzeSource syntax
  writeIndex sourcePath declarations
```

Use reading, parsing, analysis, and writing as stable event names. Put the source path, module,
and iteration number in metadata.

```
profileFromEnvironment "indexer.run" do
  for (sourcePath, fileIndex) in sourcePaths.zipIdx do
    withStep fileIndex do
      let contents ← span "source.read" (readSource sourcePath)
      let syntax ← span "source.parse" (parseSource contents)
      let declarations ← span "source.analyze" (analyzeSource syntax)
      span "index.write" (writeIndex sourcePath declarations)
```

Repeated calls share summary rows, and the trace retains their individual file indices.

# Keep names stable and put variation in metadata
%%%
tag := "event-identity"
%%%

Keep the event name stable across calls. Metadata records which module, shape, or backend each
call used.

```
span "source.analyze" (analyzeSource syntax) (metadata := {
  phase := some "analysis"
  activity := some "source file"
  backend := some analyzerName
  moduleName := some moduleName
  stepIndex := some fileIndex
})
```

LeanProfiler uses the following fields as the summary key:

```
name, phase, activity, backend, dtype, device, module
```

`name` is required. The remaining fields are optional and split the summary into separate rows.
Use `backend` to distinguish implementations, `module` for components, and `dtype` and `device`
for numerical workloads.

Step numbers, graph node labels, and shapes stay on individual trace events. They leave the
grouping key unchanged, so repeated calls contribute to the same distribution. If another label
needs its own summary row, use one of the grouping fields.

# Carry repeated context through the loop
%%%
tag := "metadata-context"
%%%

Use dynamic context for labels shared by several nested spans.

```
for (sourcePath, fileIndex) in sourcePaths.zipIdx do
  withStep fileIndex do
    span "source.read" (readSource sourcePath) (metadata := {
      activity := some "filesystem"
    })

    withModule moduleName do
      withPhase "analysis" do
        span "source.analyze" (analyzeSource syntax) (metadata := {
          backend := some analyzerName
        })
```

`withStep`, `withModule`, and `withPhase` apply while their actions run and restore the previous
context afterward.

An explicit scalar field on a span overrides the surrounding context. Shape arrays inherit from
the context only when the span supplies an empty array. This makes a broad module label convenient
without preventing one inner operation from naming a more precise module or shape.

# Keep one session around the question
%%%
tag := "session-ownership"
%%%

One `profile` call owns one capture buffer and produces one trace-summary pair. At the beginning of
the session it clears old events and enables recording. At the end it disables recording, checks
the event structure, computes summary rows, and writes both artifacts.

```
def profileIndexer (config : ProfilerConfig) : IO Unit :=
  profile config "indexer.run" do
    buildIndex
```

Nested `span` calls are normal. Nested or overlapping `profile` calls are rejected because two
sessions cannot safely own the same process-wide buffer or output paths.

If `buildIndex` throws, LeanProfiler attempts to export the completed spans and rethrows the
original exception. If export also fails, it prints that secondary error.

# Wait for worker tasks that belong to the run
%%%
tag := "worker-boundary"
%%%

A session ends when its top-level action returns. Await the workers you want included before
leaving that action.

A worker thread has its own nesting stack. To retain the logical relationship with the caller,
capture the active parent index and install it in the worker:

```lean -keep
open LeanProfiler

/-- Await a worker while preserving its parent span. -/
def decodeInWorker (decode : IO Unit) : IO Unit := do
  let some parent ← currentSpanIndex
    | throw <| IO.userError "expected an active parent span"

  let task ← IO.asTask do
    withParentIndex parent do
      span "worker.decode" decode

  IO.ofExcept task.get
```

The trace stores the worker's `parent_index` for correlation. Cross-thread child intervals can
overlap the caller's work, so they leave the parent's self time intact.

# Close a span only after asynchronous work finishes
%%%
tag := "completion-hooks"
%%%

An ordinary span stops when its host action returns. That is correct for synchronous work, but a
GPU launch or foreign runtime may return while the measured operation is still running.
`SpanHooks` makes the completion rule explicit:

```
prepare
  start timestamp
    action
    completeTiming
  stop timestamp
enrich
record event
```

`prepare` creates adapter state outside the timed interval. `completeTiming` waits for the work
whose completion defines the measurement. `enrich` runs after the stop timestamp and can attach
counters without adding their collection cost to the duration.

```
let hooks : SpanHooks := {
  State := AsyncToken
  prepare := makeTimingToken
  completeTiming := waitForRuntime
  enrich := fun token metadata => do
    let live ← readLiveBytes token
    pure { metadata with allocLiveBytes := some live }
}

span "foreign.compute" submitWork
  (metadata := {
    backend := some runtimeName
    timing := some "runtime-synchronized"
  })
  (hooks := hooks)
```

This interval includes submission, queue delay, and the wait for completion. Use the foreign
runtime's profiler to inspect its individual operations.

Errors from `completeTiming` and `enrich` are written to `metadata.hookError`. They do not replace
an exception raised by `submitWork`. An error from `prepare` occurs before the event is reserved
and returns directly to the caller.

# Keep long captures finite
%%%
tag := "event-limits"
%%%

A trace of every operation in a long-running program can consume substantial memory and become harder
to inspect than the program itself. Set a retained-event limit when the workload is not naturally
small:

```
LEAN_PROFILE=1 \
LEAN_PROFILE_MAX_EVENTS=250000 \
lake exe your_executable
```

LeanProfiler retains the spans with the first 250,000 reserved indices. Later spans still run and
unwind their local nesting stacks, but their records are dropped. The summary reports both the
configured limit and `dropped_events`.

The comparison command requires complete captures unless
`--allow-incomplete` is supplied. A short scheduled capture after warmup is usually easier to
compare than a long retained prefix.

# Give every memory number a precise meaning
%%%
tag := "allocation-semantics"
%%%

An allocator adapter can supply allocated, live, peak, and net-change byte counters. Record
which allocator they describe and when it was sampled.

Two snapshots can answer a narrow question:

```
net change = live bytes after - live bytes before
```

Allocations between the snapshots can disappear before the second sample. Measuring their peak
requires an allocator counter or an event stream. Process peak RSS covers the whole process and
has its own high-water-mark semantics. Trace metadata can leave unmeasured counters absent.
Grouped summary rows use zero for absent allocation counters, so consult the adapter and
trace metadata before interpreting them.

# The resulting event tree
%%%
tag := "capture-result"
%%%

After these choices, one file in the indexing capture has a clear structure:

```
indexer.run
├── source.read                step=17, activity=filesystem
├── source.parse               step=17, phase=parse
├── source.analyze             step=17, module=Project.Parser
│                              backend=incremental
└── index.write                step=17, phase=output
```

`withStep` labels these four events with step 17. Each remains a direct child of `indexer.run`.
Their summary rows combine observations from later steps under the same keys.
