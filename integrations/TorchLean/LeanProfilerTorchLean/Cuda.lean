/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

module

public import LeanProfiler.Runtime.Span
public import TorchLean.CUDA.LibTorch.Buffer

/-!
# TorchLean CUDA profiling

The adapter makes a host span wait for the current CUDA device and adds TorchLean allocator
snapshots. It remains outside the core profiler so importing `LeanProfiler` does not require CUDA.
-/

namespace LeanProfiler.TorchLean.Cuda

open _root_.TorchLean.LibTorch

/-- Signed difference between two monotonically sampled unsigned byte counters. -/
def byteDelta (before after : UInt64) : Int :=
  if before ≤ after then
    Int.ofNat (after - before).toNat
  else
    -Int.ofNat (before - after).toNat

/--
Synchronize CUDA at the end of a span and attach TorchLean allocator counters.

The recorded host duration includes outstanding queue time and the synchronization itself.
`allocLiveBytes`, `allocPeakBytes`, and `allocDeltaBytes` count logical payload bytes in
TorchLean buffer handles, so shared storage can be counted more than once. They are not LibTorch
allocator measurements: native temporaries, workspaces and reserved blocks need not have a
TorchLean handle. `Buffer.Memory.read` also exposes native allocator counters.
-/
public def spanHooks : SpanHooks where
  State := Buffer.Memory
  prepare := do
    Buffer.requireNativeRuntime
    Buffer.Memory.read
  completeTiming := fun _ => _root_.TorchLean.LibTorch.synchronize
  enrich := fun before metadata => do
    let after ← Buffer.Memory.read
    pure {
      metadata with
      device := some "cuda"
      timing := some "device-synchronized"
      allocLiveBytes := some after.liveBytes.toNat
      allocPeakBytes := some after.peakBytes.toNat
      allocDeltaBytes := some (byteDelta before.liveBytes after.liveBytes)
    }

end LeanProfiler.TorchLean.Cuda
