import Hegel.Gen
import Hegel.Internal.Generators

namespace Hegel

inductive Codec where
  | ascii | latin1 | utf8
  deriving Repr, BEq, Inhabited

def Codec.name : Codec → String
  | .ascii => "ascii"
  | .latin1 => "latin-1"
  | .utf8 => "utf-8"

/-- Unicode general categories, using their standard two-letter identifiers. -/
inductive GeneralCategory where
  | Lu | Ll | Lt | Lm | Lo | Mn | Mc | Me | Nd | Nl | No
  | Pc | Pd | Ps | Pe | Pi | Pf | Po | Sm | Sc | Sk | So
  | Zs | Zl | Zp | Cc | Cf | Cs | Co | Cn
  deriving Repr, BEq, Inhabited

def GeneralCategory.code : GeneralCategory → String
  | .Lu => "Lu" | .Ll => "Ll" | .Lt => "Lt" | .Lm => "Lm" | .Lo => "Lo"
  | .Mn => "Mn" | .Mc => "Mc" | .Me => "Me" | .Nd => "Nd" | .Nl => "Nl"
  | .No => "No" | .Pc => "Pc" | .Pd => "Pd" | .Ps => "Ps" | .Pe => "Pe"
  | .Pi => "Pi" | .Pf => "Pf" | .Po => "Po" | .Sm => "Sm" | .Sc => "Sc"
  | .Sk => "Sk" | .So => "So" | .Zs => "Zs" | .Zl => "Zl" | .Zp => "Zp"
  | .Cc => "Cc" | .Cf => "Cf" | .Cs => "Cs" | .Co => "Co" | .Cn => "Cn"

/-- A Unicode alphabet. Explicit inclusion is applied before exclusion; surrogates are removed. -/
structure Alphabet where
  codec : Codec := .utf8
  minCodepoint : Nat := 0
  maxCodepoint : Nat := 0x10ffff
  categories : Option (Array GeneralCategory) := none
  excludeCategories : Array GeneralCategory := #[]
  includeCharacters : String := ""
  excludeCharacters : String := ""
  deriving Repr, Inhabited

namespace Alphabet

def only (characters : String) : Alphabet :=
  { categories := some #[], includeCharacters := characters }

/-- Include valid Unicode scalar values from inclusive ranges. -/
def ranges (rs : Array (Nat × Nat)) : Alphabet := only <| String.ofList <|
  rs.toList.flatMap fun (lo, hi) =>
    (List.range (min hi 0x10ffff + 1 - lo)).filterMap fun offset =>
      let cp := lo + offset
      if cp < 0xd800 || cp > 0xdfff then some (Char.ofNat cp) else none

def ascii : Alphabet := { codec := .ascii }
def asciiPrintable : Alphabet := { minCodepoint := 0x20, maxCodepoint := 0x7e }
def lower : Alphabet := { minCodepoint := 0x61, maxCodepoint := 0x7a }
def upper : Alphabet := { minCodepoint := 0x41, maxCodepoint := 0x5a }
def alpha : Alphabet := { codec := .ascii, categories := some #[.Ll, .Lu] }
def digit : Alphabet := { minCodepoint := 0x30, maxCodepoint := 0x39 }
def alphaNum : Alphabet := { codec := .ascii, categories := some #[.Ll, .Lu, .Nd] }
def binit : Alphabet := { minCodepoint := 0x30, maxCodepoint := 0x31 }
def octit : Alphabet := { minCodepoint := 0x30, maxCodepoint := 0x37 }
def hexit : Alphabet := only "0123456789abcdefABCDEF"
def latin1 : Alphabet := { codec := .latin1 }
def unicode : Alphabet := {}
def asciiPunctuation : Alphabet := only "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
def base64 : Alphabet := only "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
def base64Url : Alphabet := only "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
def uriUnreserved : Alphabet :=
  only "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
def whitespace : Alphabet :=
  { categories := some #[.Zs, .Zl, .Zp], includeCharacters := "\t\n\x0b\x0c\r\x85" }
def combiningMarks : Alphabet := { categories := some #[.Mn, .Mc, .Me] }
def zeroWidth : Alphabet := ranges #[(0x200b, 0x200d), (0x2060, 0x2060), (0xfeff, 0xfeff)]
def bidiControls : Alphabet := ranges #[(0x200e, 0x200f), (0x202a, 0x202e), (0x2066, 0x2069)]

/-- Draw scalar text from this alphabet, preserving embedded NULs. -/
def text (a : Alphabet) (minSize : Nat := 0) (maxSize : Nat := 64)
    (pattern : String := "") (regex : Bool := false) (fullMatch : Bool := true) : Gen String := do
  if minSize > maxSize || maxSize ≥ 2 ^ 64 then
    Gen.validation "text" "Alphabet.text: invalid size bounds"
  if a.minCodepoint > a.maxCodepoint || a.maxCodepoint > 0x10ffff then
    Gen.validation "text" "Alphabet.text: invalid Unicode bounds"
  if a.categories.isSome && !a.excludeCategories.isEmpty then
    Gen.validation "text" "Alphabet.text: categories and excludeCategories are mutually exclusive"
  Gen.nativeValidation "alphabet" (Internal.alphabet · minSize.toUInt64 maxSize.toUInt64
    a.codec.name
    a.minCodepoint.toUInt32 a.maxCodepoint.toUInt32
    ((a.categories.getD #[]).map GeneralCategory.code)
    (a.excludeCategories.map GeneralCategory.code) a.categories.isSome
    a.includeCharacters a.excludeCharacters pattern regex fullMatch)

def char (a : Alphabet) : Gen Char := do
  match (← a.text 1 1).toList with
  | [c] => return c
  | _ => Gen.invalid "Alphabet.char: engine did not return exactly one scalar"

def regex (a : Alphabet) (pattern : String) (fullMatch : Bool := true) : Gen String :=
  a.text 1 1 pattern true fullMatch

end Alphabet
end Hegel
