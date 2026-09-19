import Hegel.Report.Types

namespace Hegel

inductive OutputPreference where
  | auto | ascii | unicode
  deriving Repr, BEq, Inhabited

inductive LogCell where
  | failure | elided | ellipsis | responseArrow | blank
  deriving Repr, BEq, Inhabited

structure GlyphTable where
  cell : LogCell → String
  valueName : Option String → Nat → Nat → String

private def poolLetter (index : Nat) : String :=
  String.ofList (List.replicate (index / 5 + 1) ("vwxyz".toList[index % 5]!))

def GlyphTable.ascii : GlyphTable := {
  cell := fun cell => match cell with
    | .failure => "x" | .elided => ">" | .ellipsis => "..."
    | .responseArrow => "->" | .blank => " "
  valueName := fun label pool ordinal => (label.getD (poolLetter pool)) ++ toString ordinal }

def GlyphTable.unicode : GlyphTable := {
  cell := fun cell => match cell with
    | .failure => "✗" | .elided => "▸" | .ellipsis => "⋯"
    | .responseArrow => "→" | .blank => " "
  valueName := fun label pool ordinal =>
    (label.getD (poolLetter pool)) ++ String.ofList ((toString ordinal).toList.map fun c =>
      Char.ofNat (0x2080 + c.toNat - '0'.toNat)) }

structure PhraseTable where
  elidedSteps : Nat → Option String → String
  elidedBranches : Nat → String
  stored : String → String
  unreproducible : String
  stepOrigin : Nat → Nat → Option String → String

def PhraseTable.english : PhraseTable := {
  elidedSteps := fun n concerns =>
    s!"{n} {if n == 1 then "step" else "steps"} elided" ++
      (concerns.map (" (" ++ · ++ ")")).getD ""
  elidedBranches := fun n => s!"{n} {if n == 1 then "branch" else "branches"} passed"
  stored := fun key => "stored under " ++ key ++ "; replayed on the next run"
  unreproducible := "Concurrent execution has no deterministic replay blob."
  stepOrigin := fun round worker group =>
    s!"round {round}, worker {worker}" ++ (group.map (" (" ++ · ++ ")")).getD "" }

structure ReportStyle where
  preference : OutputPreference := .unicode
  color : Bool := false
  sourceContext : Nat := 2
  maxValueLines : Nat := 40
  maxSourceLines : Nat := 80
  callWidth : Nat := 40
  glyphs : Option GlyphTable := none
  phrases : PhraseTable := .english

instance : Inhabited ReportStyle := ⟨{}⟩

namespace ReportStyle

def glyphTable (style : ReportStyle) : GlyphTable :=
  style.glyphs.getD (if style.preference == .ascii then .ascii else .unicode)

/-- Environment override controls presentation; Lean output itself always encodes UTF-8. -/
def resolve (style : ReportStyle) : IO ReportStyle := do
  if style.preference != .auto then return style
  let preference := match ← IO.getEnv "HEGEL_GLYPHS" with
    | some "ascii" => OutputPreference.ascii
    | _ => .unicode
  return { style with preference }

private def hex (n : Nat) : String := String.ofList (Nat.toDigits 16 n)

/-- ASCII mode escapes every non-ASCII scalar, including values and file names. -/
def clean (preference : OutputPreference) (text : String) : String :=
  if preference != .ascii then text
  else String.join <| text.toList.map fun char =>
    if char.toNat < 128 then String.singleton char else "\\u{" ++ hex char.toNat ++ "}"

def limitLines (limit : Nat) (text : String) : String :=
  let lines := text.splitOn "\n"
  if limit == 0 || lines.length <= limit then text
  else String.intercalate "\n" (lines.take limit) ++
    s!"\n... ({lines.length - limit} more lines)"

/-- Apply terminal styling after all source, value, and fallback text has been assembled. -/
def finish (style : ReportStyle) (text : String) : String :=
  let text := clean style.preference text
  if !style.color then text
  else String.intercalate "\n" <| (text.splitOn "\n").map fun line =>
    let content := line.trimAsciiStart.toString
    let color := if content.startsWith "- " || content.startsWith "FAIL" then "31"
      else if content.startsWith "+ " || content.startsWith "PASS" then "32"
      else if content.startsWith "ERROR" || content.startsWith "GAVE UP" then "33"
      else if content.startsWith "at " then "2"
      else ""
    if color.isEmpty then line else "\x1b[" ++ color ++ "m" ++ line ++ "\x1b[0m"

end ReportStyle

inductive LogRowKind where
  | node | detail | elision
  deriving Repr, BEq, Inhabited

structure LogRow where
  kind : LogRowKind
  cell : LogCell := .blank
  step : Option Nat := none
  text : String
  origin : Option String := none
  deriving Repr, BEq, Inhabited

def Trace.displayName (trace : Trace) (style : ReportStyle) (ref : PoolVar) : String :=
  let root := trace.root ref
  let identity := trace.identity root
  style.glyphTable.valueName (identity.bind (·.label)) root.pool
    (identity.map (·.ordinal) |>.getD (root.index + 1))

private def firstLine (text : String) : String := (text.splitOn "\n").head!

private def clipped (style : ReportStyle) (text : String) : String :=
  if style.callWidth == 0 || text.length <= style.callWidth then text
  else String.ofList (text.toList.take style.callWidth) ++ style.glyphTable.cell .ellipsis

/-- Keep every failing step and every step touching its value lineage; elide other runs. -/
def Trace.layoutRows (trace : Trace) (style : ReportStyle := {}) : Array LogRow := Id.run do
  let failing := trace.failureStep.bind trace.step
  let roots := (failing.map (·.touches) |>.getD #[]).map (trace.root ∘ (·.ref))
  let mut rows : Array LogRow := #[]
  let mut hidden : Array TraceStep := #[]
  let flush := fun (hidden : Array TraceStep) (rows : Array LogRow) => Id.run do
    if hidden.isEmpty then return rows
    let names := hidden.foldl (fun names step => step.touches.foldl (fun names touch =>
      let name := trace.displayName style touch.ref
      if names.contains name then names else names.push name) names) (#[] : Array String)
    let concerns := if names.isEmpty then none else some (String.intercalate ", " names.toList)
    return rows.push {
      kind := .elision, cell := .elided
      text := style.phrases.elidedSteps hidden.size concerns }
  for step in trace.steps do
    if step.index != 0 && !step.failed && !roots.isEmpty &&
        !(step.touches.any fun event => roots.contains (trace.root event.ref)) then
      hidden := hidden.push step
    else
      rows := flush hidden rows
      hidden := #[]
      if step.index != 0 then
        let names := step.touches.foldl (fun names event =>
          let name := trace.displayName style event.ref
          if names.contains name then names else names.push name) (#[] : Array String)
        let args := String.intercalate ", " names.toList
        let response := (step.response.map fun response =>
          " " ++ style.glyphTable.cell .responseArrow ++ " " ++ firstLine response).getD ""
        let call := firstLine step.rule ++ "(" ++ args ++ ")" ++ response
        rows := rows.push {
          kind := .node, cell := if step.failed then .failure else .blank
          step := some step.index, text := clipped style call
          origin := step.origin.map fun origin =>
            style.phrases.stepOrigin origin.round origin.worker origin.group }
      for note in step.notes do
        match note.kind with
        | .annotation =>
          rows := rows.push { kind := .detail, text := firstLine note.text }
        | .drawn refs =>
          unless refs.size == 1 && step.touches.any (·.ref == refs[0]!) do
            rows := rows.push { kind := .detail, text := firstLine note.text }
        | _ => pure ()
  return flush hidden rows

def Trace.renderWith (style : ReportStyle) (trace : Trace) : String :=
  let rows := trace.layoutRows style
  style.finish <| String.intercalate "\n" <| rows.toList.map fun row =>
    style.glyphTable.cell row.cell ++ " " ++
      (row.step.map (toString · ++ ": ")).getD "   " ++ row.text ++
      (row.origin.map ("  | " ++ ·)).getD ""

def Journal.renderWith (style : ReportStyle) (notes : Array Note) : String :=
  let notes := notes.map fun note =>
    -- Failure evidence is never elided by a value-rendering budget.
    if note.isFailure then note else
      { note with text := ReportStyle.limitLines style.maxValueLines note.text }
  style.finish (Journal.render notes)

def Journal.renderSourceWith (style : ReportStyle) (source : SourceLocation) : IO String := do
  let text ← Journal.renderSource source style.sourceContext
  return style.finish (ReportStyle.limitLines style.maxSourceLines text)

end Hegel
