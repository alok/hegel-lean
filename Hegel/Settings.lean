import Hegel.Internal.Settings
import Hegel.Report.Types

namespace Hegel

inductive Phase where
  | explicit | reuse | generate | target | shrink
  deriving Repr, BEq, Inhabited

def Phase.mask : Phase → UInt32
  | .explicit => 1
  | .reuse => 2
  | .generate => 4
  | .target => 8
  | .shrink => 16

inductive Backend where
  | auto | default | urandom
  deriving Repr, BEq, Inhabited

def Backend.code : Backend → UInt32
  | .auto => 0
  | .default => 1
  | .urandom => 2

inductive Verbosity where
  | quiet | normal | verbose | debug
  deriving Repr, BEq, Inhabited

def Verbosity.code : Verbosity → UInt32
  | .normal => 0
  | .quiet => 1
  | .verbose => 2
  | .debug => 3

inductive HealthCheck where
  | filterTooMuch | tooSlow | testCasesTooLarge | largeInitialTestCase
  deriving Repr, BEq, Inhabited

def HealthCheck.mask : HealthCheck → UInt32
  | .filterTooMuch => 1
  | .tooSlow => 2
  | .testCasesTooLarge => 4
  | .largeInitialTestCase => 8

structure Settings where
  maxExamples : UInt64 := 100
  statefulStepCount : Nat := 50
  seed : Option UInt64 := none
  derandomize : Bool := false
  database : Option System.FilePath := some ".hegel/examples"
  databaseKey : Option String := none
  phases : Array Phase := #[.explicit, .reuse, .generate, .target, .shrink]
  backend : Backend := .default
  verbosity : Verbosity := .quiet
  reportMultipleFailures : Bool := true
  /-- Original bitmask API, combined with the typed list below. -/
  suppressHealthChecks : UInt32 := 0
  suppressHealthCheck : Array HealthCheck := #[]
  maxCloneDepth : Nat := 32
  showStatistics : Bool := false
  unboundedChoices : Bool := false
  printBlob : Bool := true
  deriving Repr, Inhabited

structure SettingsError where
  diagnostic : Diagnostic
  deriving Repr, BEq, Inhabited

instance : ToString SettingsError where
  toString error := error.diagnostic.render

def Settings.withDatabaseKey (settings : Settings) (key : String) : Settings :=
  { settings with databaseKey := some key }

def Settings.phaseMask (settings : Settings) : UInt32 :=
  settings.phases.foldl (fun mask phase => mask ||| phase.mask) 0

def Settings.healthCheckMask (settings : Settings) : UInt32 :=
  settings.suppressHealthCheck.foldl (fun mask check => mask ||| check.mask)
    settings.suppressHealthChecks

def Settings.validate (settings : Settings) : Except SettingsError Unit := do
  if settings.statefulStepCount == 0 then
    throw ⟨{ context := "Settings.statefulStepCount", detail := "must be at least 1" }⟩
  if settings.statefulStepCount > UInt64.size - 1 then
    throw ⟨{ context := "Settings.statefulStepCount", detail := "exceeds UInt64" }⟩
  if settings.healthCheckMask &&& 0xfffffff0 != 0 then
    throw ⟨{ context := "Settings.suppressHealthChecks", detail := "unknown health-check bits" }⟩
  for (name, value) in #[
      ("database", settings.database.map toString |>.getD ""),
      ("databaseKey", settings.databaseKey.getD "")] do
    if value.contains '\x00' then
      throw ⟨{ context := "Settings." ++ name, detail := "contains an embedded NUL" }⟩

/-- Configure additional engine options after allocation and before starting the campaign. -/
def Settings.configure (session : Internal.Session.type) (settings : Settings) :
    EIO Internal.EngineError Unit := do
  match settings.validate with
  | .error error => throw { code := -1, message := toString error }
  | .ok () => pure ()
  Internal.configure session settings.backend.code settings.verbosity.code settings.derandomize
    settings.showStatistics settings.unboundedChoices settings.printBlob
    (settings.databaseKey.getD "") settings.databaseKey.isSome

end Hegel
