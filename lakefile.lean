import Lake
open System Lake DSL

package «hegel-lean» where
  version := v!"0.1.0"
  description := "Lean 4 frontend for Hegel's native property testing engine"
  license := "MIT"

target hegelEngine pkg : FilePath := do
  -- The fetcher verifies cached artifacts too, and is relative to the dependency package.
  proc { cmd := "python3", args := #[(pkg.dir / "scripts/fetch_engine.py").toString] }
  inputBinFile (pkg.dir / ".lake/hegel/libhegel.a")

target hegelShim pkg : FilePath := do
  let engine ← hegelEngine.fetch
  let header ← inputTextFile (pkg.dir / ".lake/hegel/hegel.h")
  let source ← inputTextFile (pkg.dir / "c/hegel_lean.c")
  let source ← source.mapM fun path => do
    addTrace engine.getTrace
    addTrace header.getTrace
    return path
  let obj ← buildO (pkg.buildDir / "c/hegel_lean.o") source
    #["-I", (← getLeanIncludeDir).toString, "-I", (pkg.dir / ".lake/hegel").toString]
    #["-std=c11", "-fPIC", "-Wall", "-Wextra", "-Werror"]
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "hegel_lean") #[obj]

@[default_target]
lean_lib Hegel where
  moreLinkObjs := #[hegelShim, hegelEngine]
  moreLinkArgs := if Platform.isOSX then #["-liconv"] else #["-lpthread", "-ldl", "-lm"]

@[test_driver]
lean_exe hegel_tests where
  root := `Tests.Main

lean_lib Tests where
  roots := #[`Tests.MacIver]

lean_exe hegel_examples where
  root := `Examples.Main

lean_exe hegel_maciver_tests where
  root := `Tests.MacIverMain
