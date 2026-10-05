# LeanProfiler for TorchLean

This optional package adds two TorchLean workloads without making TorchLean or Mathlib dependencies
of the core profiler.

Commands below run from this directory:

```sh
cd integrations/TorchLean
lake build
lake test
lake lint
```

The Lake manifest records the resolved TorchLean revision. Run `lake update TorchLean` when you
intend to move that pin.

This integration now follows TorchLean's tensor API and LibTorch runtime at `13d02834`.
The core profiler still has no TorchLean dependency; projects can add spans without importing
the model workloads or GPU hooks.

## Use the core API

A TorchLean project can instrument its own model loop with the root package:

```lean
import LeanProfiler

open LeanProfiler

def runModel (config : ProfilerConfig) : IO Unit :=
  profile config "training" do
    span "model.forward" forward
    span "loss.backward" backward
    span "optimizer.step" optimizerStep
```

No integration import is needed for ordinary spans.

To reuse the runner or MLP workload, require this subdirectory:

```toml
[[require]]
name = "LeanProfilerTorchLean"
git = "https://github.com/lean-dojo/LeanProfiler"
rev = "main"
subDir = "integrations/TorchLean"
```

Then import `LeanProfilerTorchLean` or one of its focused modules.

## Run a TorchLean command

Arguments after the executable name go to TorchLean's model runner:

```sh
LEAN_PROFILE=1 \
LEAN_PROFILE_OUT=build/traces/mlp-cpu.json \
LEAN_PROFILE_SUMMARY_OUT=build/summaries/mlp-cpu.json \
lake exe leanprofiler_torchlean quickstart_mlp --device cpu --steps 3
```

The runner records the selected command as a child of the session span. Layers, graph nodes,
tensor operations, loader workers, kernels, and optimizer steps need spans in their own code paths.

## Run on CUDA

Build from this directory so the integration can forward `cuda=true` to TorchLean:

```sh
lake -R -K cuda=true build leanprofiler_torchlean

CUDA_VISIBLE_DEVICES=0 \
LEAN_PROFILE=1 \
LEAN_PROFILE_OUT=build/cuda-mlp-trace.json \
LEAN_PROFILE_SUMMARY_OUT=build/cuda-mlp-summary.json \
lake -R -K cuda=true exe leanprofiler_torchlean \
  quickstart_mlp --device cuda --execution eager --arithmetic native --steps 3
```

The integration uses TorchLean's LibTorch backend. Set `TORCHLEAN_LIBTORCH_HOME` or pass
`-K libtorch_home=PATH` to select the SDK; a CUDA-enabled PyTorch installation can supply it.
TorchLean's native build handles SDK compilation and linking. The profiler no longer builds
its own CUDA synchronization bridge or links cuBLAS and cuFFT separately.

An explicit `--device cuda` or `--device gpu` selects `LeanProfiler.TorchLean.Cuda.spanHooks`.
Before the model runs, the hook requires a working LibTorch CUDA backend and samples the
device-buffer counters. It calls TorchLean's `LibTorch.synchronize` before the stop timestamp,
then records live bytes, peak bytes, and the signed live-byte change.

An earlier three-step quickstart run, using the previous native backend, produced this metadata:

```json
{
  "device": "cuda",
  "timing": "device-synchronized",
  "alloc_live_bytes": 0,
  "alloc_peak_bytes": 1596,
  "alloc_delta_bytes": 0,
  "hook_error": null
}
```

These fields still count logical payload bytes owned by TorchLean buffers. They are not LibTorch's
allocated or reserved memory, and they do not account for shared-storage aliasing, library
workspaces, cached blocks, or another process. The historical numbers above are not a LibTorch
memory baseline.

Run TorchLean's focused CUDA regression suite through the integration:

```sh
CUDA_VISIBLE_DEVICES=0 \
lake -R -K cuda=true exe leanprofiler_torchlean_cuda_tests
```

For native memory checking, build once and put the executable under Compute Sanitizer:

```sh
lake -R -K cuda=true build leanprofiler_torchlean
CUDA_VISIBLE_DEVICES=0 \
compute-sanitizer --tool memcheck --leak-check full --error-exitcode 99 \
  .lake/build/bin/leanprofiler_torchlean \
  quickstart_mlp --device cuda --steps 1
```

## Run the MLP walkthrough

```sh
LEAN_PROFILE=1 \
LEAN_PROFILE_OUT=build/mlp-training-trace.json \
LEAN_PROFILE_SUMMARY_OUT=build/mlp-training-summary.json \
lake exe leanprofiler_torchlean_mlp
```

The default workload profiles TorchLean's `2 → 8 → 1` quickstart MLP:

```text
torchlean.mlp-training
├── model.train
└── model.predict × 10
```

`WorkloadConfig` controls the seed, optimizer-update count, samples per update, warmup count,
and measured prediction count.

## Read the timing correctly

CPU spans report monotonic host time. Self time removes recorded same-thread child intervals.
Session resource counters cover the whole process.

CUDA launches are asynchronous. A normal command span may measure host submission rather than
device completion. The integration's CUDA hook synchronizes before the stop timestamp, so its host
duration includes queue delay, device work, and synchronization overhead. It samples TorchLean's
device-buffer allocator, but it does not collect individual kernel timestamps, CUPTI activity,
stream IDs, memcopy events, or per-kernel allocations.

The [TorchLean guide chapter](../../guide/LeanProfilerGuide/TorchLean.lean) covers model metadata,
training-loop spans, CPU/CUDA interpretation, and comparison discipline.
