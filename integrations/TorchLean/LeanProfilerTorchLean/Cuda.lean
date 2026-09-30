/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

module

public import LeanProfiler.Runtime.Span
public import NN.Runtime.Autograd.Engine.LibTorch.Buffer
import NN.Runtime.Autograd.Engine.LibTorch.Controls

/-!
# TorchLean CUDA profiling

The adapter makes a host span wait for the current CUDA device and adds TorchLean allocator
snapshots. It remains outside the core profiler so importing `LeanProfiler` does not require CUDA.
-/

namespace LeanProfiler.TorchLean.Cuda

open Runtime.Autograd.LibTorch

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
TorchLean-owned buffers. They are not LibTorch allocator measurements: aliases, workspaces,
reserved blocks, and tensors owned outside TorchLean buffers are not accounted for by these counters.
-/
public def spanHooks : SpanHooks where
  State := Buffer.AllocatorStats
  prepare := do
    Buffer.requireNativeRuntime
    Buffer.allocatorStats
  completeTiming := fun _ => Runtime.Autograd.LibTorch.synchronize
  enrich := fun before metadata => do
    let after ← Buffer.allocatorStats
    pure {
      metadata with
      device := some "cuda"
      timing := some "device-synchronized"
      allocLiveBytes := some after.liveBytes.toNat
      allocPeakBytes := some after.peakBytes.toNat
      allocDeltaBytes := some (byteDelta before.liveBytes after.liveBytes)
    }

end LeanProfiler.TorchLean.Cuda
