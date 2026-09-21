/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

module

import LeanProfiler
import LeanProfilerTorchLean.CommandMetadata
import LeanProfilerTorchLean.Cuda
import NN.Examples.Runner

/-!
# TorchLean runner

Wraps TorchLean's model dispatcher in a top-level span.
-/

namespace LeanProfiler.TorchLean

/-- Run the TorchLean model dispatcher with profiling controlled by `LEAN_PROFILE`. -/
public def run (args : List String) : IO UInt32 := do
  let commandLabel :=
    match NN.Examples.Runner.splitCommandArgs? args with
    | some (_, command, _) => s!"torchlean.{command}"
    | none => "torchlean.command"
  let metadata := CommandMetadata.fromArguments args
  let hooks :=
    if CommandMetadata.usesCuda args then
      Cuda.spanHooks
    else
      SpanHooks.none
  LeanProfiler.profileFromEnvironment "main" do
    LeanProfiler.span commandLabel (NN.Examples.Runner.main args)
      (metadata := metadata) (hooks := hooks)

end LeanProfiler.TorchLean
