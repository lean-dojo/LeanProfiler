/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

module

import LeanProfilerTorchLean.MlpTraining
import NN.Examples.Quickstart.SimpleMlpTrain

/-!
# TorchLean MLP tests

Checks the model summary and runs a minimal training and prediction workload.
-/

namespace LeanProfilerTorchLean.Tests.MlpTraining

open LeanProfiler.TorchLean.MlpTraining
open _root_.TorchLean
open NN.Examples.Quickstart.SimpleMlpTrain

def expect (label : String) (condition : Bool) : IO Unit := do
  unless condition do
    throw <| IO.userError s!"TorchLean MLP profile test failed: {label}"

/-- Check the model dimensions and exercise one training step and prediction. -/
public def run : IO Unit := do
  let summary ← IO.ofExcept (nn.summary (Trainer.new model { seed := 0 }).model)
  expect "the example uses the 33-parameter quickstart MLP"
    (summary.layerCount == 3 && summary.totalParameterCount == 33)
  LeanProfiler.TorchLean.MlpTraining.run
    { enabled := false }
    { steps := 1, samplesPerStep := 1, warmupRuns := 0, predictionRuns := 1 }

end LeanProfilerTorchLean.Tests.MlpTraining
