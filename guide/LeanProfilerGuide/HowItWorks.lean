/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import VersoManual
import LeanProfiler

open Verso.Genre Manual

#doc (Manual) "How a span becomes a report" =>
%%%
tag := "how-it-works"
%%%

A span records one named action.

```
span "source.analyze" (analyzeSource source)
```

The caller supplies the name. LeanProfiler manages its parent, thread, timestamps, and report
entry in four steps.

```
reserve its place in the event tree
sample time and Lean heartbeats around the action
complete and retain an event
analyze all retained events when the session ends
```

# The session owns the capture
%%%
tag := "session-capture"
%%%

`profile` starts one process-wide recording session. It resets the event buffer, records a process
snapshot, enables instrumentation, and opens the root span. When the action finishes, it disables
new recording before analyzing and exporting the completed events.

The session owns the process-wide buffer and output paths. Calls to `span` can nest inside it.
An overlapping `profile` call raises an error.

If profiling is disabled, `profileFromEnvironment` still runs the action and `span` does not retain
an event. This keeps instrumentation in normal application code instead of requiring a separate
profiling build.

# Reservation establishes the event tree
%%%
tag := "span-reservation"
%%%

Before the timed action starts, LeanProfiler reserves an event index under a mutex. The reservation
reads the current Lean thread identifier and the innermost active span on that thread. It records:

:::table +header
*
  * Field
  * Meaning at reservation time
*
  * `index`
  * a monotonically increasing event identifier
*
  * `parentIndex`
  * the active local parent, or an explicitly supplied cross-thread parent
*
  * `depth`
  * the event's nesting depth in the logical tree
*
  * `threadId`
  * the Lean execution thread that admitted the span
*
  * inherited metadata
  * dynamic phase, module, step, and related context
:::

The index is reserved before the action because completion order is not execution order. A short
child may finish before its parent, and two worker threads may finish in either order. Export sorts
events by their reservation indices, while every event also keeps its actual start and stop times.

Each Lean thread has its own nesting stack. A newly opened span inherits the active parent on
that thread. A caller can pass its parent index to a worker to record a cross-thread dependency.
All timestamps use the process monotonic clock.

# The timed interval has a precise boundary
%%%
tag := "timed-interval"
%%%

Once reservation is complete, the profiler samples `IO.monoNanosNow` and
`IO.getNumHeartbeats`, runs the action, and samples both again. The resulting event stores elapsed
monotonic host time and the difference in Lean heartbeats.

Host time includes waiting, scheduling, and synchronous foreign calls. Lean heartbeats count
runtime work on the current Lean thread, mainly through small allocations. Comparing the two can
help locate a slowdown. An increase in host time with few additional heartbeats suggests waiting
or foreign work, while an increase in both suggests more Lean work. Either pattern needs further
measurement to identify its cause.

A `finally` block completes the event and restores the thread stack when the action throws.
The caller receives the original exception, and the session attempts to export the completed
spans.

# Hooks define when asynchronous work is finished
%%%
tag := "span-hook-boundary"
%%%

A GPU launch can return while its work is still running. An adapter can use `SpanHooks` to wait
for completion before LeanProfiler takes the stop timestamp.

```
prepare
  start clock
    run action
    completeTiming
  stop clock
enrich metadata
```

`prepare` creates adapter state before timing. `completeTiming` may synchronize the selected
runtime before the stop sample. `enrich` runs outside the measured interval and can attach allocator
or device counters. The metadata should name the timing convention because a synchronized device
span and an unsynchronized host-launch span answer different questions.

Use a device profiler such as Nsight for the kernel activity inside that interval.

# Analysis computes inclusive and self time
%%%
tag := "event-analysis"
%%%

After the session closes, `analyze` first sorts the events by reservation index and validates their
structure. It checks duplicate indices, missing parents, impossible depths, reversed intervals, and
child intervals that extend outside their parents. Validation issues remain in the report instead
of being silently repaired into benchmark data.

Inclusive time is the length of the event interval. Self time subtracts the portion covered
by its immediate children on the same thread.

$$`t_{\mathrm{self}}(e)
  = |I_e| - \left|\bigcup_{c \in C_e} (I_c \cap I_e)\right|`

The union counts overlapping child intervals once. The analyzer clips them to the parent's
interval and bounds the subtraction, including when a malformed capture is being inspected.

Cross-thread children retain their parent links. Their intervals can overlap the caller's work,
so the analyzer leaves the caller's self time intact.

Heartbeats follow the same parent rule when a same-thread child lies completely inside its parent.
The analysis layer proves that every emitted timing has self time no greater than inclusive time,
and likewise for heartbeats.

# Repeated spans become summary rows
%%%
tag := "summary-grouping"
%%%

Individual events remain in the timeline. For comparison, repeated events are grouped by a stable
structured key:

```
name, phase, activity, backend, dtype, device, module
```

Step numbers and shape arrays remain event metadata, so a thousand training steps do not turn into
a thousand unrelated rows. Each group records call count, total inclusive and self time,
minimum, mean, median, nearest-rank p95, maximum, heartbeat totals, and any memory counters supplied
by an adapter.

The Trace Event file preserves the timeline for Perfetto. The summary JSON stores grouped
measurements and validation results for scripts and comparisons.

# What LeanProfiler does not infer
%%%
tag := "profiler-limits"
%%%

The program supplies span boundaries and metadata. Allocator and device measurements require an
adapter, while stack samples and automatic operator discovery require other instrumentation.

Recording a span costs mutex access, clock and heartbeat samples, and event storage. Analysis runs
after the session. Use selected phases and short scheduled captures to keep these costs manageable.
