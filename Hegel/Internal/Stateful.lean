import Hegel.Internal.Raw

/-! Native handles for pools and engine-owned state-machine scheduling. -/
namespace Hegel.Internal

opaque PoolHandle : NonemptyType
instance : Nonempty PoolHandle.type := PoolHandle.property
opaque MachineHandle : NonemptyType
instance : Nonempty MachineHandle.type := MachineHandle.property

@[extern "lean_hegel_pool_new"]
opaque poolNew (s : @& Session.type) : EIO EngineError PoolHandle.type
@[extern "lean_hegel_pool_identity"]
opaque poolIdentity (p : @& PoolHandle.type) : BaseIO Nat
@[extern "lean_hegel_pool_close"]
opaque poolClose (p : @& PoolHandle.type) : EIO EngineError Unit
@[extern "lean_hegel_pool_add"]
opaque poolAdd {α : Type} (s : @& Session.type) (p : @& PoolHandle.type) (value : @& α) :
    EIO EngineError Int
@[extern "lean_hegel_pool_draw"]
opaque poolDraw {α : Type} (s : @& Session.type) (p : @& PoolHandle.type) (consume : Bool) :
    EIO EngineError α := throw ⟨-3, "native pool operation unavailable"⟩
@[extern "lean_hegel_pool_transfer"]
opaque poolTransfer {α : Type} (s : @& Session.type) (src dst : @& PoolHandle.type) :
    EIO EngineError α := throw ⟨-3, "native pool operation unavailable"⟩
@[extern "lean_hegel_pool_size"]
opaque poolSize (p : @& PoolHandle.type) : EIO EngineError Nat

@[extern "lean_hegel_machine_new"]
opaque machineNew (s : @& Session.type) (names : @& Array String) (groups : @& Array Int64)
    (weights : @& Array Float) (invariants : @& Array String) (always : @& Array Bool)
    (minWorkers maxWorkers steps : Int64) : EIO EngineError (MachineHandle.type × Nat)
@[extern "lean_hegel_machine_close"]
opaque machineClose (m : @& MachineHandle.type) : EIO EngineError Unit
@[extern "lean_hegel_machine_group"]
opaque machineGroup (s : @& Session.type) (m : @& MachineHandle.type) :
    EIO EngineError (Option Nat)
@[extern "lean_hegel_machine_rule"]
opaque machineRule (s : @& Session.type) (m : @& MachineHandle.type) (worker : UInt64) :
    EIO EngineError (Option Nat)
@[extern "lean_hegel_machine_rejected"]
opaque machineRejected (s : @& Session.type) (m : @& MachineHandle.type) (worker : UInt64) :
    EIO EngineError Unit
@[extern "lean_hegel_machine_invariant"]
opaque machineInvariant (s : @& Session.type) (m : @& MachineHandle.type) (index : UInt64) :
    EIO EngineError Bool

end Hegel.Internal
