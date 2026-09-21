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
lake exe leanprofiler_torchlean mlp --device cpu
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

The integration forwards `cuda_home` and `cuda_arch` to TorchLean. For an A100-only build,
add `-K cuda_arch=sm_80` to the build and run commands. This is also needed with CUDA 11,
whose compiler does not accept the default `all-major` target. The toolkit selected by
`cuda_home` supplies both the headers and linked libraries.

An explicit `--device cuda` selects `LeanProfiler.TorchLean.Cuda.spanHooks`. Before the model runs,
the hook rejects TorchLean's CPU parity stubs and samples the device-buffer allocator. It calls
`cudaDeviceSynchronize` before the stop timestamp, then records live bytes, peak bytes, and the
signed live-byte change.

One three-step quickstart run produced this trace metadata:

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

Those numbers are TorchLean buffer counters. They do not include allocations owned only by cuBLAS,
cuFFT, another process, or a different allocator.

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

`WorkloadConfig` controls the seed, optimizer-update count, batch size, warmup count, and measured
prediction count.

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
