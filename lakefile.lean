import Lake
open System Lake DSL

package «hegel-lean» where
  version := v!"1.0.0"
  description := "Lean 4 frontend for Hegel's native property testing engine"
  license := "MIT"

target hegelEngine pkg : FilePath := do
  -- The fetcher verifies cached artifacts too, and is relative to the dependency package.
  proc { cmd := "python3", args := #[(pkg.dir / "scripts/fetch_engine.py").toString] }
  inputBinFile (pkg.dir / ".lake/hegel/libhegel.a")

target hegelShim pkg : FilePath := do
  let engine ← hegelEngine.fetch
  let header ← inputTextFile (pkg.dir / ".lake/hegel/hegel.h")
  let sharedHeader ← inputTextFile (pkg.dir / "c/hegel_lean.h")
  let mut objects := #[]
  for entry in ← (pkg.dir / "c").readDir do
    if entry.path.extension == some "c" then
      let source ← inputTextFile entry.path
      let source ← source.mapM fun path => do
        addTrace engine.getTrace
        addTrace header.getTrace
        addTrace sharedHeader.getTrace
        return path
      let obj ← buildO (pkg.buildDir / "c" / (entry.fileName ++ ".o")) source
        #["-I", (← getLeanIncludeDir).toString, "-I", (pkg.dir / ".lake/hegel").toString,
          "-I", (pkg.dir / "c").toString]
        #["-std=c11", "-fPIC", "-Wall", "-Wextra", "-Werror"]
      objects := objects.push obj
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "hegel_lean") objects

@[default_target]
lean_lib Hegel where
  moreLinkObjs := #[hegelShim, hegelEngine]
  moreLinkArgs := if Platform.isOSX then #["-liconv"] else #["-lpthread", "-ldl", "-lm"]

@[test_driver]
lean_exe hegel_tests where
  root := `Tests.Main

lean_lib Tests where
  roots := #[`Tests.MacIver, `Tests.Generators, `Tests.Reporting, `Tests.Stateful, `Tests.Safety, `Tests.Concurrency, `Tests.Replay]

lean_exe hegel_examples where
  root := `Examples.Main

lean_exe hegel_maciver_tests where
  root := `Tests.MacIverMain

lean_exe hegel_generator_tests where
  root := `Tests.GeneratorsMain

lean_exe hegel_reporting_tests where
  root := `Tests.ReportingMain

lean_exe hegel_stateful_tests where
  root := `Tests.StatefulMain

lean_exe hegel_panic_probe where
  root := `Tests.PanicProbe

lean_exe hegel_concurrency_tests where
  root := `Tests.ConcurrencyMain
