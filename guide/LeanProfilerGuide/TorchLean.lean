/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import VersoManual

open Verso.Genre Manual

#doc (Manual) "Profile TorchLean" =>
%%%
tag := "torchlean"
%%%

A TorchLean run crosses several boundaries before a single kernel becomes interesting: data enters
the program, the model runs, gradients are computed, parameters change, and device work completes.
LeanProfiler records those application-level intervals without changing TorchLean's tensor or
proof APIs.

A TorchLean application may depend only on the core LeanProfiler package. This repository also
contains an optional integration package with a command runner, a real MLP training workload, and
CUDA completion hooks:

```
cd integrations/TorchLean
lake build
lake test
lake lint
```

The nested package follows TorchLean's `main` branch in its Lake configuration. Its checked-in
manifest pins the resolved revision until `lake update TorchLean` is run, so a saved profile can
name the code it measured.

# Import the core API
%%%
tag := "torchlean-core-import"
%%%

If the application already owns its model loop, import only LeanProfiler:

```
import LeanProfiler

open LeanProfiler

def runModel (config : ProfilerConfig) : IO Unit :=
  profile config "training" do
    span "model.forward" forward
    span "loss.backward" backward
    span "optimizer.step" optimizerStep
```

Use the integration package to reuse its runner, MLP workload, or CUDA hooks:

```
[[require]]
name = "LeanProfilerTorchLean"
git = "https://github.com/lean-dojo/LeanProfiler"
rev = "main"
subDir = "integrations/TorchLean"
```

Then import `LeanProfilerTorchLean` or one of its focused modules.

# Run a model command
%%%
tag := "torchlean-command"
%%%

Arguments after the executable name go to TorchLean's model runner:

```
LEAN_PROFILE=1 \
LEAN_PROFILE_OUT=build/traces/mlp-cpu.json \
LEAN_PROFILE_SUMMARY_OUT=build/summaries/mlp-cpu.json \
LEAN_PROFILE_PROCESS_NAME="TorchLean MLP CPU" \
lake exe leanprofiler_torchlean quickstart_mlp --device cpu
```

The outer event tree is:

```
main
└── torchlean.quickstart_mlp
```

That span measures the host path through the command. It does not invent layer, graph-node, tensor
operation, kernel, loader-worker, or optimizer events. Add narrower spans only where the running
program knows the corresponding boundary.

# Train and measure the example MLP
%%%
tag := "torchlean-mlp"
%%%

The second executable profiles TorchLean's `2 → 8 → 1` quickstart MLP and its 25-sample regression
dataset:

```
LEAN_PROFILE=1 \
LEAN_PROFILE_OUT=build/mlp-training-trace.json \
LEAN_PROFILE_SUMMARY_OUT=build/mlp-training-summary.json \
lake exe leanprofiler_torchlean_mlp
```

The default workload measures 20 optimizer updates and ten predictions after one warmup
prediction:

```
torchlean.mlp-training
├── model.train
└── model.predict × 10
```

`model.train` records the training phase, tensor IR backend, Float32 arithmetic, CPU device,
model, and tensor shapes. Prediction spans carry step numbers while sharing one grouped row.

The Lean 4.35 capture reached a loss of `0.178789`, down from `1.159370`. Ten post-warmup
prediction spans form the distribution below:

![Ten measured prediction latencies from the TorchLean quickstart MLP](../../Assets/torchlean-prediction-latency.svg)

The [trace](../../Assets/torchlean-mlp-trace.json),
[summary](../../Assets/torchlean-mlp-summary.json), and
[capture provenance](../../Assets/torchlean-mlp-provenance.json) are available beside the figure.
These files show the exact artifact format. They are not a portable TorchLean benchmark: latency
depends on the machine, build, runtime state, and resolved TorchLean revision.

Another executable can reuse the workload:

```
import LeanProfilerTorchLean.MlpTraining

def main : IO Unit :=
  LeanProfiler.TorchLean.MlpTraining.run {
    enabled := true
    tracePath := "build/custom-mlp-trace.json"
    summaryPath := "build/custom-mlp-summary.json"
  } {
    seed := 7
    steps := 100
    samplesPerStep := 5
    warmupRuns := 2
    predictionRuns := 50
  }
```

The model has 33 trainable scalars:

$$`8\cdot2+8+1\cdot8+1=33`

# Instrument a TorchLean trainer
%%%
tag := "training-boundary"
%%%

The MLP executable profiles the real `Trainer.train` call and then measures a distribution of
predictions. Its central block is:

```
profile config "torchlean.mlp-training" do
  let trained ← span "model.train"
    (trainer.train data {
      steps := workload.steps
      samplesPerStep := workload.samplesPerStep
      logEvery := 0
    })
    (metadata := {
      modelMetadata with
      phase := some "training"
      activity := some "training run"
    })

  for iteration in List.range workload.predictionRuns do
    withStep iteration do
      span "model.predict" (trained.predict heldout) (metadata := {
        modelMetadata with
        phase := some "inference"
        activity := some "held-out prediction"
      })
```

`model.train` measures the whole trainer call. It cannot split batches, forward evaluation,
backward evaluation, and optimizer updates from outside that call. If the trace points into
training, place narrower spans in the training loop that owns those phases. Prediction is different:
the caller owns every repeated call, so each one can carry a step index while all calls share one
summary row.

The application supplies shape and backend labels; the command runner reads arithmetic and device
flags through TorchLean's parser.
LeanProfiler itself does not inspect tensor values, which keeps its core usable by any Lean
application.

# Interpret CPU spans
%%%
tag := "cpu-spans"
%%%

On CPU, a span reports monotonic host elapsed time. It includes Lean execution, blocking foreign
calls, and time when the thread is descheduled. Self time removes recorded same-thread child
intervals. It does not remove uninstrumented callees, runtime overhead, or another thread's work.

Session resource counters cover all process threads and foreign runtime activity. They are useful
context for the capture, not layer-level attribution.

# Interpret CUDA spans
%%%
tag := "cuda-spans"
%%%

Build TorchLean with CUDA and run a device model:

```
LEAN_PROFILE=1 \
LEAN_PROFILE_OUT=build/mlp-cuda-trace.json \
LEAN_PROFILE_SUMMARY_OUT=build/mlp-cuda-summary.json \
lake -R -K cuda=true exe leanprofiler_torchlean \
  quickstart_mlp --device cuda --arithmetic native --steps 3
```

The integration forwards `cuda=true` and the optional `libtorch_home` setting to TorchLean.
TorchLean builds and links the LibTorch adapter; the profiler needs no separate CUDA bridge.
Without option forwarding, Lake would leave the dependency on its unavailable-backend shim even
though the workspace root received `-K cuda=true`.

When the command line contains `--device cuda` or `--device gpu`, the runner uses `Cuda.spanHooks`.
The hook checks TorchLean's native runtime, samples its buffer counters, runs the model, calls
TorchLean's `LibTorch.synchronize`, and samples the counters again:

![A synchronized LeanProfiler host span around CUDA launches, copies, kernels, and final synchronization](../../Assets/cuda-timing-boundary.svg)

The duration is a synchronized host boundary. It includes queue delay, device work, and
synchronization overhead; it is not the sum of kernel execution times. In the trace, look for
`timing = device-synchronized` and check `hook_error` before using a span as a device measurement.
The `alloc_live_bytes`, `alloc_peak_bytes`, and `alloc_delta_bytes` fields count logical payload
bytes owned by TorchLean buffer handles, not LibTorch's allocated or reserved memory. Shared
storage can be counted more than once, and native temporaries need not have a TorchLean handle.
TorchLean's `Buffer.memory` exposes native allocator counters separately; these fields record
buffer ownership.
LeanProfiler does not read CUDA events, CUPTI activity, stream IDs,
memcopy events, or per-kernel allocations, so Perfetto still shows Lean host threads. Use a native
device profiler when the synchronized boundary points to CUDA and the next question is which kernel
or transfer is responsible.

Run TorchLean's CUDA kernel and allocator checks without the unrelated Python and dataset suites:

```
CUDA_VISIBLE_DEVICES=0 \
lake -R -K cuda=true exe leanprofiler_torchlean_cuda_tests
```

# Compare like with like
%%%
tag := "torchlean-comparisons"
%%%

Before attributing a change to TorchLean:

- retain the resolved TorchLean revision;
- use the same toolchain, build options, model arguments, seed, backend profile, arithmetic, and
  device;
- warm up device libraries and any custom kernels before active samples;
- collect several process runs;
- keep device completion policy identical.

The trace is the place to diagnose order and nesting. The summary is the input to an automated
comparison.
