namespace Hegel

/-- One line of an assertion difference, oriented from actual to expected. -/
inductive LineDiff where
  | same (text : String)
  | removed (text : String)
  | added (text : String)
  deriving Repr, BEq, Inhabited

abbrev Diff := Array LineDiff

def renderDiff (diff : Diff) : String :=
  String.intercalate "\n" <| diff.toList.map fun line => match line with
    | .same text => "  " ++ text
    | .removed text => "- " ++ text
    | .added text => "+ " ++ text

/-- Preserve common leading and trailing lines, without overlapping their context. -/
def diffLines (actual expected : String) : Diff := Id.run do
  let left := (actual.splitOn "\n").toArray
  let right := (expected.splitOn "\n").toArray
  let mut first := 0
  while first < min left.size right.size && left[first]! == right[first]! do
    first := first + 1
  let mut last := 0
  while last < min (left.size - first) (right.size - first) &&
      left[left.size - last - 1]! == right[right.size - last - 1]! do
    last := last + 1
  return (left.extract 0 first |>.map .same) ++
    (left.extract first (left.size - last) |>.map .removed) ++
    (right.extract first (right.size - last) |>.map .added) ++
    (left.extract (left.size - last) left.size |>.map .same)

/-- A printable value tree. Applications and records retain their outer shape during diffing. -/
inductive DiffValue where
  | atom (text : String)
  | group (opening closing : String) (items : List DiffValue)
  deriving Repr, BEq, Inhabited

def DiffValue.render : DiffValue → String
  | .atom text => text
  | .group opening closing items =>
    opening ++ String.intercalate ", " (items.map render) ++ closing

private def indentDiff (padding : String) : Diff → Diff := Array.map fun line => match line with
  | .same text => .same (padding ++ text)
  | .removed text => .removed (padding ++ text)
  | .added text => .added (padding ++ text)

/-- Recursively compare matching list, tuple, record, and constructor shapes. -/
partial def diffValues (actual expected : DiffValue) : Diff :=
  if actual == expected then #[.same actual.render]
  else match actual, expected with
    | .group lo lc ls, .group ro rc rs =>
      if lo == ro && lc == rc && ls.length == rs.length then
        #[.same lo] ++ (ls.zip rs).foldl (fun acc (l, r) =>
          acc ++ indentDiff "  " (diffValues l r)) #[] ++ #[.same lc]
      else #[.removed actual.render, .added expected.render]
    | _, _ => #[.removed actual.render, .added expected.render]

private def closing : Char → Option Char
  | '[' => some ']'
  | '(' => some ')'
  | '{' => some '}'
  | _ => none

/-- Split only top-level commas. Quotes and escaped quotes do not affect nesting. -/
private def splitItems (chars : List Char) : Option (List String) := Id.run do
  let mut stack : List Char := []
  let mut quoted := false
  let mut escaped := false
  let mut current : List Char := []
  let mut items : List String := []
  for char in chars do
    if quoted then
      current := char :: current
      if escaped then escaped := false
      else if char == '\\' then escaped := true
      else if char == '"' then quoted := false
    else if char == '"' then
      quoted := true
      current := char :: current
    else if let some close := closing char then
      stack := close :: stack
      current := char :: current
    else if char == ']' || char == ')' || char == '}' then
      if stack.head? != some char then return none
      stack := stack.tail
      current := char :: current
    else if char == ',' && stack.isEmpty then
      items := (String.ofList current.reverse).trimAscii.toString :: items
      current := []
    else current := char :: current
  if quoted || !stack.isEmpty then return none
  let final := (String.ofList current.reverse).trimAscii.toString
  if items.isEmpty && final.isEmpty then return some []
  return some ((final :: items).reverse)

private def parseShown (fuel : Nat) (text : String) : Option DiffValue := do
  let text := text.trimAscii.toString
  if text.isEmpty then return ← none
  match fuel with
  | 0 => none
  | fuel + 1 =>
    let chars := text.toList
    -- Accept bracketed collections and a constructor/field prefix before a bracket.
    let opener := chars.findIdx? fun char => (closing char).isSome
    match opener with
    | none =>
      let _ ← splitItems chars
      return .atom text
    | some index =>
      -- Brackets inside a quoted atom are literal data.
      if chars.head? == some '"' then
        let _ ← splitItems chars
        return .atom text
      let start := chars[index]!
      let finish ← closing start
      if chars.getLast? != some finish then return ← none
      let children ← splitItems (chars.drop (index + 1) |>.dropLast)
      let children ← children.mapM (parseShown fuel)
      return .group (String.ofList (chars.take (index + 1))) (String.singleton finish) children

/-- Parse balanced Lean `Repr` collection/record syntax; fall back for unsupported formats. -/
def diffShown (actual expected : String) : Option Diff := do
  let left ← parseShown (actual.length + 1) actual
  let right ← parseShown (expected.length + 1) expected
  return diffValues left right

def diffRepr [Repr α] (actual expected : α) : Diff :=
  (diffShown (reprStr actual) (reprStr expected)).getD
    (diffLines (reprStr actual) (reprStr expected))

end Hegel
