# LeanProfiler

Application-level runtime profiling for compiled Lean programs.

The core package, TorchLean integration, and guide use Lean 4.34.0.

## Why it exists

LeanProfiler grew out of an awkward gap in Lean's performance tooling. Lean already has good tools
for finding an expensive declaration or tactic, but their job is largely over by the time `main`
begins. A compiled program may then spend its time reading files, exploring a search tree, serving
requests, waiting for workers, running numerical code, or crossing into another runtime.

Imagine a source indexer that used to finish in ten seconds and now takes thirty. A stopwatch proves
that it regressed. A system profiler can identify hot native functions. Neither result answers the
question the programmer is likely to ask first: did discovery, parsing, analysis, or writing become
slower? LeanProfiler lets the program name those phases directly, then records their order,
nesting, thread, metadata, elapsed time, and Lean heartbeats.

The core package is for any compiled Lean application. TorchLean is a useful stress case, but it is
an optional integration rather than a dependency of the profiler.

Use the tool that matches the question:

| Question | Tool |
| --- | --- |
| Why is a Lean file slow to elaborate or compile? | Lean's `--profile`, [component profiler](https://lean-lang.org/doc/api/Lean/Util/Profile.html), and [trace profiler](https://lean-lang.org/doc/api/Lean/Util/Trace.html) |
| Which phase of a running Lean executable is slow? | LeanProfiler |
| Which PyTorch operator or supported device kernel is expensive? | [PyTorch Profiler](https://docs.pytorch.org/docs/stable/profiler.html), inside an outer LeanProfiler span when Lean owns the application |
| Which native function is expensive? | A system or runtime profiler, with LeanProfiler retaining the application context |

## From one span to a report

The common case is small:

```lean
profileFromEnvironment "indexer.run" do
  let source ← span "source.read" readSource
  span "source.analyze" (analyzeSource source)
```

When profiling is enabled, `profileFromEnvironment` claims the process-wide capture buffer and
opens the root event. Each `span` then follows the same path:

1. reserve an event index under a mutex and read the current thread's parent stack;
2. sample the monotonic clock and the thread's Lean heartbeat counter;
3. run the action, including any completion hook needed for asynchronous work;
4. take the ending samples and store the completed event;
5. restore the stack even when the action throws.

At the end of the session, the analyzer validates the event forest. It computes inclusive time
from the recorded interval and self time by subtracting the covered union of immediate,
same-thread children. Cross-thread children stay linked in the trace but are not subtracted from
another thread's clock. Repeated events are grouped by their structured key, and the report keeps
call counts, total and self time, min/mean/median/p95/max, heartbeats, and supplied allocator
counters.

Each capture produces:

- a Trace Event file that opens in [Perfetto](https://ui.perfetto.dev);
- a strict JSON summary with integer-nanosecond timings, grouped rows, heartbeats, and process
  counters.

The trace answers "what happened, and in what order?" The summary answers "which repeated phase
changed?" It is a strict, versioned input for baseline-to-candidate comparisons in scripts or CI.

LeanProfiler does not discover functions, operators, or kernels automatically. The application
chooses its spans. That is the reason the output can retain names such as `source.analyze`,
`solver.expand`, or `training.step` even when the implementation crosses several libraries.

![A LeanProfiler investigation from a performance question to a diagnosis or regression gate](guide/LeanProfilerGuide/Assets/profiling-workflow.svg)

## Add it to a project

```toml
[[require]]
name = "LeanProfiler"
git = "https://github.com/lean-dojo/LeanProfiler"
rev = "main"
```

Wrap the work you want to measure:

```lean
import LeanProfiler

open LeanProfiler

def readSource : IO String := do
  IO.sleep 2
  pure "def answer := 42"

def analyzeSource (source : String) : IO Nat := do
  IO.sleep 4
  pure source.length

def main : IO Unit :=
  profileFromEnvironment "indexer.run" do
    let source ← span "source.read" readSource
    let declarations ← span "source.analyze" (analyzeSource source) (metadata := {
      phase := some "analysis"
      moduleName := some "indexer"
    })
    IO.println s!"indexed {declarations} characters"
```

Run it with profiling enabled:

```sh
LEAN_PROFILE=1 lake exe your_executable
```

The default files are:

```text
build/leanprofiler-trace.json
build/leanprofiler-summary.json
```

Use `LEAN_PROFILE_OUT` and `LEAN_PROFILE_SUMMARY_OUT` to keep several runs.
`LEAN_PROFILE_MAX_EVENTS` bounds long captures, and `LEAN_PROFILE_PROCESS_NAME` changes the process
label shown in Perfetto.

Without `LEAN_PROFILE=1`, the same action runs without retaining spans or writing reports.

The umbrella import contains the runtime API, report writers, schedules, and summary comparison.
Three narrower features use explicit imports:

```lean
import LeanProfiler.Syntax  -- `profiled def`
import LeanProfiler.CLI     -- embeddable command router
import LeanProfiler.Proofs  -- laws about schedules, comparisons, and timing analysis
```

Most applications need only `import LeanProfiler`. Keeping the command syntax separate avoids
loading Lean's compiler front end into an ordinary runtime executable.

## Try the examples

The examples are small enough to read before running them:

- `leanprofiler_nested_example` records a source-indexing loop with nested phase and module context.
- `leanprofiler_async_example` waits for a worker task before closing the measured interval.
- `leanprofiler_schedule_example` records only the active part of a longer stepped workload.
- `leanprofiler_regression_example` captures a baseline and a deliberately slower candidate, then
  checks their p95 summaries.

Enable capture for the first three with `LEAN_PROFILE=1`. The regression walkthrough supplies its
own output paths and profiling configuration, so it runs directly:

```sh
LEAN_PROFILE=1 lake exe leanprofiler_nested_example
LEAN_PROFILE=1 lake exe leanprofiler_async_example
LEAN_PROFILE=1 lake exe leanprofiler_schedule_example
lake exe leanprofiler_regression_example
```

## What the output looks like

![A nested timeline with one root span and alternating source.read and source.analyze child spans](guide/LeanProfilerGuide/Assets/nested-spans-timeline.svg)

The timeline shows the order, duration, and nesting of every recorded span.

![A paired-dot plot comparing baseline and candidate p95 values for three rows](guide/LeanProfilerGuide/Assets/p95-comparison.svg)

The comparison plot makes changed p95 timings visible before you inspect the JSON report.

## Compare summaries

```sh
lake exe leanprofiler compare \
  build/baseline-summary.json \
  build/candidate-summary.json \
  --metric p95_ns \
  --absolute-tolerance 500000 \
  --relative-tolerance-bps 1000 \
  --json build/comparison.json
```

A candidate increase is a regression only when it exceeds both tolerances. New and missing keys
are reported separately. Invalid or incomplete summaries are rejected unless the caller requests a
diagnostic comparison.

## Optional TorchLean integration

TorchLean is one application of the general API. TorchLean programs can import the core package
directly, while a separate package provides a command runner, CUDA hooks, and an MLP walkthrough:

```sh
cd integrations/TorchLean
lake build
lake test
LEAN_PROFILE=1 lake exe leanprofiler_torchlean_mlp
```

The runner also has a CUDA adapter. It rejects CPU parity stubs, waits for the selected device
before closing the command span, and records TorchLean device-buffer counters:

```sh
LEAN_PROFILE=1 \
lake -R -K cuda=true exe leanprofiler_torchlean \
  quickstart_mlp --device cuda --steps 3
```

See [the integration README](integrations/TorchLean/README.md).

## Guide

The [published Verso guide](https://lean-dojo.github.io/LeanProfiler/) follows one real slowdown
investigation from instrumentation through its timeline, summary, diagnosis, and regression check.
It also explains sessions, hooks, repeated capture schedules, Lean's elaboration profilers,
PyTorch Profiler, and TorchLean on CPU and CUDA.

Build it locally:

```sh
cd guide
lake exe leanprofiler-guide-assets
lake exe leanprofiler-guide --output build/guide
```

The rendered site is under `guide/build/guide/html-multi`.

The checked-in JSON captures are real observations. The SVG figures are regenerated from those
artifacts by Lean code.

## Tests

```sh
lake test
lake lint
```

The TorchLean package has its own test driver under `integrations/TorchLean`.

## Team and license

Maintained by the LeanProfiler Team. Released under the [MIT license](LICENSE).
