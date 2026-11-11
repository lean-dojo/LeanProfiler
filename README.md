# LeanProfiler

LeanProfiler records named `IO` actions in compiled Lean programs. Add spans around the work you
want to measure, then inspect their timing, nesting, threads, metadata and Lean heartbeats in a
timeline or JSON summary. The core package has no external dependencies.

The [guide](https://lean-dojo.github.io/LeanProfiler/) covers instrumentation, asynchronous work,
capture schedules and performance comparisons.

## Getting started

Add LeanProfiler to your project's `lakefile.toml`.

```toml
[[require]]
name = "LeanProfiler"
git = "https://github.com/lean-dojo/LeanProfiler"
rev = "main"
```

Wrap the executable's work in a profiling session, then name the actions to measure. For example,
this `Main.lean` records each file read.

```lean
import LeanProfiler

open LeanProfiler

def main (files : List String) : IO Unit :=
  profileFromEnvironment "readFiles" do
    for file in files do
      let contents ← span "readFile" (IO.FS.readFile file)
      IO.println s!"{file}: {contents.length} characters"
```

Run your executable with profiling enabled.

```sh
LEAN_PROFILE=1 lake exe your_executable Main.lean
```

The session writes `build/leanprofiler-trace.json` and `build/leanprofiler-summary.json`.
Open the trace in [Perfetto](https://ui.perfetto.dev) to inspect individual spans. The summary groups
repeated spans and reports call counts, inclusive and self time, min/mean/median/p95/max, and
heartbeats. It also includes process resource counters and any allocator counters supplied through
hooks.

| Environment variable | Setting |
| --- | --- |
| `LEAN_PROFILE_OUT` | Trace output path |
| `LEAN_PROFILE_SUMMARY_OUT` | Summary output path |
| `LEAN_PROFILE_MAX_EVENTS` | Maximum number of retained events |
| `LEAN_PROFILE_PROCESS_NAME` | Process label in the trace |

With profiling disabled, the instrumented actions run without retaining events or writing reports.
Use `profile config "name" action` to supply a `ProfilerConfig` directly. Spans accept optional
`metadata` and `hooks` arguments.

## Reading a profile

![Nested spans in a LeanProfiler trace](guide/LeanProfilerGuide/Assets/nested-spans-timeline.svg)

Inclusive time covers the whole action. Self time subtracts the union of its immediate child
intervals on the same thread, so overlapping children are counted once. Children on other threads
retain their parent links and their own timing. Await worker tasks before the session ends.
Completion hooks can keep a span open until asynchronous work finishes.

One session owns the process capture buffer at a time. Spans restore their nesting when an action
throws, and the session still attempts to export the capture. The analyzer checks the event
structure before producing the grouped report.

The runtime API, schedules and comparison functions are available through `import LeanProfiler`.
Additional imports provide declaration instrumentation, an embeddable command router and proofs
about the analysis.

```lean
import LeanProfiler.Syntax  -- `profiled def`
import LeanProfiler.CLI     -- comparison command router
import LeanProfiler.Proofs  -- schedule, comparison and timing lemmas
```

## Comparing runs

From a LeanProfiler checkout, compare two summary files with the CLI.

```sh
lake exe leanprofiler compare \
  build/baseline-summary.json \
  build/candidate-summary.json \
  --metric p95_ns \
  --absolute-tolerance 500000 \
  --relative-tolerance-bps 1000 \
  --json build/comparison.json
```

These settings flag an increase in p95 only when it exceeds both 500,000 ns and 10% of the
baseline. New and missing keys are reported separately. The command exits with status 1 when
the comparison fails. It rejects malformed summaries and, by default, captures with dropped events
or validation issues.

## TorchLean integration

The optional integration profiles TorchLean commands and an MLP training workload. Run it from
the integration directory.

```sh
cd integrations/TorchLean
lake build
lake test
LEAN_PROFILE=1 lake exe leanprofiler_torchlean_mlp
```

With a CUDA-enabled LibTorch SDK and an NVIDIA GPU, the command runner synchronizes the selected
device before closing the span and records TorchLean's device-buffer counters.

```sh
LEAN_PROFILE=1 \
lake -R -Kcuda=true exe leanprofiler_torchlean \
  quickstart_mlp --device cuda --arithmetic native --steps 3
```

The elapsed time includes queue delay, device execution and synchronization. Memory counters
measure the logical bytes owned by TorchLean buffer handles. The
[integration README](integrations/TorchLean/README.md) explains SDK setup and how to interpret these
measurements.

## Examples and guide

From a repository checkout, run the examples for nested spans, worker completion, scheduled
capture and a baseline comparison.

```sh
LEAN_PROFILE=1 lake exe leanprofiler_nested_example
LEAN_PROFILE=1 lake exe leanprofiler_async_example
LEAN_PROFILE=1 lake exe leanprofiler_schedule_example
lake exe leanprofiler_regression_example
```

The guide's figures are generated from recorded JSON captures. To build the guide locally,
run the following commands and open `guide/build/guide/html-multi/index.html`.

```sh
cd guide
lake exe leanprofiler-guide-assets
lake exe leanprofiler-guide --output build/guide
```

Run `lake test` and `lake lint` from the repository root to check the core package.

Maintained by the LeanProfiler Team. Released under the [MIT license](LICENSE).
