/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

module

public import LeanProfiler.Config
import LeanProfiler.Instrumentation
import NN.Examples.Quickstart.SimpleMlpTrain

/-!
# TorchLean MLP training profile

Profiles training and repeated inference for TorchLean's quickstart MLP.
-/

namespace LeanProfiler.TorchLean.MlpTraining

open LeanProfiler
open _root_.TorchLean
open Trainer.Objective (mse)
open NN.Examples.Quickstart.SimpleMlpTrain

/-- Training and inference sizes for the MLP workload. -/
public structure WorkloadConfig where
  /-- Seed used to initialize the imported TorchLean model. -/
  seed : Nat := 0
  /-- Number of optimizer updates in the measured training run. -/
  steps : Nat := 20
  /-- Number of dataset items accumulated before each optimizer update. -/
  samplesPerStep : Nat := 5
  /-- Predictions run before the timed prediction spans. -/
  warmupRuns : Nat := 1
  /-- Number of post-training predictions used to form an inference latency distribution. -/
  predictionRuns : Nat := 10
  deriving Repr, Inhabited, DecidableEq

def modelMetadata : Metadata :=
  {
    backend := some "eager"
    dtype := some "float32"
    device := some "cpu"
    moduleName := some "quickstart.simple-mlp"
    inputShapes := #[Shape.pretty [2]]
    outputShapes := #[Shape.pretty [1]]
  }

/-- Profile one training run and repeated predictions with TorchLean's quickstart MLP. -/
public def run (profiler : ProfilerConfig) (workload : WorkloadConfig := {}) : IO Unit := do
  let trainer := Trainer.new model {
    objective := mse
    optimizer := optim.adam { learningRate := 0.03 }
    arithmetic := native
    execution := eager
    seed := workload.seed
  }
  IO.println "== TorchLean MLP profile =="
  let summary ← IO.ofExcept (nn.summary trainer.model)
  IO.println summary
  let (trainingSummary, lastPrediction) ←
    profile profiler "torchlean.mlp-training" do
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
      let heldout : Tensor Float [2] := [0.25, -0.75]
      -- Warmups are excluded from the inference latency row.
      for _ in List.range workload.warmupRuns do
        let _ ← trained.predict heldout
      let predictions ← (List.range workload.predictionRuns).mapM fun iteration =>
        withStep iteration do
          span "model.predict" (trained.predict heldout) (metadata := {
            modelMetadata with
            phase := some "inference"
            activity := some "held-out prediction"
          })
      pure (trained.summary, predictions.getLast?.map reprStr)
  IO.println trainingSummary
  if let some prediction := lastPrediction then
    IO.println s!"last prediction = {prediction}"

end LeanProfiler.TorchLean.MlpTraining
