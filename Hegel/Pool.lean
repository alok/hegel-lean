import Hegel.Property
import Hegel.Internal.Stateful

/-! Engine-managed reusable values. Pools live for one test-case family, including its workers. -/
namespace Hegel

/-- A typed, thread-safe pool. Values retain the engine's stable variable identities. -/
structure Pool (α : Type) where
  private handle : Internal.PoolHandle.type
  label : String := "pool"

namespace Pool

private def release (handle : Internal.PoolHandle.type) : IO Unit :=
  (Internal.poolClose handle).toIO (IO.userError ∘ toString)

/-- Allocate in a property body or machine setup; rules may use existing pools. -/
def named (label : String) : Property (Pool α) := do
  let ctx ← Property.getContext
  if ctx.scope == .inStep then
    throw (.error "Pool.named: allocate pools in machine initial or the property body")
  let handle ← Property.draw (Gen.native Internal.poolNew)
  Property.registerFinalizer (release handle)
  Property.labelPool (← Internal.poolIdentity handle) label
  Property.annotate s!"Pool {label} created"
  return ⟨handle, label⟩

def new : Property (Pool α) := named "pool"

/-- Register a value under a fresh native identity. -/
def add (pool : Pool α) (value : α) : Property Unit := do
  let id ← Property.draw (Gen.native (Internal.poolAdd · pool.handle value))
  Property.annotate s!"{pool.label}[{id}] added"

/-- Live size; a released pool reports an error instead of a stale count. -/
def size (pool : Pool α) : IO Nat :=
  (Internal.poolSize pool.handle).toIO (IO.userError ∘ toString)

def isEmpty (pool : Pool α) : IO Bool := (· == 0) <$> pool.size

/-- Draw without removing the value; empty pools reject the current rule or case. -/
def reuse (pool : Pool α) : Gen α := Gen.native (Internal.poolDraw · pool.handle false)

/-- Draw and remove a value. -/
def consume (pool : Pool α) : Gen α := Gen.native (Internal.poolDraw · pool.handle true)

/-- Move one engine-selected value into another pool. Locks both pools in a stable order.
The consume and add are separate engine operations: an engine stop can interrupt the move. -/
def transfer (src dst : Pool α) : Gen α :=
  Gen.native (Internal.poolTransfer · src.handle dst.handle)

end Pool
end Hegel
