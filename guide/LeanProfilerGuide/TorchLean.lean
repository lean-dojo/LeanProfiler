/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import VersoManual
import LeanProfiler

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Profile TorchLean" =>
%%%
tag := "torchlean"
%%%

Use LeanProfiler to measure a TorchLean training call, prediction, or model command. Spans can
record the data-loading, forward, backward, and optimizer phases wherever the application exposes
them.

The optional integration package provides a command runner, an MLP training example, and CUDA
completion hooks.

```
cd integrations/TorchLean
lake build
lake test
lake lint
```

The integration's manifest pins TorchLean and inherits its FloatLib revision. It has no independent
FloatLib dependency: `lake update TorchLean` refreshes both. Retain the resolved revisions with a
capture so later comparisons can identify the measured code.

# Import the core API
%%%
tag := "torchlean-core-import"
%%%

If the application already owns its model loop, import only LeanProfiler:

```lean -keep
open LeanProfiler

/-- Record the supplied training phases in one session. -/
def runModel (config : ProfilerConfig)
    (forward backward optimizerStep : IO Unit) : IO Unit :=
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

The outer span measures the whole command. Add spans inside the model loop to measure individual
phases.

# Train and measure the example MLP
%%%
tag := "torchlean-mlp"
%%%

The MLP executable profiles TorchLean's `2 → 8 → 1` quickstart and its 25-sample regression
dataset.

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

The saved Lean 4.35 capture reduced loss from `1.159370` to `0.178789`. Its ten measured predictions
form the distribution below.

[![Ten measured prediction latencies from the TorchLean quickstart MLP](Assets/torchlean-prediction-latency.svg)](Assets/torchlean-prediction-latency.svg)

The [trace](Assets/torchlean-mlp-trace.json),
[summary](Assets/torchlean-mlp-summary.json), and
[capture provenance](Assets/torchlean-mlp-provenance.json) are available beside the figure.
The capture record identifies the toolchain, workload, and local dependency revisions. Use these
timings to inspect this run and its report format.

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

The MLP executable times `Trainer.train`, then measures repeated predictions.

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

`model.train` includes the whole trainer call. Measure its internal phases by placing spans in
the training loop. Prediction spans already surround individual calls, with a step index on each
event and one summary row for the repeated measurements.

The application supplies shape and backend labels. The command runner reads arithmetic and device
flags through TorchLean's parser.

# Interpret CPU spans
%%%
tag := "cpu-spans"
%%%

CPU spans include Lean execution, synchronous foreign calls, and time when the thread is
descheduled. Self time subtracts recorded child intervals on the same thread. Process resource
counters cover the whole session across all threads.

# Interpret CUDA spans
%%%
tag := "cuda-spans"
%%%

Use a CUDA-enabled LibTorch SDK of torch 2.13–2.15, build TorchLean with CUDA, and run a device model:

```
LEAN_PROFILE=1 \
LEAN_PROFILE_OUT=build/mlp-cuda-trace.json \
LEAN_PROFILE_SUMMARY_OUT=build/mlp-cuda-summary.json \
lake -R -K cuda=true exe leanprofiler_torchlean \
  quickstart_mlp --device cuda --arithmetic native --steps 3
```

The integration forwards `cuda=true` and the optional `libtorch_home` setting to TorchLean,
which builds and links its LibTorch adapter.

TorchLean's operators use the LibTorch Stable ABI introduced in torch 2.13. The hook also reads
allocator statistics, whose interface TorchLean checks for torch 2.13–2.15. On another runtime
release, the initial memory read fails before the model runs. Keep the SDK and loaded runtime
versions with a capture; `TorchLean.LibTorch.version` reports the loaded runtime's version.

When the command line contains `--device cuda` or `--device gpu`, the runner uses `Cuda.spanHooks`.
The hook checks TorchLean's native runtime, samples its buffer counters, runs the model, calls
TorchLean's `LibTorch.synchronize`, and samples the counters again:

[![A synchronized LeanProfiler host span around CUDA launches, copies, kernels, and final synchronization](Assets/cuda-timing-boundary.svg)](Assets/cuda-timing-boundary.svg)

The duration includes queue delay, device work, and synchronization overhead. Its trace metadata
sets `timing = device-synchronized`. Check `hook_error` before interpreting the result.

The hook's `alloc_live_bytes`, `alloc_peak_bytes`, and `alloc_delta_bytes` count logical payload
bytes in TorchLean buffer handles. Shared storage can be counted more than once, and native
temporaries can exist without such a handle. `Buffer.Memory.read` exposes additional native
allocator counters, but this hook records buffer ownership.

Perfetto shows the Lean host spans. Use a device profiler to inspect the CUDA kernels, streams,
and memory transfers within a synchronized interval.

Run the integration's CUDA checks with the same build option.

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
