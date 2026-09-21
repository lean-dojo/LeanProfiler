/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

module

public import LeanProfiler.Runtime.Event

/-!
# TorchLean command metadata

Reads the runtime choices that belong on a model-command span without duplicating TorchLean's
command dispatcher.
-/

namespace LeanProfiler.TorchLean.CommandMetadata

/-- Find either `--flag value` or `--flag=value` in a command argument list. -/
public def optionValue? (flag : String) : List String → Option String
  | [] => none
  | argument :: rest =>
      if argument == flag then
        rest.head?
      else
        let flagPrefix := flag ++ "="
        if argument.startsWith flagPrefix then
          some (argument.drop flagPrefix.length).toString
        else
          optionValue? flag rest

/-- Structured runtime labels inferred from TorchLean's common command flags. -/
public def fromArguments (args : List String) : Metadata :=
  {
    activity := some "model command"
    backend := optionValue? "--execution" args
    dtype := (optionValue? "--arithmetic" args).bind fun
      | "native" => some "float32"
      | "ieee" => some "ieee-binary32"
      | "complex" => some "complex64"
      | _ => none
    device := optionValue? "--device" args
  }

/-- Whether the command explicitly selects TorchLean's CUDA runtime. -/
public def usesCuda (args : List String) : Bool :=
  optionValue? "--device" args == some "cuda"

end LeanProfiler.TorchLean.CommandMetadata
