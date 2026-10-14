/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

module

public import LeanProfiler.Comparison.Policy

/-!
# Comparison command options

Argument parsing for the standalone `compare` command.
-/

namespace LeanProfiler.CLI

open LeanProfiler

/-- Inputs and failure policy for `leanprofiler compare`. -/
public structure CompareOptions where
  baselinePath : System.FilePath
  candidatePath : System.FilePath
  config : ComparisonConfig := {}
  jsonPath : Option System.FilePath := none
  failOnNew : Bool := false
  failOnMissing : Bool := false
  allowIncomplete : Bool := false
  deriving Repr, Inhabited

def parseNatFlag (flag value : String) : Except String Nat :=
  match value.toNat? with
  | some result => pure result
  | none => throw s!"{flag} expects a nonnegative integer, found `{value}`"

def parseFlags (options : CompareOptions) : List String → Except String CompareOptions
  | [] => pure options
  | "--metric" :: value :: rest => do
      let metric ← ComparisonMetric.parse value
      parseFlags { options with config := { options.config with metric } } rest
  | "--absolute-tolerance" :: value :: rest => do
      let absolute ← parseNatFlag "--absolute-tolerance" value
      parseFlags {
        options with
        config := { options.config with threshold := { options.config.threshold with absolute } }
      } rest
  | "--relative-tolerance-bps" :: value :: rest => do
      let relativeBps ← parseNatFlag "--relative-tolerance-bps" value
      parseFlags {
        options with
        config := {
          options.config with
          threshold := { options.config.threshold with relativeBps }
        }
      } rest
  | "--json" :: value :: rest =>
      parseFlags { options with jsonPath := some value } rest
  | "--fail-on-new" :: rest =>
      parseFlags { options with failOnNew := true } rest
  | "--fail-on-missing" :: rest =>
      parseFlags { options with failOnMissing := true } rest
  | "--allow-incomplete" :: rest =>
      parseFlags { options with allowIncomplete := true } rest
  | "--metric" :: [] => throw "`--metric` requires a value"
  | "--absolute-tolerance" :: [] => throw "`--absolute-tolerance` requires a value"
  | "--relative-tolerance-bps" :: [] =>
      throw "`--relative-tolerance-bps` requires a value"
  | "--json" :: [] => throw "`--json` requires an output path"
  | argument :: _ =>
      throw s!"unexpected comparison argument `{argument}`"

/-- Parse arguments following the `compare` command name. -/
public def parseCompareOptions : List String → Except String CompareOptions
  | baseline :: candidate :: flags =>
      if baseline.startsWith "--" then
        throw "BASELINE must appear before comparison options"
      else if candidate.startsWith "--" then
        throw "CANDIDATE must appear before comparison options"
      else
        parseFlags {
          baselinePath := baseline
          candidatePath := candidate
        } flags
  | _ => throw "compare requires BASELINE and CANDIDATE summary paths"

end LeanProfiler.CLI
