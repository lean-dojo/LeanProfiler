# LeanProfiler for TorchLean

This package profiles TorchLean model commands and an MLP training workload, with CUDA completion
hooks and device-buffer memory counters.

From the repository root, build the integration.

```sh
cd integrations/TorchLean
lake build
lake test
lake lint
```

The manifest pins TorchLean and inherits its FloatLib revision. Update them together with
`lake update TorchLean`; this package has no independent FloatLib dependency.

## Use the core API

Use `LeanProfiler` to name the actions in your training loop.

```lean
import LeanProfiler

open LeanProfiler

def runModel (config : ProfilerConfig)
    (forward backward optimizerStep : IO Unit) : IO Unit :=
  profile config "training" do
    span "model.forward" forward
    span "loss.backward" backward
    span "optimizer.step" optimizerStep
```

To use the command runner or MLP workload, add the integration package.

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

The runner records the selected command as a child of the session span. Add spans in the model
code to measure individual phases.

## Run on CUDA

With a CUDA-enabled LibTorch SDK of torch 2.13–2.15 and an NVIDIA GPU, run the following commands
from `integrations/TorchLean`.

```sh
lake -R -K cuda=true build leanprofiler_torchlean

CUDA_VISIBLE_DEVICES=0 \
LEAN_PROFILE=1 \
LEAN_PROFILE_OUT=build/cuda-mlp-trace.json \
LEAN_PROFILE_SUMMARY_OUT=build/cuda-mlp-summary.json \
lake -R -K cuda=true exe leanprofiler_torchlean \
  quickstart_mlp --device cuda --arithmetic native --steps 3
```

Set `TORCHLEAN_LIBTORCH_HOME` or pass `-K libtorch_home=PATH` to select the SDK.
A CUDA-enabled PyTorch installation can supply it.

TorchLean's native operators use the LibTorch Stable ABI introduced in torch 2.13. The profiling
hook also reads allocator statistics, whose interface TorchLean checks for torch 2.13–2.15.
Another runtime release causes the hook's initial memory read to fail before the command runs.
Retain the SDK version and loaded runtime version with a capture; `TorchLean.LibTorch.version`
reports the latter.

An explicit `--device cuda` or `--device gpu` selects `LeanProfiler.TorchLean.Cuda.spanHooks`.
The hook samples the device-buffer counters, runs the command, synchronizes the selected device,
and records live bytes, peak bytes and the signed live-byte change.

The memory fields count logical payload bytes owned by TorchLean buffer handles. Shared storage
can be counted more than once. `Buffer.Memory.read` also exposes LibTorch's allocated and
reserved CUDA memory counters, including its cache.

Run TorchLean's focused CUDA regression suite through the integration:

```sh
CUDA_VISIBLE_DEVICES=0 \
lake -R -K cuda=true exe leanprofiler_torchlean_cuda_tests
```

Run the executable under Compute Sanitizer to check native memory accesses.

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

## Timing

CPU spans report monotonic host time. Self time subtracts the union of recorded child intervals
on the same thread. Session resource counters cover the whole process.

CUDA command spans include queue delay, device execution and synchronization overhead. These
are host intervals around the selected command.

The [TorchLean guide](../../guide/LeanProfilerGuide/TorchLean.lean) covers model metadata,
training-loop spans and interpreting CPU and CUDA profiles.
