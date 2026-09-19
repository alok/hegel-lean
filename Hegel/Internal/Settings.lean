import Hegel.Internal.Raw

namespace Hegel.Internal

@[extern "lean_hegel_configure"]
opaque configure (session : @& Session.type) (backend verbosity : UInt32)
    (derandomize showStatistics unboundedChoices printBlob : Bool)
    (key : @& String) (hasKey : Bool) : EIO EngineError Unit

end Hegel.Internal
