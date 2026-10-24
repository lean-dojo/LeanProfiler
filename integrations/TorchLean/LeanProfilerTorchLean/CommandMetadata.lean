/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

module

public import LeanProfiler.Runtime.Event
import NN.API.Module.Command

/-!
# TorchLean command metadata

Reads the runtime choices that belong on a model-command span without duplicating TorchLean's
command dispatcher.
-/

namespace LeanProfiler.TorchLean.CommandMetadata

/-- Structured runtime labels inferred from TorchLean's common command flags. -/
public def fromArguments (args : List String) : Metadata :=
  match (TorchLean.Module.RuntimeSelection.parse args).toOption with
  | none => { activity := some "model command" }
  | some (selection, _) => {
      activity := some "model command"
      dtype := if TorchLean.CLI.hasFlagValue args "arithmetic" then
        some (match selection.arithmetic with
          | .native => "float32"
          | .ieee => "ieee-binary32"
          | .complex => "complex64") else none
      device := if TorchLean.CLI.hasFlagValue args "device" then
        some selection.device.cliName else none
    }

/-- Whether the command explicitly selects TorchLean's CUDA runtime. -/
public def usesCuda (args : List String) : Bool :=
  match (TorchLean.Module.RuntimeSelection.parse args).toOption with
  | some (selection, _) => selection.device == .cuda
  | none => false

end LeanProfiler.TorchLean.CommandMetadata
