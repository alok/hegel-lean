/* Engine-owned pools and state machines; each resource owns its cleanup context. */
#include "hegel_lean.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define ACTIVE() \
    session *s = hegel_lean_get_session(handle); \
    lean_object *err_ = hegel_lean_check_session(s, true); \
    if (err_) return err_
#define CALL(expr) do { hegel_result_t rc_ = (expr); \
    if (rc_ != HEGEL_OK) return hegel_lean_engine_error(s, rc_); } while (0)

typedef struct pool_entry {
    int64_t id;
    lean_object *value;
    struct pool_entry *next;
} pool_entry;
typedef struct {
    hegel_context_t *cleanup;
    hegel_pool_t *ptr;
    uint64_t family;
    uint64_t identity;
    pthread_mutex_t lock;
    pool_entry *entries;
    size_t size;
} pool_handle;
typedef struct {
    hegel_context_t *cleanup;
    hegel_state_machine_t *ptr;
    uint64_t family;
} machine_handle;

static void pool_release(pool_handle *p) {
    if (p->ptr) hegel_pool_free(p->cleanup, p->ptr);
    p->ptr = NULL;
    while (p->entries) {
        pool_entry *e = p->entries;
        p->entries = e->next;
        lean_dec(e->value);
        free(e);
    }
    p->size = 0;
}
static void pool_finalize(void *data) {
    pool_handle *p = data;
    pool_release(p);
    hegel_context_free(p->cleanup);
    pthread_mutex_destroy(&p->lock);
    free(p);
}
static void pool_foreach(void *data, b_lean_obj_arg f) {
    pool_handle *p = data;
    pthread_mutex_lock(&p->lock);
    for (pool_entry *e = p->entries; e; e = e->next) {
        lean_inc(f); lean_inc(e->value);
        lean_dec(lean_apply_1(f, e->value));
    }
    pthread_mutex_unlock(&p->lock);
}
static void machine_finalize(void *data) {
    machine_handle *m = data;
    if (m->ptr) hegel_state_machine_free(m->cleanup, m->ptr);
    hegel_context_free(m->cleanup);
    free(m);
}
static void no_refs(void *data, b_lean_obj_arg f) { (void)data; (void)f; }
static lean_external_class *pool_class, *machine_class;
static pthread_once_t classes_once = PTHREAD_ONCE_INIT;
static void init_classes(void) {
    pool_class = lean_register_external_class(pool_finalize, pool_foreach);
    machine_class = lean_register_external_class(machine_finalize, no_refs);
}
static lean_object *pool_valid(session *s, pool_handle *p) {
    if (!p->ptr) return hegel_lean_error(HEGEL_E_INVALID_HANDLE, "Pool has been released");
    if (p->family != hegel_lean_family(s))
        return hegel_lean_error(HEGEL_E_INVALID_HANDLE, "Pool belongs to another test case");
    return NULL;
}
static lean_object *machine_valid(session *s, machine_handle *m) {
    if (!m->ptr) return hegel_lean_error(HEGEL_E_INVALID_HANDLE, "State machine has been released");
    if (m->family != hegel_lean_family(s))
        return hegel_lean_error(HEGEL_E_INVALID_HANDLE, "State machine belongs to another test case");
    return NULL;
}
LEAN_EXPORT lean_obj_res lean_hegel_pool_new(b_lean_obj_arg handle) {
    ACTIVE();
    pool_handle *p = calloc(1, sizeof(*p));
    if (!p) return hegel_lean_error(HEGEL_E_INTERNAL, "Could not allocate pool");
    p->cleanup = hegel_context_new();
    pthread_mutex_init(&p->lock, NULL);
    hegel_result_t rc = hegel_new_pool(hegel_lean_context(s), hegel_lean_test_case(s), &p->ptr);
    if (rc != HEGEL_OK) { pool_finalize(p); return hegel_lean_engine_error(s, rc); }
    p->family = hegel_lean_family(s);
    p->identity = hegel_lean_fresh_pool_id(s);
    pthread_once(&classes_once, init_classes);
    return lean_io_result_mk_ok(lean_alloc_external(pool_class, p));
}
LEAN_EXPORT lean_obj_res lean_hegel_pool_identity(b_lean_obj_arg pool) {
    pool_handle *p = lean_get_external_data(pool);
    return lean_uint64_to_nat(p->identity);
}
LEAN_EXPORT lean_obj_res lean_hegel_pool_close(b_lean_obj_arg pool) {
    pool_handle *p = lean_get_external_data(pool);
    pthread_mutex_lock(&p->lock);
    pool_release(p);
    pthread_mutex_unlock(&p->lock);
    return hegel_lean_unit_ok();
}
LEAN_EXPORT lean_obj_res lean_hegel_pool_add(b_lean_obj_arg handle, b_lean_obj_arg pool,
    b_lean_obj_arg value) {
    ACTIVE();
    pool_handle *p = lean_get_external_data(pool);
    /* Mark before locking: values may themselves refer to this pool. */
    lean_mark_mt(value);
    pthread_mutex_lock(&p->lock);
    lean_object *err = pool_valid(s, p);
    if (err) { pthread_mutex_unlock(&p->lock); return err; }
    pool_entry *e = calloc(1, sizeof(*e));
    if (!e) { pthread_mutex_unlock(&p->lock);
        return hegel_lean_error(HEGEL_E_INTERNAL, "Could not allocate pool entry"); }
    hegel_result_t rc = hegel_pool_add(hegel_lean_context(s), hegel_lean_test_case(s), p->ptr, &e->id);
    if (rc != HEGEL_OK) { free(e); pthread_mutex_unlock(&p->lock);
        return hegel_lean_engine_error(s, rc); }
    lean_inc(value); e->value = value; e->next = p->entries; p->entries = e; p->size++;
    int64_t id = e->id;
    hegel_lean_record_pool_event(s, 0, p->identity, (uint64_t)id, 0, 0);
    pthread_mutex_unlock(&p->lock);
    return lean_io_result_mk_ok(lean_int64_to_int(id));
}
static lean_object *pool_draw_locked(session *s, pool_handle *p, bool consume,
    lean_object **value_out, int64_t *id_out) {
    lean_object *err = pool_valid(s, p);
    if (err) return err;
    int64_t id;
    hegel_result_t rc = hegel_pool_generate(hegel_lean_context(s), hegel_lean_test_case(s),
                                           p->ptr, consume, &id);
    if (rc != HEGEL_OK) return hegel_lean_engine_error(s, rc);
    if (id_out) *id_out = id;
    pool_entry **slot = &p->entries;
    while (*slot && (*slot)->id != id) slot = &(*slot)->next;
    if (!*slot) return hegel_lean_error(HEGEL_E_INTERNAL, "Engine returned unknown pool variable");
    pool_entry *e = *slot;
    *value_out = e->value;
    if (consume) { *slot = e->next; free(e); p->size--; }
    else lean_inc(e->value);
    return NULL;
}
LEAN_EXPORT lean_obj_res lean_hegel_pool_draw(b_lean_obj_arg handle, b_lean_obj_arg pool,
    uint8_t consume) {
    ACTIVE();
    pool_handle *p = lean_get_external_data(pool);
    pthread_mutex_lock(&p->lock);
    lean_object *value = NULL;
    int64_t id = 0;
    lean_object *err = pool_draw_locked(s, p, consume, &value, &id);
    if (!err) hegel_lean_record_pool_event(s, consume ? 2 : 1, p->identity, (uint64_t)id, 0, 0);
    pthread_mutex_unlock(&p->lock);
    return err ? err : lean_io_result_mk_ok(value);
}
LEAN_EXPORT lean_obj_res lean_hegel_pool_transfer(b_lean_obj_arg handle, b_lean_obj_arg source,
    b_lean_obj_arg destination) {
    ACTIVE();
    pool_handle *src = lean_get_external_data(source), *dst = lean_get_external_data(destination);
    pool_handle *first = (uintptr_t)src < (uintptr_t)dst ? src : dst;
    pool_handle *second = first == src ? dst : src;
    pthread_mutex_lock(&first->lock);
    if (second != first) pthread_mutex_lock(&second->lock);
    lean_object *err = pool_valid(s, src);
    pool_entry *entry = NULL;
    lean_object *value = NULL;
    if (!err) err = pool_valid(s, dst);
    if (err) goto failed;
    entry = calloc(1, sizeof(*entry));
    if (!entry) {
        err = hegel_lean_error(HEGEL_E_INTERNAL, "Could not allocate transferred entry");
        goto failed;
    }
    int64_t source_id = 0;
    err = pool_draw_locked(s, src, true, &value, &source_id);
    if (err) goto failed;
    if (!value) {
        err = hegel_lean_error(HEGEL_E_INTERNAL, "Pool draw returned no value");
        goto failed;
    }
    hegel_lean_record_pool_event(s, 2, src->identity, (uint64_t)source_id, 0, 0);
    hegel_result_t rc = hegel_pool_add(hegel_lean_context(s), hegel_lean_test_case(s),
                                      dst->ptr, &entry->id);
    if (rc != HEGEL_OK) { err = hegel_lean_engine_error(s, rc); goto failed; }
    entry->value = value; entry->next = dst->entries; dst->entries = entry; dst->size++;
    lean_inc(value);
    hegel_lean_record_pool_event(s, 3, dst->identity, (uint64_t)entry->id,
                                src->identity, (uint64_t)source_id);
    if (second != first) pthread_mutex_unlock(&second->lock);
    pthread_mutex_unlock(&first->lock);
    return lean_io_result_mk_ok(value);
failed:
    if (value) lean_dec(value);
    free(entry);
    if (second != first) pthread_mutex_unlock(&second->lock);
    pthread_mutex_unlock(&first->lock);
    return err;
}
LEAN_EXPORT lean_obj_res lean_hegel_pool_size(b_lean_obj_arg pool) {
    pool_handle *p = lean_get_external_data(pool);
    pthread_mutex_lock(&p->lock);
    bool closed = p->ptr == NULL;
    size_t size = p->size;
    pthread_mutex_unlock(&p->lock);
    if (closed) return hegel_lean_error(HEGEL_E_INVALID_HANDLE, "Pool has been released");
    return lean_io_result_mk_ok(lean_usize_to_nat(size));
}

static bool cstring_array(b_lean_obj_arg array, const char **out) {
    for (size_t i = 0; i < lean_array_size(array); ++i) {
        lean_object *str = lean_array_get_core(array, i);
        if (memchr(lean_string_cstr(str), 0, lean_string_size(str) - 1)) return false;
        out[i] = lean_string_cstr(str);
    }
    return true;
}
LEAN_EXPORT lean_obj_res lean_hegel_machine_new(b_lean_obj_arg handle, b_lean_obj_arg names,
    b_lean_obj_arg groups, b_lean_obj_arg weights, b_lean_obj_arg invariants, b_lean_obj_arg always,
    uint64_t min_workers, uint64_t max_workers, uint64_t steps) {
    ACTIVE();
    size_t n = lean_array_size(names), k = lean_array_size(invariants);
    if (!n || lean_array_size(groups) != n || lean_array_size(weights) != n ||
        lean_array_size(always) != k)
        return hegel_lean_error(HEGEL_E_INVALID_ARG, "Invalid state machine array lengths");
    const char **ns = calloc(n, sizeof(*ns)), **is = calloc(k ? k : 1, sizeof(*is));
    int64_t *gs = calloc(n, sizeof(*gs)); double *ws = calloc(n, sizeof(*ws));
    bool *as = calloc(k ? k : 1, sizeof(*as));
    machine_handle *m = calloc(1, sizeof(*m));
    if (!ns || !is || !gs || !ws || !as || !m) {
        free(ns); free(is); free(gs); free(ws); free(as); free(m);
        return hegel_lean_error(HEGEL_E_INTERNAL, "Could not allocate state machine");
    }
    bool valid_names = cstring_array(names, ns) && cstring_array(invariants, is);
    for (size_t i = 0; i < n; ++i) {
        gs[i] = (int64_t)lean_unbox_uint64(lean_array_get_core(groups, i));
        ws[i] = lean_unbox_float(lean_array_get_core(weights, i));
    }
    for (size_t i = 0; i < k; ++i) as[i] = lean_unbox(lean_array_get_core(always, i));
    int64_t count = 0;
    hegel_result_t rc = valid_names ? hegel_new_state_machine(hegel_lean_context(s),
        hegel_lean_test_case(s), ns, gs, ws, n, is, as, k, (int64_t)min_workers,
        (int64_t)max_workers, (int64_t)steps, &m->ptr, &count) : HEGEL_E_INVALID_ARG;
    free(ns); free(is); free(gs); free(ws); free(as);
    if (rc != HEGEL_OK) { free(m);
        return valid_names ? hegel_lean_engine_error(s, rc) :
            hegel_lean_error(rc, "Embedded NUL in state machine name"); }
    m->cleanup = hegel_context_new(); m->family = hegel_lean_family(s);
    pthread_once(&classes_once, init_classes);
    lean_object *pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, lean_alloc_external(machine_class, m));
    lean_ctor_set(pair, 1, lean_uint64_to_nat(count));
    return lean_io_result_mk_ok(pair);
}
LEAN_EXPORT lean_obj_res lean_hegel_machine_close(b_lean_obj_arg machine) {
    machine_handle *m = lean_get_external_data(machine);
    if (m->ptr) hegel_state_machine_free(m->cleanup, m->ptr);
    m->ptr = NULL;
    return hegel_lean_unit_ok();
}
#define MACHINE() ACTIVE(); \
    machine_handle *m = lean_get_external_data(machine); \
    lean_object *valid_ = machine_valid(s, m); if (valid_) return valid_
static lean_object *optional_index(int64_t n) {
    if (n == HEGEL_STATE_MACHINE_DONE) return lean_box(0);
    lean_object *some = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(some, 0, lean_uint64_to_nat(n));
    return some;
}
LEAN_EXPORT lean_obj_res lean_hegel_machine_group(b_lean_obj_arg handle, b_lean_obj_arg machine) {
    MACHINE(); int64_t n;
    CALL(hegel_state_machine_next_group(hegel_lean_context(s), hegel_lean_test_case(s), m->ptr, &n));
    return lean_io_result_mk_ok(optional_index(n));
}
LEAN_EXPORT lean_obj_res lean_hegel_machine_rule(b_lean_obj_arg handle, b_lean_obj_arg machine,
    uint64_t worker) {
    MACHINE(); int64_t n;
    CALL(hegel_state_machine_next_rule(hegel_lean_context(s), hegel_lean_test_case(s),
                                      m->ptr, (int64_t)worker, &n));
    return lean_io_result_mk_ok(optional_index(n));
}
LEAN_EXPORT lean_obj_res lean_hegel_machine_rejected(b_lean_obj_arg handle, b_lean_obj_arg machine,
    uint64_t worker) {
    MACHINE();
    CALL(hegel_state_machine_rule_rejected(hegel_lean_context(s), hegel_lean_test_case(s),
                                          m->ptr, (int64_t)worker));
    return hegel_lean_unit_ok();
}
LEAN_EXPORT lean_obj_res lean_hegel_machine_invariant(b_lean_obj_arg handle,
    b_lean_obj_arg machine, uint64_t index) {
    MACHINE(); bool check;
    CALL(hegel_state_machine_should_check_invariant(hegel_lean_context(s),
        hegel_lean_test_case(s), m->ptr, (int64_t)index, &check));
    return lean_io_result_mk_ok(lean_box(check));
}
