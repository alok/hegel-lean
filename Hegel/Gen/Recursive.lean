import Hegel.Gen.Builder

namespace Hegel.Gen

structure RecursionContext where
  depth : Nat
  maxDepth : Nat
  deriving Repr, BEq

structure RecursiveBuilder (α : Type) where
  leaf : Gen α
  branch : RecursionContext → Gen α → Gen α
  depthLimit : Nat := 32
  leafLimit : Nat := 100

def maxDepth (limit : Nat) (b : RecursiveBuilder α) : RecursiveBuilder α :=
  { b with depthLimit := limit }

def maxLeaves (limit : Nat) (b : RecursiveBuilder α) : RecursiveBuilder α :=
  { b with leafLimit := limit }

private def recursionStep (id : UInt64) (kind : UInt32) (depth : Nat := 0) : Gen Bool :=
  Gen.ofRun fun s => (Internal.recursionAction s id kind depth.toUInt64).adapt fun e =>
    if e.code == -10 then
      if kind == 1 then .recursionLeafRetry else .recursionMispriced
    else if e.code == -1 then .overrun
    else if e.code == -2 then .discard
    else .error (toString e)

private def subtree (b : RecursiveBuilder α) (id : UInt64) (depth fuel : Nat) : Gen α :=
  Gen.ofRun fun session => do
    Gen.native (Internal.startSpan · "lean.recursive") session
    let result ← (do
      let branch ← recursionStep id 0 depth session
      let value ← if branch then
        match fuel with
        | 0 => throw (Abort.error "Engine exceeded the recursive depth limit")
        | fuel + 1 =>
          b.branch ⟨depth, b.depthLimit⟩ (subtree b id (depth + 1) fuel) session
      else do
        let _ ← recursionStep id 1 0 session
        b.leaf session
      if depth == 0 then
        let _ ← recursionStep id 3 0 session
        pure ()
      pure value).toBaseIO
    match result with
    | .ok value =>
      Gen.native (Internal.stopSpan · false) session
      return value
    | .error error =>
      match error with
      | .recursionLeafRetry | .recursionMispriced => pure ()
      | _ => let _ ← (Internal.stopSpan session true).toBaseIO; pure ()
      throw error

private instance : Nonempty (Gen α) := ⟨Gen.discard⟩

private partial def retryRecursion (b : RecursiveBuilder α) (id : UInt64) : Gen α :=
  Gen.ofRun fun session => do
    let result ← (subtree b id 0 b.depthLimit session).toBaseIO
    match result with
    | .ok value => return value
    | .error .recursionLeafRetry =>
      let _ ← recursionStep id 2 0 session
      retryRecursion b id session
    | .error .recursionMispriced => retryRecursion b id session
    | .error error => throw error

/-- Native recursion enforces both depth and a shared leaf budget across the whole value. -/
def recursiveNative (b : RecursiveBuilder α) : Gen α := do
  if b.depthLimit ≥ 2 ^ 64 || b.leafLimit ≥ 2 ^ 64 then
    validation "recursiveNative" "Gen.recursiveNative: bound exceeds UInt64"
  let id ← native (Internal.newRecursion · b.depthLimit.toUInt64 b.leafLimit.toUInt64)
  try retryRecursion b id
  finally native (Internal.freeRecursion · id)

instance : Build (RecursiveBuilder α) α := ⟨recursiveNative⟩

namespace Builder

def recursive (leaf : Gen α) (branch : RecursionContext → Gen α → Gen α) : RecursiveBuilder α :=
  ⟨leaf, branch, 32, 100⟩

end Builder
end Hegel.Gen
