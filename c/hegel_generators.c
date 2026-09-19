#include "hegel_lean.h"
#include <float.h>
#include <stdlib.h>
#include <string.h>

#define CASE() \
    session *s = hegel_lean_get_session(handle); \
    lean_object *err = hegel_lean_check_session(s, true); \
    if (err) return err; \
    hegel_context_t *ctx = hegel_lean_context(s); \
    hegel_test_case_t *tc = hegel_lean_test_case(s)
#define CHECK(expr) do { hegel_result_t rc = (expr); \
    if (rc != HEGEL_OK) return hegel_lean_engine_error(s, rc); } while (0)
#define CSTRING(str) do { \
    if (memchr(lean_string_cstr(str), 0, lean_string_size(str) - 1)) \
        return hegel_lean_error(HEGEL_E_INVALID_ARG, "Embedded NUL in C-string argument"); \
} while (0)

LEAN_EXPORT lean_obj_res lean_hegel_float32(b_lean_obj_arg handle, double lo, double hi,
    uint8_t nan, uint8_t infinity, uint8_t excl_lo, uint8_t excl_hi) {
    CASE();
    double out;
    CHECK(hegel_generate_float(ctx, tc, 32, lo, hi, nan, infinity, excl_lo, excl_hi,
        (double)FLT_TRUE_MIN, &out));
    return lean_io_result_mk_ok(lean_box_float(out));
}

static bool in_range(b_lean_obj_arg value, int64_t lo, int64_t hi) {
    lean_object *lower = lean_int64_to_int(lo), *upper = lean_int64_to_int(hi);
    bool valid = lean_int_dec_le(lower, value) && lean_int_dec_le(value, upper);
    lean_dec(lower); lean_dec(upper);
    return valid;
}
static bool valid_calendar_fields(b_lean_obj_arg fields, uint32_t kind) {
    size_t offset = 0;
    if (kind != 1) {
        if (!in_range(lean_array_get_core(fields, 0), -999999, 999999) ||
            !in_range(lean_array_get_core(fields, 1), 1, 12) ||
            !in_range(lean_array_get_core(fields, 2), 1, 31)) return false;
        offset = 3;
    }
    if (kind != 0) {
        if (!in_range(lean_array_get_core(fields, offset), 0, 23) ||
            !in_range(lean_array_get_core(fields, offset + 1), 0, 59) ||
            !in_range(lean_array_get_core(fields, offset + 2), 0, 59) ||
            !in_range(lean_array_get_core(fields, offset + 3), 0, 999999999)) return false;
    }
    return true;
}
static int64_t field(b_lean_obj_arg arr, size_t i) {
    return lean_int64_of_int(lean_array_get_core(arr, i));
}
static hegel_date_t date_fields(b_lean_obj_arg arr) {
    return (hegel_date_t){(int32_t)field(arr, 0), (uint8_t)field(arr, 1),
        (uint8_t)field(arr, 2)};
}
static hegel_time_t time_fields(b_lean_obj_arg arr, size_t i) {
    return (hegel_time_t){(uint8_t)field(arr, i), (uint8_t)field(arr, i + 1),
        (uint8_t)field(arr, i + 2), (uint32_t)field(arr, i + 3)};
}
static lean_object *push(lean_object *arr, int64_t n) {
    return lean_array_push(arr, lean_int64_to_int(n));
}
static lean_object *push_date(lean_object *arr, hegel_date_t d) {
    return push(push(push(arr, d.year), d.month), d.day);
}
static lean_object *push_time(lean_object *arr, hegel_time_t t) {
    return push(push(push(push(arr, t.hour), t.minute), t.second), t.nanosecond);
}
LEAN_EXPORT lean_obj_res lean_hegel_calendar(b_lean_obj_arg handle, uint32_t kind,
    b_lean_obj_arg lo, b_lean_obj_arg hi) {
    CASE();
    size_t size = kind == 0 ? 3 : kind == 1 ? 4 : 7;
    if (kind > 2 || lean_array_size(lo) != size || lean_array_size(hi) != size)
        return hegel_lean_error(HEGEL_E_INVALID_ARG, "Invalid calendar payload");
    if (!valid_calendar_fields(lo, kind) || !valid_calendar_fields(hi, kind))
        return hegel_lean_error(HEGEL_E_INVALID_ARG, "Calendar field is out of range");
    lean_object *arr;
    if (kind == 0) {
        hegel_date_t out;
        CHECK(hegel_generate_date(ctx, tc, date_fields(lo), date_fields(hi), &out));
        arr = push_date(lean_mk_empty_array_with_capacity(lean_box(size)), out);
    } else if (kind == 1) {
        hegel_time_t out;
        CHECK(hegel_generate_time(ctx, tc, time_fields(lo, 0), time_fields(hi, 0), &out));
        arr = push_time(lean_mk_empty_array_with_capacity(lean_box(size)), out);
    } else {
        hegel_datetime_t out;
        hegel_datetime_t a = {date_fields(lo), time_fields(lo, 3)};
        hegel_datetime_t b = {date_fields(hi), time_fields(hi, 3)};
        CHECK(hegel_generate_datetime(ctx, tc, a, b, &out));
        arr = push_time(push_date(lean_mk_empty_array_with_capacity(lean_box(size)),
            out.date), out.time);
    }
    return lean_io_result_mk_ok(arr);
}

LEAN_EXPORT lean_obj_res lean_hegel_uuid(b_lean_obj_arg handle, uint8_t version,
    uint8_t has_version) {
    CASE();
    uint8_t data[16];
    CHECK(hegel_generate_uuid(ctx, tc, version, has_version, data));
    lean_object *out = lean_alloc_sarray(1, 16, 16);
    memcpy(lean_sarray_cptr(out), data, 16);
    return lean_io_result_mk_ok(out);
}

LEAN_EXPORT lean_obj_res lean_hegel_alphabet(b_lean_obj_arg handle, uint64_t lo, uint64_t hi,
    b_lean_obj_arg codec, uint32_t min_char, uint32_t max_char,
    b_lean_obj_arg categories, b_lean_obj_arg excluded, uint8_t has_categories,
    b_lean_obj_arg included_chars, b_lean_obj_arg excluded_chars,
    b_lean_obj_arg pattern, uint8_t regex, uint8_t full_match) {
    CASE(); CSTRING(codec); CSTRING(pattern);
    size_t nc = lean_array_size(categories), ne = lean_array_size(excluded);
    for (size_t i = 0; i < nc; i++) { CSTRING(lean_array_get_core(categories, i)); }
    for (size_t i = 0; i < ne; i++) { CSTRING(lean_array_get_core(excluded, i)); }
    const char **cats = calloc(nc + 1, sizeof(char *));
    const char **excs = calloc(ne + 1, sizeof(char *));
    if (!cats || !excs) {
        free(cats); free(excs);
        return hegel_lean_error(HEGEL_E_INTERNAL, "Could not allocate category arrays");
    }
    for (size_t i = 0; i < nc; i++) cats[i] = lean_string_cstr(lean_array_get_core(categories, i));
    for (size_t i = 0; i < ne; i++) excs[i] = lean_string_cstr(lean_array_get_core(excluded, i));
    hegel_string_generator_t *alphabet = NULL, *generator = NULL;
    hegel_generate_string_result_t result = {0};
    hegel_result_t rc = hegel_string_generator_text(ctx, lo, hi, lean_string_cstr(codec),
        min_char, max_char, has_categories ? cats : NULL, nc, excs, ne,
        (const uint8_t *)lean_string_cstr(included_chars), lean_string_size(included_chars) - 1,
        (const uint8_t *)lean_string_cstr(excluded_chars), lean_string_size(excluded_chars) - 1,
        &alphabet);
    free(cats); free(excs);
    if (rc != HEGEL_OK) goto done;
    if (regex) {
        rc = hegel_string_generator_regex(ctx, lean_string_cstr(pattern), full_match,
            alphabet, &generator);
        if (rc != HEGEL_OK) goto done;
    }
    rc = hegel_generate_string(ctx, tc, regex ? generator : alphabet, &result);
 done:;
    lean_object *out = rc == HEGEL_OK
        ? lean_io_result_mk_ok(lean_mk_string_from_bytes(result.data, result.len))
        : hegel_lean_engine_error(s, rc);
    hegel_generate_string_result_free(ctx, &result);
    if (generator) hegel_string_generator_free(ctx, generator);
    if (alphabet) hegel_string_generator_free(ctx, alphabet);
    return out;
}

static void free_recursion(hegel_context_t *ctx, void *value) {
    hegel_recursion_free(ctx, value);
}
LEAN_EXPORT lean_obj_res lean_hegel_recursion_new(b_lean_obj_arg handle,
    uint64_t depth, uint64_t leaves) {
    CASE();
    HegelRecursion *recursion = NULL;
    CHECK(hegel_new_recursion(ctx, tc, depth, leaves, &recursion));
    uint64_t id = hegel_lean_register_resource(s, recursion, free_recursion);
    if (id == 0) {
        hegel_recursion_free(ctx, recursion);
        return hegel_lean_error(HEGEL_E_INTERNAL, "Could not register recursion handle");
    }
    return lean_io_result_mk_ok(lean_box_uint64(id));
}
LEAN_EXPORT lean_obj_res lean_hegel_recursion_action(b_lean_obj_arg handle,
    uint64_t id, uint32_t kind, uint64_t depth) {
    CASE();
    HegelRecursion *recursion = hegel_lean_get_resource(s, id);
    if (!recursion) return hegel_lean_error(HEGEL_E_INVALID_HANDLE, "Unknown recursion handle");
    bool branch = false;
    switch (kind) {
    case 0: CHECK(hegel_recursion_branch(ctx, tc, recursion, depth, &branch)); break;
    case 1: CHECK(hegel_recursion_leaf(ctx, tc, recursion)); break;
    case 2: CHECK(hegel_recursion_retry(ctx, tc, recursion)); break;
    case 3: CHECK(hegel_recursion_finish(ctx, tc, recursion)); break;
    default: return hegel_lean_error(HEGEL_E_INVALID_ARG, "Invalid recursion action");
    }
    return lean_io_result_mk_ok(lean_box(branch));
}
LEAN_EXPORT lean_obj_res lean_hegel_recursion_free(b_lean_obj_arg handle, uint64_t id) {
    session *s = hegel_lean_get_session(handle);
    lean_object *err = hegel_lean_check_session(s, false);
    if (err) return err;
    hegel_result_t rc = hegel_lean_free_resource(s, id);
    return rc == HEGEL_OK ? hegel_lean_unit_ok() : hegel_lean_engine_error(s, rc);
}
