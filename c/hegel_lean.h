#ifndef HEGEL_LEAN_H
#define HEGEL_LEAN_H
#include <lean/lean.h>
#include <hegel.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct hegel_lean_session session;
session *hegel_lean_get_session(b_lean_obj_arg handle);
/* NULL on success, otherwise an owned Lean EIO error result. */
lean_object *hegel_lean_check_session(session *s, bool require_case);
hegel_context_t *hegel_lean_context(session *s);
hegel_settings_t *hegel_lean_settings(session *s);
hegel_test_case_t *hegel_lean_test_case(session *s);
uint64_t hegel_lean_family(session *s);
lean_object *hegel_lean_error(int code, const char *message);
lean_object *hegel_lean_error_value(int code, const char *message);
lean_object *hegel_lean_engine_error(session *s, hegel_result_t rc);
lean_object *hegel_lean_unit_ok(void);
uint64_t hegel_lean_register_resource(session *s, void *resource,
    void (*release)(hegel_context_t *, void *));
void *hegel_lean_get_resource(session *s, uint64_t id);
hegel_result_t hegel_lean_free_resource(session *s, uint64_t id);
void hegel_lean_record_pool_event(session *s, uint32_t kind, uint64_t pool, uint64_t index,
    uint64_t source_pool, uint64_t source_index);
uint64_t hegel_lean_fresh_pool_id(session *s);
#endif
