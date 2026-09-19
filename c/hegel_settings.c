#include "hegel_lean.h"
#include <stdlib.h>
#include <string.h>

LEAN_EXPORT lean_obj_res lean_hegel_configure(b_lean_obj_arg handle,
    uint32_t backend, uint32_t verbosity, uint8_t derandomize,
    uint8_t show_statistics, uint8_t unbounded_choices, uint8_t print_blob,
    b_lean_obj_arg key, uint8_t has_key) {
    session *s = hegel_lean_get_session(handle);
    lean_object *error = hegel_lean_check_session(s, false);
    if (error) return error;
    hegel_context_t *ctx = hegel_lean_context(s);
    hegel_settings_t *settings = hegel_lean_settings(s);
    if (has_key && memchr(lean_string_cstr(key), 0, lean_string_size(key) - 1))
        return hegel_lean_error(HEGEL_E_INVALID_ARG, "Embedded NUL in database key");
    /* The pinned C API has two backends. Automatic selection follows its SDK environment. */
    if (backend == 0)
        backend = getenv("ANTITHESIS_OUTPUT_DIR") ? HEGEL_BACKEND_URANDOM : HEGEL_BACKEND_DEFAULT;
#define SET(expr) do { hegel_result_t rc = (expr); \
    if (rc != HEGEL_OK) return hegel_lean_engine_error(s, rc); } while (0)
    SET(hegel_settings_set_backend(ctx, settings, backend));
    SET(hegel_settings_set_verbosity(ctx, settings, verbosity));
    SET(hegel_settings_set_derandomize(ctx, settings, derandomize));
    SET(hegel_settings_set_show_statistics(ctx, settings, show_statistics));
    SET(hegel_settings_set_unbounded_choices(ctx, settings, unbounded_choices));
    SET(hegel_settings_set_print_blob(ctx, settings, print_blob));
    if (has_key) SET(hegel_settings_set_database_key(ctx, settings, lean_string_cstr(key)));
#undef SET
    return hegel_lean_unit_ok();
}
