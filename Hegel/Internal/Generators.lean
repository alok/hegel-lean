import Hegel.Internal.Raw

namespace Hegel.Internal

@[extern "lean_hegel_float32"]
opaque float32 (s : @& Session.type) (lo hi : Float) (nan infinity exclLo exclHi : Bool) :
    EIO EngineError Float

@[extern "lean_hegel_calendar"]
opaque calendar (s : @& Session.type) (kind : UInt32) (lo hi : @& Array Int) :
    EIO EngineError (Array Int)

@[extern "lean_hegel_uuid"]
opaque uuid (s : @& Session.type) (version : UInt8) (hasVersion : Bool) :
    EIO EngineError ByteArray

@[extern "lean_hegel_alphabet"]
opaque alphabet (s : @& Session.type) (lo hi : UInt64) (codec : @& String)
    (minChar maxChar : UInt32) (categories excludeCategories : @& Array String)
    (hasCategories : Bool) (includeChars excludeChars : @& String)
    (pattern : @& String) (regex fullMatch : Bool) : EIO EngineError String

@[extern "lean_hegel_recursion_new"]
opaque newRecursion (s : @& Session.type) (depth leaves : UInt64) : EIO EngineError UInt64
@[extern "lean_hegel_recursion_action"]
opaque recursionAction (s : @& Session.type) (id : UInt64) (kind : UInt32) (depth : UInt64) :
    EIO EngineError Bool
@[extern "lean_hegel_recursion_free"]
opaque freeRecursion (s : @& Session.type) (id : UInt64) : EIO EngineError Unit

end Hegel.Internal
