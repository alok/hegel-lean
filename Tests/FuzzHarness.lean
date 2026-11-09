import Hegel
import Hegel.Stateful

/-! Differential fuzzing of the runner: random generator programs, random failure predicates.

A seeded Lean PRNG builds a generator program from combinators, then the runner checks a
property over it. Valid programs must never produce engine errors. A failing campaign must
replay deterministically: same origin and annotations on every replay, and through a portable
replay token. -/
namespace Tests.FuzzHarness
open Hegel Hegel.Property

inductive V where
  | int (n : Int)
  | bool (b : Bool)
  | str (s : String)
  | list (xs : List V)
  | pair (a b : V)
  deriving Repr, BEq, Inhabited, Hashable

partial def V.weight : V → Nat
  | .int n => n.natAbs % 1000
  | .bool b => if b then 1 else 0
  | .str s => s.length
  | .list xs => xs.length + (xs.map V.weight).sum
  | .pair a b => a.weight + b.weight

inductive Prog where
  | int (lo hi : Int)
  | bool
  | text (lo hi : Nat) (alpha : Option String)
  | bytes (lo hi : Nat)
  | list (p : Prog) (lo hi : Nat)
  | unique (p : Prog) (lo hi : Nat)
  | set (p : Prog) (lo hi : Nat)
  | pair (a b : Prog)
  | oneOf (ps : List Prog)
  | filter (p : Prog) (k : Nat)
  | mapMaybe (p : Prog) (k : Nat)
  | bind (p : Prog) (k : Nat)
  | float (lo hi : Float)
  | element (n : Nat)
  | span (p : Prog)
  | option (p : Prog)
  | collection (p : Prog) (lo hi : Nat) (rejectEvery : Nat)
  | frequency (ps : List (Nat × Prog))
  | date
  | float32 (lo hi : Float)
  | regex (pattern : String)
  | category (cats : List GeneralCategory) (lo hi : Nat)
  | recursive (p : Prog) (depth : Nat)
  | entries (k v : Prog) (lo hi : Nat)
  deriving Repr, Inhabited

partial def Prog.gen : Prog → Gen V
  | .int lo hi => V.int <$> Gen.int lo hi
  | .bool => V.bool <$> Gen.bool
  | .text lo hi none => V.str <$> Gen.text { minSize := lo, maxSize := hi }
  | .text lo hi (some a) => V.str <$> Alphabet.text (Alphabet.only a) lo hi
  | .bytes lo hi => (fun b => V.list (b.toList.map (V.int ·.toNat))) <$> Gen.bytes lo hi
  | .list p lo hi => V.list <$> Gen.list p.gen lo hi
  | .unique p lo hi => (V.list ·.toList) <$> Gen.uniqueArray p.gen lo hi
  | .set p lo hi => (fun s => V.list (s.toList.map V.int)) <$>
      Gen.set ((fun v => (v.weight : Int)) <$> p.gen) lo hi
  | .pair a b => V.pair <$> a.gen <*> b.gen
  | .oneOf ps => Gen.oneOf (ps.map Prog.gen).toArray
  | .filter p k => Gen.filter (fun v => v.weight % (k + 2) != 0) p.gen
  | .mapMaybe p k => Gen.mapMaybe (fun v => if v.weight % (k + 2) == 1 then none else some v) p.gen
  | .bind p k => do
      let v ← p.gen
      let n := v.weight % (k + 3)
      V.list <$> Gen.list (V.int <$> Gen.int 0 n) 0 n
  | .float lo hi => (fun f => V.int (f.floor.toInt64.toInt)) <$>
      Gen.float { min := lo, max := hi, allowNaN := false, allowInfinity := false }
  | .element n => V.int <$> Gen.element ((List.range (n + 1)).map Int.ofNat).toArray
  | .span p => Gen.withSpan "fuzz.span" p.gen
  | .option p => (fun o => match o with | none => V.bool false | some v => V.pair (.bool true) v) <$>
      Gen.option p.gen
  | .collection p lo hi r => Collection.with lo hi fun c => do
      let mut out := #[]
      let mut i := 0
      while ← c.more do
        let v ← p.gen
        i := i + 1
        if r > 0 && i % (r + 1) == 0 && lo < hi then c.reject
        else out := out.push v
      return V.list out.toList
  | .frequency ps => Gen.frequency (ps.map fun (w, p) => (w + 1, p.gen)).toArray
  | .date => (fun (d : Date) => V.int d.year) <$> Gen.date ⟨1900, 1, 1⟩ ⟨2100, 12, 31⟩
  | .float32 lo hi => (fun f => V.int (f.toFloat.floor.toInt64.toInt)) <$>
      Gen.float32 { min := lo, max := hi, allowNaN := false, allowInfinity := false }
  | .regex pattern => V.str <$> Gen.regex pattern
  | .category cats lo hi => V.str <$> Alphabet.text { categories := some cats.toArray } lo hi
  | .recursive p depth => Gen.recursive depth p.gen fun child => (V.list [·, ·]) <$> child <*> child
  | .entries k v lo hi => (fun es => V.list (es.toList.map fun (a, b) => V.pair a b)) <$>
      Gen.entries (· == ·) k.gen v.gen lo hi

/-- Tiny deterministic PRNG (SplitMix64) so every program is reproducible from its seed. -/
structure Rng where
  state : UInt64

def Rng.next (r : Rng) : UInt64 × Rng :=
  let s := r.state + 0x9e3779b97f4a7c15
  let z := (s ^^^ (s >>> 30)) * 0xbf58476d1ce4e5b9
  let z := (z ^^^ (z >>> 27)) * 0x94d049bb133111eb
  (z ^^^ (z >>> 31), ⟨s⟩)

abbrev R := StateM Rng

def below (n : Nat) : R Nat := do
  let (x, r) := (← get).next
  set r
  return if n == 0 then 0 else x.toNat % n

def pick (xs : Array α) [Inhabited α] : R α := return xs[← below xs.size]!

def size : R (Nat × Nat) := do
  let lo ← below 4
  return (lo, lo + (← below 5))

def bigInt : R Int := do
  match ← below 4 with
  | 0 => return (← below 21 : Nat) - 10
  | 1 => return ((← below 2000 : Nat) : Int) - 1000
  | 2 => return (if ← (· == 0) <$> below 2 then -1 else 1) * ((2 : Int) ^ (← below 140) + (← below 5 : Nat) - 2)
  | _ => pick #[-(2 ^ 63), 2 ^ 63 - 1, 2 ^ 63, -(2 ^ 63) - 1, 2 ^ 64, 0]

partial def prog (depth : Nat) : R Prog := do
  let leaf := depth == 0
  match ← below (if leaf then 6 else 24) with
  | 0 => let a ← bigInt; let b ← bigInt; return .int (min a b) (max a b)
  | 1 => return .bool
  | 2 => let (lo, hi) ← size; return .text lo hi (← pick #[none, some "ab", some ":\\\"\x00é😀", some "x"])
  | 3 => let (lo, hi) ← size; return .bytes lo hi
  | 4 => return .element (← below 5)
  | 5 => return .float (← pick #[-1.0, 0.0, -1e300, 5e-324]) (← pick #[1.0, 1e300, 5e-324, 0.0, 2.5])
  | 6 => let (lo, hi) ← size; return .list (← prog (depth - 1)) lo hi
  | 7 => let (lo, hi) ← size; return .unique (← prog (depth - 1)) lo hi
  | 8 => return .pair (← prog (depth - 1)) (← prog (depth - 1))
  | 9 => return .oneOf (← (List.range ((← below 3) + 1)).mapM fun _ => prog (depth - 1))
  | 10 => return .filter (← prog (depth - 1)) (← below 4)
  | 11 => return .mapMaybe (← prog (depth - 1)) (← below 4)
  | 12 => return .bind (← prog (depth - 1)) (← below 5)
  | 13 => return .span (← prog (depth - 1))
  | 14 => return .option (← prog (depth - 1))
  | 15 => let (lo, hi) ← size; return .collection (← prog (depth - 1)) lo hi (← below 3)
  | 16 => return .frequency (← (List.range ((← below 3) + 1)).mapM fun _ => do
      return (← below 4, ← prog (depth - 1)))
  | 17 => let (lo, hi) ← size; return .set (← prog (depth - 1)) lo hi
  | 18 => return .recursive (← prog (depth - 1)) (← below 4)
  | 19 => let (lo, hi) ← size; return .entries (← prog (depth - 1)) (← prog (depth - 1)) lo hi
  | 20 => return .float32 (← pick #[-1.0, 0.0, -3.4e38, 1.401298464324817e-45]) (← pick #[1.0, 3.4e38, 0.0, 2.5])
  | 21 => return .regex (← pick #["[a-c]{0,3}", "x|yz", "\\d+", "(ab)*c?", "[^a]", "a\\x00b", "\\w{2}@\\w"])
  | 22 => let (lo, hi) ← size; return .category (← pick #[[.Lu], [.Nd, .Ll], [.Zs], [.Sm, .So]]) lo hi
  | _ => return .date

/-- The program's own float bounds can be reversed; fix them so every program is valid. -/
partial def Prog.normalize : Prog → Prog
  | .float lo hi => if lo ≤ hi then .float lo hi else .float hi lo
  | .list p lo hi => .list p.normalize lo hi
  | .unique p lo hi => .unique p.normalize lo hi
  | .set p lo hi => .set p.normalize lo hi
  | .pair a b => .pair a.normalize b.normalize
  | .oneOf ps => .oneOf (ps.map normalize)
  | .filter p k => .filter p.normalize k
  | .mapMaybe p k => .mapMaybe p.normalize k
  | .bind p k => .bind p.normalize k
  | .span p => .span p.normalize
  | .option p => .option p.normalize
  | .collection p lo hi r => .collection p.normalize lo hi r
  | .frequency ps => .frequency (ps.map fun (w, p) => (w, p.normalize))
  | .float32 lo hi => if lo ≤ hi then .float32 lo hi else .float32 hi lo
  | .recursive p d => .recursive p.normalize d
  | .entries k v lo hi => .entries k.normalize v.normalize lo hi
  | p => p

inductive Verdict where
  | passed | replayed | exhausted
  | bug (detail : String)

private def checkReport (report : Report) (property : Property Unit) (settings : Settings)
    (shown : String.Slice) : IO Verdict := do
  match report.outcome with
  | .passed => return .passed
  | .error =>
    if report.cleanupDiagnostics.isEmpty && report.failures.isEmpty &&
        (report.message.startsWith "FailedHealthCheck: FilterTooMuch" ||
         report.message.startsWith "Unsatisfiable:") then return .exhausted
    return .bug s!"engine/runner error for {shown}\n{report.render}"
  | .nondeterministic => return .bug s!"nondeterministic for {shown}\n{report.render}"
  | .failed =>
    if report.failures.isEmpty then return .bug s!"no failure evidence for {shown}"
    for f in report.failures do
      let some token ← f.replayToken | return .bug s!"failure without replay data for {shown}"
      for _ in [:3] do
        let again ← replay f.blob property settings
        if again.status != .failed || again.origin != f.origin ||
            again.annotations != f.annotations || !again.cleanupDiagnostics.isEmpty then
          return .bug s!"replay diverged for {shown}\n{repr again.status} {again.message}"
      match decodeReplayToken (encodeReplayToken token) with
      | .error e => return .bug s!"token decode {repr e}"
      | .ok decoded =>
        let r ← replayToken decoded property settings
        if r.outcome != .failed || !r.failures.any (fun reproduced =>
            reproduced.origin == f.origin && reproduced.annotations == f.annotations) then
          return .bug s!"token replay diverged for {shown}\n{r.render}"
    return .replayed

def runOne (seed : Nat) (examples : Nat) : IO Verdict := do
  let (p, rng) := (prog 3).run ⟨seed.toUInt64 * 7919 + 1⟩
  let p := p.normalize
  let (threshold, _) := (below 12).run rng
  let gen := p.gen
  let (shape, _) := (below 7).run rng
  let drawOne : Property V := forAll gen "value"
  let property : Property Unit := do
    let v ← match shape with
      | 4 => do
        let f ← Hegel.Property.Fork.spawn drawOne
        -- Settle the fork even when the parent's draw aborts; see `Fork.spawn`.
        let w ← try drawOne catch e => do
          (try discard (Hegel.Property.Fork.join f) catch _ => pure ())
          throw e
        pure (V.pair (← Hegel.Property.Fork.join f) w)
      | 5 => V.list <$> (Array.toList <$> Hegel.Property.Branch.mapConcurrently (fun _ => drawOne) #[0, 1, 2])
      | 6 => do
        let (a, b) ← Hegel.Property.Branch.concurrently drawOne drawOne
        pure (V.pair a b)
      | _ => drawOne
    let w ← forAll (Gen.int 0 5) "extra"
    if shape == 1 then assume (v.weight % 5 != 4)
    if shape == 2 then target (v.weight.toFloat) "weight"
    let total := v.weight + w.toNat
    if shape == 3 && total ≥ threshold + 3 then
      failure s!"fuzz/weight-mod-{total % 3}" s!"weight {v.weight}"
    assertThat (total < threshold + 3) "fuzz/weight" s!"weight {v.weight}"
  let settings : Settings := { seed := some seed.toUInt64, maxExamples := examples.toUInt64, database := none }
  let report ← check s!"program {seed}" property settings
  let shown := (reprStr p).take 600
  checkReport report property settings shown

/-! ## Random state machines -/

inductive RuleKind where
  | push (p : Prog)
  | pop
  | popAssume
  | clear
  | buggy (limit : Nat)
  deriving Repr, Inhabited

def ruleKind (depth : Nat) : R RuleKind := do
  match ← below 5 with
  | 0 => return .push (← prog depth)
  | 1 => return .pop
  | 2 => return .popAssume
  | 3 => return .clear
  | _ => return .buggy (← below 30)

def ruleBody (i : Nat) : RuleKind → List V → Property (List V)
  | .push p, stack => do
    let v ← forAll p.gen "pushed"
    Stateful.respondShow v.weight
    return v :: stack
  | .pop, stack => return stack.drop 1
  | .popAssume, stack => do
    assume (!stack.isEmpty)
    return stack.drop 1
  | .clear, _ => return []
  | .buggy limit, stack => do
    assertThat ((stack.map V.weight).sum < limit + 5) s!"stack/r{i}" "stack too heavy"
    return stack

def depthInvariant (n : Nat) : Stateful.Invariant (List V) where
  name := "depth"
  check stack := assertThat (stack.length < n + 2) "stack/depth" "stack too deep"

def machineOf (kinds : List (RuleKind × Nat)) (invLimit : Option Nat) (steps : Nat) :
    Stateful.Machine (List V) where
  initial := pure []
  rules := kinds.toArray.mapIdx fun i (k, w) => ⟨s!"r{i}", ruleBody i k, (w + 1).toFloat⟩
  invariants := (invLimit.map depthInvariant).toArray
  stepCount := some steps

def runMachine (seed : Nat) (examples : Nat) : IO Verdict := do
  let gen : R (List (RuleKind × Nat) × Option Nat × Nat) := do
    let n := (← below 4) + 1
    let kinds ← (List.range n).mapM fun _ => return (← ruleKind 2, ← below 3)
    let inv ← if (← below 2) == 0 then pure none else some <$> below 8
    return (kinds, inv, (← below 20) + 1)
  let ((kinds, inv, steps), _) := gen.run ⟨seed.toUInt64 * 104729 + 7⟩
  let kinds := kinds.map fun (k, w) => match k with
    | .push p => (.push p.normalize, w)
    | k => (k, w)
  let property := Stateful.run (machineOf kinds inv steps)
  let settings : Settings := { seed := some seed.toUInt64, maxExamples := examples.toUInt64, database := none }
  let report ← check s!"machine {seed}" property settings
  let shown := (reprStr (kinds, inv, steps)).take 600
  checkReport report property settings shown

end Tests.FuzzHarness

