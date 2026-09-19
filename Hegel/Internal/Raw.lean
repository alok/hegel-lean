/-! Thin bindings to libhegel. Import `Hegel` for the public API. -/
namespace Hegel.Internal

structure EngineError where
  code : Int
  message : String
  deriving Repr

instance : ToString EngineError where
  toString e := s!"libhegel ({e.code}): {e.message}"

opaque Session : NonemptyType
instance : Nonempty Session.type := Session.property

structure NativeResult where
  status : Nat
  message : String
  failures : Array (String × String)
  deriving Repr, Inhabited

@[extern "lean_hegel_open"]
opaque openSession (cases seed : UInt64) (hasSeed : Bool) (database key : @& String)
    (multiple : Bool) (phases suppress : UInt32) : EIO EngineError Session.type

@[extern "lean_hegel_start_run"]
opaque startRun (s : @& Session.type) : EIO EngineError Unit
@[extern "lean_hegel_clone"]
opaque clone (s : @& Session.type) : EIO EngineError Session.type

@[extern "lean_hegel_close"]
opaque close (s : @& Session.type) : EIO EngineError Unit
@[extern "lean_hegel_next"]
opaque next (s : @& Session.type) : EIO EngineError Bool
@[extern "lean_hegel_complete"]
opaque complete (s : @& Session.type) (status : UInt32) (origin : @& String) : EIO EngineError Unit
@[extern "lean_hegel_result"]
opaque result (s : @& Session.type) : EIO EngineError NativeResult
@[extern "lean_hegel_replay"]
opaque replay (s : @& Session.type) (blob : @& String) : EIO EngineError Unit
@[extern "lean_hegel_version"]
opaque version : EIO EngineError String

@[extern "lean_hegel_boolean"]
opaque boolean (s : @& Session.type) (probability : Float) : EIO EngineError Bool
@[extern "lean_hegel_integer"]
opaque integer (s : @& Session.type) (lo hi : Int64) : EIO EngineError Int
@[extern "lean_hegel_integer_big"]
opaque integerBig (s : @& Session.type) (lo hi : @& ByteArray) : EIO EngineError ByteArray
@[extern "lean_hegel_float"]
opaque float (s : @& Session.type) (lo hi : Float) (nan infinity exclLo exclHi : Bool) :
    EIO EngineError Float
@[extern "lean_hegel_bytes"]
opaque bytes (s : @& Session.type) (lo hi : UInt64) : EIO EngineError ByteArray
@[extern "lean_hegel_text"]
opaque text (s : @& Session.type) (lo hi : UInt64) (minChar maxChar : UInt32)
    (codec : @& String) : EIO EngineError String
@[extern "lean_hegel_string"]
opaque string (s : @& Session.type) (kind : UInt32) (arg : @& String) (flag : Bool)
    (limit : UInt64) : EIO EngineError String

@[extern "lean_hegel_start_span"]
opaque startSpan (s : @& Session.type) (label : @& String) : EIO EngineError Unit
@[extern "lean_hegel_stop_span"]
opaque stopSpan (s : @& Session.type) (discard : Bool) : EIO EngineError Unit
@[extern "lean_hegel_collection"]
opaque collection (s : @& Session.type) (lo hi : UInt64) : EIO EngineError UInt64
@[extern "lean_hegel_more"]
opaque more (s : @& Session.type) (id : UInt64) : EIO EngineError Bool
@[extern "lean_hegel_reject"]
opaque reject (s : @& Session.type) (id : UInt64) : EIO EngineError Unit
@[extern "lean_hegel_collection_free"]
opaque freeCollection (s : @& Session.type) (id : UInt64) : EIO EngineError Unit
@[extern "lean_hegel_target"]
opaque target (s : @& Session.type) (score : Float) (label : @& String) : EIO EngineError Unit

structure NativePoolEvent where
  kind : Nat
  pool : Nat
  index : Nat
  sourcePool : Nat
  sourceIndex : Nat
  deriving Repr

@[extern "lean_hegel_drain_pool_events"]
opaque drainPoolEvents (s : @& Session.type) : EIO EngineError (Array NativePoolEvent)

@[extern "lean_hegel_output"]
opaque output (s : @& Session.type) : EIO EngineError String

end Hegel.Internal
