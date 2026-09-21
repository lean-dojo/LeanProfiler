/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import Lake
import Lake.Util.Proc

open Lake DSL

/-- Whether this workspace should compile and link TorchLean's native CUDA runtime. -/
private def cudaEnabled : Bool :=
  match get_config? cuda with
  | some value => value == "true" || value == "1"
  | none => false

/-- CUDA toolkit root shared by TorchLean's compiler and this package's final linker. -/
private def cudaHome : String :=
  match get_config? cuda_home with
  | some value =>
      let path := value.trimAscii.toString
      if path.isEmpty then "/usr/local/cuda" else path
  | none => "/usr/local/cuda"

/--
Link arguments required by executables that consume TorchLean as a dependency.

TorchLean's native archives propagate through its Lean library, but package-level link flags do not.
The final executable therefore names the CUDA runtime libraries again.
-/
private def nativeLinkArgs : Array String :=
  if cudaEnabled then
    #[
      "-L", s!"{cudaHome}/lib64",
      "-lcudart", "-lcublas", "-lcufft",
      "-Wl,-rpath," ++ s!"{cudaHome}/lib64"
    ]
  else
    #[]

/-- Build the CUDA synchronization bridge or its portable mismatch stub. -/
private def buildCudaBridge (pkg : Package) := do
  let source :=
    if cudaEnabled then
      pkg.dir / "csrc/leanprofiler_torchlean_cuda.c"
    else
      pkg.dir / "csrc/leanprofiler_torchlean_cuda_stub.c"
  let sourceJob ← inputFile source false
  let object := pkg.buildDir /
    (if cudaEnabled then "leanprofiler_torchlean_cuda.o" else "leanprofiler_torchlean_cuda_stub.o")
  let compileArgs :=
    if cudaEnabled then
      #["-I", s!"{cudaHome}/include", "-O2", "-fPIC"]
    else
      #["-O2", "-fPIC"]
  let objectJob ← buildO object sourceJob compileArgs #[] "cc"
  buildStaticLib (pkg.buildDir / nameToStaticLib "leanprofiler_torchlean_cuda") #[objectJob]

/--
Forward optional native-runtime settings to TorchLean.

Lake applies command-line `-K` values to the workspace root only. TorchLean is a dependency here,
so its CUDA build would otherwise keep using the CPU parity stubs even when this package was invoked
with `-K cuda=true`.
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
  let options :=
    match get_config? cuda_arch with
    | some value => options.insert `cuda_arch value
    | none => options
  let options :=
    match get_config? libtorch_home with
    | some value => options.insert `libtorch_home value
    | none => options
  match get_config? libtorch with
  | some value => options.insert `libtorch value
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

extern_lib leanprofiler_torchlean_cuda (pkg) :=
  buildCudaBridge pkg

require LeanProfiler from "../.."

require TorchLean from git
  "https://github.com/lean-dojo/TorchLean" @ "main"
  with torchLeanOptions

@[default_target]
lean_lib LeanProfilerTorchLean where
  moreLinkObjs := #[leanprofiler_torchlean_cuda]

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
