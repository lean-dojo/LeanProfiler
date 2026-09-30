/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

module

import NN.Tests.Runtime.Cuda.Suite

/-!
# TorchLean CUDA test executable

Runs TorchLean's focused CUDA kernel, autograd, numerical-parity, shape, ownership, and allocator
checks without first running unrelated dataset or Python interoperability suites.
-/

/--
Run the CUDA coverage suite selected by the current TorchLean native build.

Allocator tests re-execute this binary in fresh processes. Each child must run only its selected
probe; entering the full suite again would recursively fork more children.
-/
public def main : IO Unit := do
  match ← IO.getEnv "TORCHLEAN_LIBTORCH_MEMORY_PROBE" with
  | some "accounting" => Tests.Cuda.Stress.runMemoryAccountingProbe
  | some "attention-buffers" => Tests.Cuda.Stress.runAttentionMemoryProbe
  | some "oom-recovery" => Tests.Cuda.Stress.runMemoryOOMProbe
  | some other => throw <| IO.userError s!"unknown LibTorch memory probe: {other}"
  | none => Tests.Cuda.run
