import Hegel.Gen

/-! Scoped access to Hegel's collection primitive for custom container generators. -/
namespace Hegel

/-- Valid only inside `Collection.with`; completed collections remain idempotent. -/
structure Collection where
  private session : Internal.Session.type
  private handle : UInt64
  private finished : IO.Ref Bool
  private released : IO.Ref Bool

namespace Collection

/-- Ask whether to generate the next element. Once finished, this always returns false. -/
def more (collection : Collection) : Gen Bool := Gen.ofRun fun _ => do
  if ← collection.released.get then throw (.error "Collection.more: collection scope has ended")
  else if ← collection.finished.get then return false
  else
    let next ← Gen.native (Internal.more · collection.handle) collection.session
    unless next do collection.finished.set true
    return next

/-- Reject the previous element; a completed collection makes this a no-op. -/
def reject (collection : Collection) : Gen Unit := Gen.ofRun fun _ => do
  if ← collection.released.get then throw (.error "Collection.reject: collection scope has ended")
  else unless ← collection.finished.get do
    Gen.native (Internal.reject · collection.handle) collection.session

/-- Scope a custom collection and release it on success, rejection, or failure.
Generators rejecting duplicates should use a variable upper bound (`min < max`). -/
def «with» (min max : Nat) (action : Collection → Gen α) : Gen α := Gen.ofRun fun session => do
  if min > max || max > 18446744073709551615 then
    throw (.error "Collection.with: require 0 <= min <= max <= UInt64.max")
  let id ← Gen.native (Internal.collection · min.toUInt64 max.toUInt64) session
  let collection : Collection := ⟨session, id, ← IO.mkRef false, ← IO.mkRef false⟩
  try
    action collection session
  finally
    collection.released.set true
    Gen.native (Internal.freeCollection · id) session

end Collection
end Hegel
