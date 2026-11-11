/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import VersoManual

open Verso.Genre Manual

#doc (Manual) "Choose the right profiler" =>
%%%
tag := "profiler-comparison"
%%%

Choose a profiler for the code you need to measure. Lean's built-in tools profile elaboration and
compilation. LeanProfiler records named phases in the running program. PyTorch Profiler and device
tools provide detail inside framework calls and kernels.

[![The observation boundaries of Lean profiling tools, LeanProfiler, and a foreign runtime profiler](Assets/profiler-scope.svg)](Assets/profiler-scope.svg)

# Before `main`: Lean's profilers
%%%
tag := "lean-elaboration-profilers"
%%%

Use Lean's command-line profile when a declaration makes a file slow to build:

```
lake env lean --profile MyProject/SlowModule.lean
```

It reports elaboration and type-checking time by declaration.

Lean's [`profiler` option](https://lean-lang.org/doc/api/Lean/Util/Profile.html) accumulates
exclusive time inside instrumented elaborator and compiler components:

```
lake env lean \
  -Dprofiler=true \
  -Dprofiler.threshold=10 \
  MyProject/SlowModule.lean
```

The threshold is in milliseconds. The default is 100 milliseconds.

[`trace.profiler`](https://lean-lang.org/doc/api/Lean/Util/Trace.html) times Lean's nested trace
tree and can export a Firefox-Profiler-compatible file:

```
lake env lean \
  -Dtrace.profiler=true \
  -Dtrace.profiler.threshold=5 \
  -Dtrace.profiler.output=build/elaboration-profile.json \
  MyProject/SlowModule.lean
```

With `-Dtrace.profiler.useHeartbeats=true`, its measurement and threshold use heartbeats.
`trace.profiler.serve` starts an ephemeral loopback server and opens Firefox Profiler. The server
shuts down after the profile is fetched.

For a single action, `IO.timeit` prints elapsed time. `IO.allocprof` invokes Lean's runtime
allocation-profiler hook.

# After `main`: LeanProfiler
%%%
tag := "runtime-measurement-sources"
%%%

LeanProfiler uses the application's span names and nesting.

```
profileFromEnvironment "indexer.run" do
  for (sourcePath, fileIndex) in sourcePaths.zipIdx do
    withStep fileIndex do
      let contents ← span "source.read" (readSource sourcePath)
      let syntax ← span "source.parse" (parseSource contents)
      span "source.analyze" (analyzeSource syntax)
```

The runtime supplies monotonic timestamps, thread and process IDs, Lean heartbeats, and process
resource counters. Device measurements require an adapter. A synchronization hook can wait for
completion before closing a span.

# Inside PyTorch: PyTorch Profiler
%%%
tag := "pytorch-comparison"
%%%

PyTorch Profiler records framework operators and supported device activity. This example schedules
three active training steps after waiting and warmup, then exports a trace.

```
import torch
from torch.profiler import ProfilerActivity, profile, record_function

activities = [ProfilerActivity.CPU]
if torch.cuda.is_available():
    activities.append(ProfilerActivity.CUDA)

def save_trace(prof):
    print(prof.key_averages().table(
        sort_by="self_cpu_time_total",
        row_limit=20,
    ))
    prof.export_chrome_trace(f"trace-{prof.step_num}.json")

with profile(
    activities=activities,
    schedule=torch.profiler.schedule(
        wait=1, warmup=1, active=3, repeat=1
    ),
    on_trace_ready=save_trace,
    record_shapes=True,
    profile_memory=True,
    with_stack=True,
) as prof:
    for batch in loader:
        with record_function("training.step"):
            loss = model(batch)
            loss.backward()
            optimizer.step()
            optimizer.zero_grad()
        prof.step()
```

The trace includes `training.step` and framework operations inside it. CUDA activity uses CUPTI
where available. Call `torch.profiler.supported_activities()` to check the installed build.
Shape recording, memory profiling, stack collection, and FLOP estimates add overhead. Enable the
detail you need for the measurement.

# Similar controls, different observations
%%%
tag := "profiler-capability-table"
%%%

Both provide named ranges, capture schedules, aggregates, and trace export.

:::table +header
*
  * Capability
  * LeanProfiler
  * PyTorch profiler
*
  * Primary boundary
  * running Lean application
  * PyTorch framework and supported device runtime
*
  * User-defined range
  * `span`; `profiled def` with `LeanProfiler.Syntax`
  * `record_function`
*
  * Capture boundary
  * `profile` or `profileFromEnvironment`
  * `torch.profiler.profile`
*
  * Long-run schedule
  * skip, warmup, record, record-and-save
  * `NONE`, `WARMUP`, `RECORD`, `RECORD_AND_SAVE`, advanced by `step()`
*
  * Automatic operation events
  * none
  * PyTorch operators and selected runtime activity
*
  * Accelerator timing
  * host timing; an adapter may synchronize the device
  * supported device activities, including CUDA kernels when CUPTI is available
*
  * Shapes
  * application-supplied metadata
  * optional operator input shapes
*
  * Memory
  * process resources; allocator adapters may supply span counters
  * optional tensor allocation, release, and memory timeline data
*
  * Stacks and FLOPs
  * not collected automatically
  * optional source stacks and estimates for selected operators
*
  * Aggregation
  * structured key plus min, mean, median, p95, max, self, and total
  * `key_averages`, optionally grouped by shape, stack, or overload
*
  * Lean-specific signal
  * heartbeats
  * none
*
  * Trace export
  * Trace Event JSON for Perfetto
  * Chrome Trace JSON; TensorBoard trace handler is also available
*
  * Built-in regression input
  * strict versioned summary and built-in comparison
  * the user or surrounding tooling defines the gate
:::

# Read the timing columns carefully
%%%
tag := "timing-semantics-comparison"
%%%

LeanProfiler reports elapsed host time. Self time subtracts immediate same-thread child coverage.
A CUDA synchronization hook includes the wait for device completion in the host interval.

PyTorch tables separate CPU and supported device measurements. A user range can have CPU total,
CPU self, and device-related columns derived from events correlated below it. Sorting by
`self_cpu_time_total` answers a different question from sorting by `self_cuda_time_total`.

Keep the workload, warmup, and synchronization policy fixed when comparing the same timing
columns. Concurrent threads and streams can overlap, so totals do not directly measure hardware
utilization.

LeanProfiler's `runScheduledCycle` opens a session around the active steps. PyTorch's `step()`
advances its profiler through the schedule inside the loop.

# Use both around a foreign boundary
%%%
tag := "foreign-runtime-boundary"
%%%

Place a LeanProfiler span around the foreign call to locate it within the application's phases.
Use a profiler inside that runtime to inspect its operators and device activity. To correlate the
two captures, the adapter must supply a shared identifier or a mapping between their timestamps.

# Start with the symptom
%%%
tag := "profiler-choice"
%%%

:::table +header
*
  * Symptom
  * First tool
  * Why
*
  * one Lean declaration is slow to build
  * `lean --profile` or `trace.profiler`
  * the cost occurs during elaboration or compilation
*
  * a running Lean command has a slow phase
  * LeanProfiler
  * the application owns the meaningful phase names
*
  * a PyTorch operator dominates CPU time
  * PyTorch Profiler
  * operators are discovered and grouped automatically
*
  * a CUDA model waits unexpectedly
  * LeanProfiler boundary plus PyTorch/CUPTI or Nsight detail
  * one view locates the application call; the other resolves kernels and runtime activity
*
  * a candidate build regressed
  * LeanProfiler comparison over repeated controlled captures
  * the summary schema and threshold policy are explicit
:::

# References
%%%
tag := "profiler-references"
%%%

- Lean,
  [`Lean.Util.Profile` API](https://lean-lang.org/doc/api/Lean/Util/Profile.html).
- Lean,
  [`Lean.Util.Trace` API](https://lean-lang.org/doc/api/Lean/Util/Trace.html).
- Lean,
  [`Lean.Util.Profiler` API](https://lean-lang.org/doc/api/Lean/Util/Profiler.html).
- Lean,
  [`Init.System.IO` API](https://lean-lang.org/doc/api/Init/System/IO.html).
- Lean,
  [Lean 4.31 profiler release note](https://lean-lang.org/doc/reference/latest/releases/v4.31.0/).
- PyTorch,
  [`torch.profiler` reference](https://docs.pytorch.org/docs/stable/profiler.html).
- PyTorch,
  [profiler recipe](https://docs.pytorch.org/tutorials/recipes/recipes/profiler_recipe.html).
- PyTorch,
  [profiling a module](https://docs.pytorch.org/tutorials/beginner/profiler.html).
- Perfetto,
  [Trace Event format](https://perfetto.dev/docs/getting-started/other-formats).
