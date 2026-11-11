/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import VersoManual
import LeanProfiler

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Record your first run" =>
%%%
tag := "getting-started"
%%%

Start by naming the phases you want to measure. For a training step, these might be data loading,
forward evaluation, backward evaluation, and the optimizer update. Record those phases first, then
add detail where the trace shows an expensive call.

Add LeanProfiler to the Lake package that owns the executable:

```
[[require]]
name = "LeanProfiler"
git = "https://github.com/lean-dojo/LeanProfiler"
rev = "main"
```

Add `import LeanProfiler` to the file and put one session around the run. Name its phases with spans.

```lean -keep
open LeanProfiler

/-- Simulate a file read for this timing example. -/
def readSource : IO Unit :=
  IO.sleep 2

/-- Simulate analysis as a separate measured phase. -/
def analyzeSource : IO Unit :=
  IO.sleep 4

/-- Record both phases in one profiling session. -/
def main : IO Unit :=
  profileFromEnvironment "indexer.run" do
    span "source.read" readSource
    span "source.analyze" analyzeSource (metadata := {
      phase := some "analysis"
      activity := some "source file"
      moduleName := some "indexer"
    })
```

Run the executable with profiling enabled:

```
LEAN_PROFILE=1 lake exe your_executable
```

The default files are:

```
build/leanprofiler-trace.json
build/leanprofiler-summary.json
```

Open the trace in [Perfetto](https://ui.perfetto.dev) to inspect the spans and their metadata.
The summary groups repeated spans and records their durations in integer nanoseconds, together
with Lean heartbeats, validation issues, and process resource counters.

`profileFromEnvironment` runs the action in either mode. Setting `LEAN_PROFILE=1` enables event
recording and report export. Leave the spans in application code and enable them for captures.

The session above produces a root event with two children:

```
indexer.run
├── source.read
└── source.analyze
```

The two child spans separate the time spent in each phase.

# Use an explicit configuration
%%%
tag := "explicit-configuration"
%%%

Environment variables are convenient for commands and CI. A library or long-running application
can pass the same settings directly:

```lean -keep
open LeanProfiler

/-- Record one supplied action with explicit settings. -/
def runProfiled (config : ProfilerConfig)
    (runWork : IO Unit) : IO Unit :=
  profile config "worker" do
    span "work" runWork
```

The main configuration fields are:

:::table +header
*
  * Field
  * Meaning
*
  * `enabled`
  * record spans and export reports
*
  * `tracePath`
  * Trace Event JSON destination
*
  * `summaryPath`
  * strict summary JSON destination
*
  * `eventLimit`
  * maximum retained span count, or no limit
*
  * `processName`
  * process-track label shown by Perfetto
:::

The environment entry point reads these variables:

:::table +header
*
  * Variable
  * Setting
*
  * `LEAN_PROFILE`
  * enable the session unless set to an empty or false-like value
*
  * `LEAN_PROFILE_OUT`
  * trace path
*
  * `LEAN_PROFILE_SUMMARY_OUT`
  * summary path
*
  * `LEAN_PROFILE_MAX_EVENTS`
  * retained event limit
*
  * `LEAN_PROFILE_PROCESS_NAME`
  * Perfetto process label
:::

Keep explicit paths when saving several runs:

```
LEAN_PROFILE=1 \
LEAN_PROFILE_OUT=build/traces/baseline.json \
LEAN_PROFILE_SUMMARY_OUT=build/summaries/baseline.json \
LEAN_PROFILE_PROCESS_NAME="baseline worker" \
lake exe your_executable
```

# Run the checked-in example
%%%
tag := "checked-in-example"
%%%

The repository's nested example simulates three source files with timed delays. Run it from the
repository root:

```
LEAN_PROFILE=1 lake exe leanprofiler_nested_example
```

It records this pair three times:

```
example.source-indexer
├── source.read
└── source.analyze
```

The read and analysis spans sleep for two and four milliseconds respectively. They carry phase,
activity, and module labels to demonstrate grouping. Each event retains its step number, and the
three calls to each phase share one summary row.

Two further examples cover asynchronous completion and scheduled captures.

```
LEAN_PROFILE=1 lake exe leanprofiler_async_example
LEAN_PROFILE=1 lake exe leanprofiler_schedule_example
```

`AsyncCompletion` waits for a task before taking the stop timestamp. `ScheduledSteps` runs skipped
and warmup steps before opening the recorded interval.

# Place work inside the timed action
%%%
tag := "io-timing-boundary"
%%%

`span` starts timing when it runs the supplied `IO` action. Lean evaluates ordinary arguments
before calling a function, so a pure computation used to construct that action may finish before
timing starts. Put the computation inside the action, and consume its result so the compiler
retains the work you intend to measure.

The optional `profiled def` syntax keeps a small `IO` function concise. It has its own import
because defining a command requires Lean's compiler front end:

```
import LeanProfiler.Syntax

open LeanProfiler

profiled def readSource : IO Unit := do
  IO.sleep 2
```

Use an explicit `span` when the same function needs different names or metadata at different call
sites.
