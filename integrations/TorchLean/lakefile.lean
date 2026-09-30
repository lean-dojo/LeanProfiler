/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import Lake

open Lake DSL

/-- Host numerical primitives need libm on Linux; LibTorch carries its own SDK link settings. -/
private def nativeLinkArgs : Array String :=
  if System.Platform.isWindows || System.Platform.isOSX then
    #[]
  else
    #["-lm"]

/--
Forward optional native-runtime settings to TorchLean.

Lake applies command-line `-K` values to the workspace root only. TorchLean is a dependency here,
so its CUDA build would otherwise keep using the unavailable-backend shim even when this package
was invoked with `-K cuda=true`.
-/
private def torchLeanOptions : Lean.NameMap String :=
  let options : Lean.NameMap String := {}
  let options :=
    match get_config? torchleanBuildDir with
    | some value => options.insert `torchleanBuildDir value
    | none => options
  let options :=
    match get_config? cuda with
    | some value => options.insert `cuda value
    | none => options
  let options :=
    match get_config? cuda_home with
    | some value => options.insert `cuda_home value
    | none => options
  match get_config? libtorch_home with
  | some value => options.insert `libtorch_home value
  | none => options

package LeanProfilerTorchLean where
  version := v!"0.1.0"
  testDriver := "leanprofiler_torchlean_tests"
  builtinLint := true
  leanOptions := #[
    ⟨`linter.missingDocs, true⟩,
    ⟨`linter.redundantVisibility, true⟩
  ]
  moreLinkArgs := nativeLinkArgs

require LeanProfiler from "../.."

require TorchLean from git
  "https://github.com/lean-dojo/TorchLean" @ "main"
  with torchLeanOptions

@[default_target]
lean_lib LeanProfilerTorchLean

@[default_target]
lean_exe leanprofiler_torchlean where
  root := `LeanProfilerTorchLean.Executables.Runner

@[default_target]
lean_exe leanprofiler_torchlean_mlp where
  root := `LeanProfilerTorchLean.Executables.MlpTraining

lean_exe leanprofiler_torchlean_tests where
  root := `LeanProfilerTorchLean.Tests.Main

lean_exe leanprofiler_torchlean_cuda_tests where
  root := `LeanProfilerTorchLean.Executables.CudaTests
