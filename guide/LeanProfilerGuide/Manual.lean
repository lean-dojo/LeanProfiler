/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import VersoManual
import LeanProfiler
import LeanProfilerGuide.GettingStarted
import LeanProfilerGuide.HowItWorks
import LeanProfilerGuide.Capture
import LeanProfilerGuide.Results
import LeanProfilerGuide.Regressions
import LeanProfilerGuide.ProfilerComparison
import LeanProfilerGuide.TorchLean

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "LeanProfiler" =>
%%%
shortTitle := "LeanProfiler"
tag := "leanprofiler"
%%%

LeanProfiler records how compiled Lean programs spend their time. We can measure a numerical
solver, a proof-search procedure, or a model's training loop by placing named spans around the
operations we want to study. Each span records elapsed time, its parent and thread, Lean
heartbeats, and any metadata supplied by the application.

The same instrumentation produces a timeline for inspecting one run and a summary for comparing
repeated runs. We use it in TorchLean to measure training and numerical workloads, with explicit
synchronization when a measurement includes GPU work.

```lean -keep
open LeanProfiler

/-- Record loading and analysis in separate spans. -/
def profileAnalysis
    (load : IO String)
    (analyze : String → IO Nat) : IO Nat :=
  profileFromEnvironment "analysis" do
    let source ← span "source.read" load
    span "source.analyze" (analyze source)
```

Enable recording with `LEAN_PROFILE=1` when running the executable. Open the resulting trace in
[Perfetto](https://ui.perfetto.dev), or use the JSON summary to compare call counts, self time,
percentiles, and heartbeats.

[![Recorded spans from the source-indexing simulation, with reads and analysis nested inside one run](Assets/nested-spans-timeline.svg)](Assets/nested-spans-timeline.svg)

This trace comes from the [nested-spans example](https://github.com/lean-dojo/LeanProfiler/blob/main/Examples/NestedSpans.lean).
Its short sleeps simulate reading and analysis so that the nesting and timing calculation are easy
to inspect. The guide develops that example, explains the measurement rules, and then applies the
same API to TorchLean.

Start with [a first recording](Record-your-first-run/#getting-started), inspect
[a trace and summary](Read-the-trace-and-summary/#results), or go directly to
[profiling TorchLean](Profile-TorchLean/#torchlean).

{include 1 LeanProfilerGuide.GettingStarted}

{include 1 LeanProfilerGuide.HowItWorks}

{include 1 LeanProfilerGuide.Capture}

{include 1 LeanProfilerGuide.Results}

{include 1 LeanProfilerGuide.Regressions}

{include 1 LeanProfilerGuide.ProfilerComparison}

{include 1 LeanProfilerGuide.TorchLean}
