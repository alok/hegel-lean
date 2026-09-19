/* Lean object ownership follows lean/lean.h; engine ownership follows hegel.h. */
#include "hegel_lean.h"
#include <stdatomic.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>

typedef struct collection_entry {
    uint64_t id;
    hegel_collection_t *value;
    struct collection_entry *next;
} collection_entry;

typedef struct resource_entry {
    uint64_t id;
    void *value;
    void (*release)(hegel_context_t *, void *);
    struct resource_entry *next;
} resource_entry;
typedef struct pool_event {
    uint64_t fields[5];
    struct pool_event *next;
} pool_event;
typedef struct family_state {
    atomic_uint refs;
    atomic_uint_fast64_t next_pool;
} family_state;
typedef struct output_state {
    atomic_uint refs;
    pthread_mutex_t lock;
    char *data;
    size_t len;
} output_state;
struct hegel_lean_session {
    hegel_context_t *ctx;
    hegel_settings_t *settings;
    hegel_run_t *run;
    hegel_test_case_t *tc;
    collection_entry *collections;
    uint64_t next_id;
    pthread_t owner;
    atomic_int owner_state;
    uint64_t family;
    bool is_clone;
    family_state *shared_family;
    output_state *output;
    resource_entry *resources;
    pool_event *events_head, *events_tail;
};
static atomic_uint_fast64_t next_family = 1;

static lean_object *error_value(int code, const char *message) {
    lean_object *e = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(e, 0, lean_int64_to_int(code));
    lean_ctor_set(e, 1, lean_mk_string(message ? message : "unknown engine error"));
    return lean_io_result_mk_error(e);
}
static lean_object *engine_error(session *s, hegel_result_t rc) {
    return error_value(rc, hegel_context_last_error(s->ctx));
}
static lean_object *unit_ok(void) { return lean_io_result_mk_ok(lean_box(0)); }
static void release_collections(session *s) {
    while (s->collections) {
        collection_entry *p = s->collections;
        s->collections = p->next;
        hegel_collection_free(s->ctx, p->value);
        free(p);
    }
}
static void release_case(session *s) {
    release_collections(s);
    while (s->resources) {
        resource_entry *entry = s->resources;
        s->resources = entry->next;
        entry->release(s->ctx, entry->value); free(entry);
    }
    while (s->events_head) {
        pool_event *entry = s->events_head;
        s->events_head = entry->next; free(entry);
    }
    s->events_tail = NULL;
    if (s->tc) hegel_test_case_free(s->ctx, s->tc);
    s->tc = NULL;
    if (s->shared_family && atomic_fetch_sub(&s->shared_family->refs, 1) == 1)
        free(s->shared_family);
    s->shared_family = NULL;
}
static void release_session(session *s) {
    if (!s->ctx) return;
    release_case(s);
    if (s->run) hegel_run_free(s->ctx, s->run);
    if (s->settings) hegel_settings_free(s->ctx, s->settings);
    hegel_context_free(s->ctx);
    s->ctx = NULL; s->run = NULL; s->settings = NULL;
    if (s->output && atomic_fetch_sub(&s->output->refs, 1) == 1) {
        pthread_mutex_destroy(&s->output->lock); free(s->output->data); free(s->output);
    }
    s->output = NULL;
}
static void finalize(void *data) { session *s = data; release_session(s); free(s); }
static void foreach_ref(void *data, b_lean_obj_arg f) { (void)data; (void)f; }
static lean_external_class *session_class;
static pthread_once_t class_once = PTHREAD_ONCE_INIT;
static void init_class(void) {
    session_class = lean_register_external_class(finalize, foreach_ref);
}
/* A cloned stream is claimed by its first worker, then stays thread confined. */
session *hegel_lean_get_session(b_lean_obj_arg handle) { return lean_get_external_data(handle); }
lean_object *hegel_lean_check_session(session *s, bool require_case) {
    int state = atomic_load_explicit(&s->owner_state, memory_order_acquire);
    if (state == 0) {
        int expected = 0;
        if (!atomic_compare_exchange_strong(&s->owner_state, &expected, 2))
            return error_value(HEGEL_E_CONCURRENT_USE, "Hegel stream is being claimed");
        s->owner = pthread_self();
        atomic_store_explicit(&s->owner_state, 1, memory_order_release);
    } else if (state != 1 || !pthread_equal(s->owner, pthread_self())) {
        return error_value(HEGEL_E_CONCURRENT_USE, "Hegel session used from another thread");
    }
    if (!s->ctx) return error_value(HEGEL_E_INVALID_HANDLE, "Hegel session is closed");
    if (require_case && !s->tc)
        return error_value(HEGEL_E_INVALID_HANDLE, "No active Hegel test case");
    return NULL;
}
hegel_context_t *hegel_lean_context(session *s) { return s->ctx; }
hegel_settings_t *hegel_lean_settings(session *s) { return s->settings; }
hegel_test_case_t *hegel_lean_test_case(session *s) { return s->tc; }
uint64_t hegel_lean_family(session *s) { return s->family; }
lean_object *hegel_lean_error(int code, const char *msg) { return error_value(code, msg); }
lean_object *hegel_lean_error_value(int code, const char *msg) { return error_value(code, msg); }
lean_object *hegel_lean_engine_error(session *s, hegel_result_t rc) { return engine_error(s, rc); }
lean_object *hegel_lean_unit_ok(void) { return unit_ok(); }
#define SESSION() \
    session *s = hegel_lean_get_session(handle); \
    lean_object *session_error = hegel_lean_check_session(s, false); \
    if (session_error) return session_error
#define CASE() SESSION(); \
    if (!s->tc) return error_value(HEGEL_E_INVALID_HANDLE, "No active Hegel test case")
#define CHECK(expr) do { hegel_result_t rc_ = (expr); \
    if (rc_ != HEGEL_OK) return engine_error(s, rc_); } while (0)
#define CSTRING(str) do { \
    if (memchr(lean_string_cstr(str), 0, lean_string_size(str) - 1)) \
        return error_value(HEGEL_E_INVALID_ARG, "Embedded NUL in C-string argument"); \
} while (0)
static void silent_output(void *data, const char *line, size_t len) {
    output_state *output = data;
    if (!output) return;
    pthread_mutex_lock(&output->lock);
    char *buffer = realloc(output->data, output->len + len + 2);
    if (!buffer) lean_internal_panic_out_of_memory();
    output->data = buffer;
    memcpy(buffer + output->len, line, len); output->len += len;
    buffer[output->len++] = '\n'; buffer[output->len] = 0;
    pthread_mutex_unlock(&output->lock);
}

LEAN_EXPORT lean_obj_res lean_hegel_open(uint64_t cases, uint64_t seed, uint8_t has_seed,
    b_lean_obj_arg database, b_lean_obj_arg key, uint8_t multiple,
    uint32_t phases, uint32_t suppress) {
    CSTRING(database); CSTRING(key);
    session *s = calloc(1, sizeof(session));
    if (!s) return error_value(HEGEL_E_INTERNAL, "Could not allocate Hegel session");
    s->ctx = hegel_context_new(); s->owner = pthread_self();
    atomic_init(&s->owner_state, 1);
    s->output = calloc(1, sizeof(output_state));
    if (!s->output) lean_internal_panic_out_of_memory();
    atomic_init(&s->output->refs, 1); pthread_mutex_init(&s->output->lock, NULL);
    hegel_result_t rc;
#define SET(expr) do { rc = (expr); if (rc != HEGEL_OK) goto fail; } while (0)
    SET(hegel_settings_new(s->ctx, &s->settings));
    SET(hegel_settings_set_backend(s->ctx, s->settings, HEGEL_BACKEND_DEFAULT));
    SET(hegel_settings_set_test_cases(s->ctx, s->settings, cases));
    SET(hegel_settings_set_seed(s->ctx, s->settings, seed, has_seed));
    SET(hegel_settings_set_database(s->ctx, s->settings, lean_string_cstr(database)));
    SET(hegel_settings_set_database_key(s->ctx, s->settings, lean_string_cstr(key)));
    SET(hegel_settings_set_report_multiple_failures(s->ctx, s->settings, multiple));
    SET(hegel_settings_set_phases(s->ctx, s->settings, phases));
    SET(hegel_settings_set_suppress_health_check(s->ctx, s->settings, suppress));
    SET(hegel_settings_set_verbosity(s->ctx, s->settings, HEGEL_VERBOSITY_QUIET));
    /* Settings.configure runs before the explicit startRun call. */
    pthread_once(&class_once, init_class);
    return lean_io_result_mk_ok(lean_alloc_external(session_class, s));
fail: {
    lean_object *err = engine_error(s, rc);
    release_session(s); free(s); return err;
}
#undef SET
}
LEAN_EXPORT lean_obj_res lean_hegel_close(b_lean_obj_arg handle) {
    session *s = lean_get_external_data(handle);
    if (!s->ctx) return unit_ok();
    lean_object *err = hegel_lean_check_session(s, false);
    if (err) return err;
    release_session(s); return unit_ok();
}
LEAN_EXPORT lean_obj_res lean_hegel_next(b_lean_obj_arg handle) {
    SESSION();
    /* next requires a completed case; do not discard a live one on API misuse. */
    hegel_test_case_t *tc = NULL;
    CHECK(hegel_next_test_case(s->ctx, s->run, &tc));
    release_case(s); s->tc = tc;
    if (tc) {
        s->family = atomic_fetch_add(&next_family, 1);
        s->shared_family = calloc(1, sizeof(family_state));
        if (!s->shared_family) lean_internal_panic_out_of_memory();
        atomic_init(&s->shared_family->refs, 1); atomic_init(&s->shared_family->next_pool, 0);
    }
    return lean_io_result_mk_ok(lean_box(tc != NULL));
}
LEAN_EXPORT lean_obj_res lean_hegel_complete(b_lean_obj_arg handle, uint32_t status,
    b_lean_obj_arg origin) {
    CASE(); CSTRING(origin);
    if (s->is_clone) return error_value(HEGEL_E_INVALID_ARG, "Only the root completes a case");
    CHECK(hegel_mark_complete(s->ctx, s->tc, status,
          status == HEGEL_STATUS_INTERESTING ? lean_string_cstr(origin) : NULL));
    release_case(s); return unit_ok();
}
LEAN_EXPORT lean_obj_res lean_hegel_replay(b_lean_obj_arg handle, b_lean_obj_arg blob) {
    SESSION(); CSTRING(blob);
    if (s->tc) return error_value(HEGEL_E_NOT_COMPLETE, "Complete the current case before replay");
    CHECK(hegel_test_case_from_blob(s->ctx, s->settings, lean_string_cstr(blob),
                                  silent_output, s->output, &s->tc));
    s->family = atomic_fetch_add(&next_family, 1);
    s->shared_family = calloc(1, sizeof(family_state));
    if (!s->shared_family) lean_internal_panic_out_of_memory();
    atomic_init(&s->shared_family->refs, 1); atomic_init(&s->shared_family->next_pool, 0);
    return unit_ok();
}
LEAN_EXPORT lean_obj_res lean_hegel_result(b_lean_obj_arg handle) {
    SESSION();
    hegel_run_result_t *r = NULL;
    hegel_failure_t *f = NULL;
    hegel_run_status_t status;
    const char *message = NULL;
    size_t count;
    lean_object *failures = lean_mk_empty_array();
    hegel_result_t rc;
#define READ(expr) do { rc = (expr); if (rc != HEGEL_OK) goto fail; } while (0)
    READ(hegel_run_result(s->ctx, s->run, &r));
    READ(hegel_run_result_status(s->ctx, r, &status));
    READ(hegel_run_result_error(s->ctx, r, &message));
    READ(hegel_run_result_failure_count(s->ctx, r, &count));
    for (size_t i = 0; i < count; ++i) {
        const char *origin = NULL, *blob = NULL;
        READ(hegel_run_result_failure(s->ctx, r, i, &f));
        READ(hegel_failure_origin(s->ctx, f, &origin));
        READ(hegel_failure_reproduction_blob(s->ctx, f, &blob));
        lean_object *pair = lean_alloc_ctor(0, 2, 0);
        lean_ctor_set(pair, 0, lean_mk_string(origin ? origin : ""));
        lean_ctor_set(pair, 1, lean_mk_string(blob ? blob : ""));
        failures = lean_array_push(failures, pair);
        hegel_failure_free(s->ctx, f); f = NULL;
    }
    lean_object *out = lean_alloc_ctor(0, 3, 0);
    lean_ctor_set(out, 0, lean_unsigned_to_nat(status));
    lean_ctor_set(out, 1, lean_mk_string(message ? message : ""));
    lean_ctor_set(out, 2, failures);
    hegel_run_result_free(s->ctx, r);
    return lean_io_result_mk_ok(out);
fail: {
    lean_object *err = engine_error(s, rc);
    hegel_failure_free(s->ctx, f); hegel_run_result_free(s->ctx, r);
    lean_dec(failures); return err;
}
#undef READ
}
LEAN_EXPORT lean_obj_res lean_hegel_version(void) {
    const char *version = NULL;
    hegel_result_t rc = hegel_version(NULL, &version);
    if (rc != HEGEL_OK) return error_value(rc, "Cannot read Hegel version");
    return lean_io_result_mk_ok(lean_mk_string(version));
}
LEAN_EXPORT lean_obj_res lean_hegel_boolean(b_lean_obj_arg handle, double p) {
    CASE(); bool value;
    CHECK(hegel_generate_boolean(s->ctx, s->tc, p, false, false, &value));
    return lean_io_result_mk_ok(lean_box(value));
}
LEAN_EXPORT lean_obj_res lean_hegel_integer(b_lean_obj_arg handle, uint64_t lo, uint64_t hi) {
    CASE(); int64_t value;
    CHECK(hegel_generate_integer(s->ctx, s->tc, (int64_t)lo, (int64_t)hi, &value));
    return lean_io_result_mk_ok(lean_int64_to_int(value));
}
LEAN_EXPORT lean_obj_res lean_hegel_integer_big(b_lean_obj_arg handle, b_lean_obj_arg lo,
    b_lean_obj_arg hi) {
    CASE();
    size_t cap = lean_sarray_size(lo) > lean_sarray_size(hi) ?
        lean_sarray_size(lo) : lean_sarray_size(hi);
    lean_object *bytes = lean_alloc_sarray(1, cap, cap);
    size_t len;
    hegel_result_t rc = hegel_generate_integer_big(s->ctx, s->tc,
        lean_sarray_cptr(lo), lean_sarray_size(lo), lean_sarray_cptr(hi), lean_sarray_size(hi),
        lean_sarray_cptr(bytes), cap, &len);
    if (rc != HEGEL_OK) { lean_dec(bytes); return engine_error(s, rc); }
    return lean_io_result_mk_ok(bytes);
}
LEAN_EXPORT lean_obj_res lean_hegel_float(b_lean_obj_arg handle, double lo, double hi,
    uint8_t nan, uint8_t infinity, uint8_t excl_lo, uint8_t excl_hi) {
    CASE(); double value;
    CHECK(hegel_generate_float(s->ctx, s->tc, 64, lo, hi, nan, infinity, excl_lo, excl_hi,
                              DBL_TRUE_MIN, &value));
    return lean_io_result_mk_ok(lean_box_float(value));
}
LEAN_EXPORT lean_obj_res lean_hegel_bytes(b_lean_obj_arg handle, uint64_t lo, uint64_t hi) {
    CASE(); hegel_generate_bytes_result_t value = {0};
    CHECK(hegel_generate_bytes(s->ctx, s->tc, lo, hi, &value));
    lean_object *out = lean_alloc_sarray(1, value.len, value.len);
    memcpy(lean_sarray_cptr(out), value.data, value.len);
    hegel_generate_bytes_result_free(s->ctx, &value);
    return lean_io_result_mk_ok(out);
}
static lean_object *draw_string(session *s, hegel_string_generator_t *gen) {
    hegel_generate_string_result_t value = {0};
    hegel_result_t rc = hegel_generate_string(s->ctx, s->tc, gen, &value);
    /* Preserve the error before free overwrites the context diagnostic. */
    lean_object *out = rc == HEGEL_OK ?
        lean_io_result_mk_ok(lean_mk_string_from_bytes(value.data, value.len)) : engine_error(s, rc);
    hegel_generate_string_result_free(s->ctx, &value);
    hegel_string_generator_free(s->ctx, gen);
    return out;
}
LEAN_EXPORT lean_obj_res lean_hegel_text(b_lean_obj_arg handle, uint64_t lo, uint64_t hi,
    uint32_t min_char, uint32_t max_char, b_lean_obj_arg codec) {
    CASE(); CSTRING(codec); hegel_string_generator_t *gen = NULL;
    CHECK(hegel_string_generator_text(s->ctx, lo, hi, lean_string_cstr(codec),
        min_char, max_char, NULL, 0, NULL, 0, NULL, 0, NULL, 0, &gen));
    return draw_string(s, gen);
}
LEAN_EXPORT lean_obj_res lean_hegel_string(b_lean_obj_arg handle, uint32_t kind,
    b_lean_obj_arg arg, uint8_t flag, uint64_t limit) {
    CASE(); CSTRING(arg); hegel_string_generator_t *gen = NULL;
    switch (kind) {
        case 0: CHECK(hegel_string_generator_regex(s->ctx, lean_string_cstr(arg), flag, NULL, &gen)); break;
        case 1: CHECK(hegel_string_generator_email(s->ctx, &gen)); break;
        case 2: CHECK(hegel_string_generator_url(s->ctx, &gen)); break;
        case 3: CHECK(hegel_string_generator_domain(s->ctx, limit, &gen)); break;
        default: return error_value(HEGEL_E_INVALID_ARG, "Unknown string generator");
    }
    return draw_string(s, gen);
}
LEAN_EXPORT lean_obj_res lean_hegel_start_span(b_lean_obj_arg handle, b_lean_obj_arg name) {
    CASE(); CSTRING(name); uint64_t label;
    CHECK(hegel_label_from_name(s->ctx, lean_string_cstr(name), &label));
    CHECK(hegel_start_span(s->ctx, s->tc, label)); return unit_ok();
}
LEAN_EXPORT lean_obj_res lean_hegel_stop_span(b_lean_obj_arg handle, uint8_t discard) {
    CASE(); CHECK(hegel_stop_span(s->ctx, s->tc, discard)); return unit_ok();
}
LEAN_EXPORT lean_obj_res lean_hegel_collection(b_lean_obj_arg handle, uint64_t lo, uint64_t hi) {
    CASE();
    collection_entry *p = calloc(1, sizeof(collection_entry));
    if (!p) return error_value(HEGEL_E_INTERNAL, "Could not allocate collection");
    hegel_result_t rc = hegel_new_collection(s->ctx, s->tc, lo, hi, &p->value);
    if (rc != HEGEL_OK) { free(p); return engine_error(s, rc); }
    p->id = ++s->next_id; p->next = s->collections; s->collections = p;
    return lean_io_result_mk_ok(lean_box_uint64(p->id));
}
static collection_entry *find_collection(session *s, uint64_t id) {
    for (collection_entry *p = s->collections; p; p = p->next) if (p->id == id) return p;
    return NULL;
}
#define COLLECTION() CASE(); collection_entry *p = find_collection(s, id); \
    if (!p) return error_value(HEGEL_E_INVALID_HANDLE, "Expired collection")
LEAN_EXPORT lean_obj_res lean_hegel_more(b_lean_obj_arg handle, uint64_t id) {
    COLLECTION(); bool more;
    CHECK(hegel_collection_more(s->ctx, s->tc, p->value, &more));
    return lean_io_result_mk_ok(lean_box(more));
}
LEAN_EXPORT lean_obj_res lean_hegel_reject(b_lean_obj_arg handle, uint64_t id) {
    COLLECTION();
    CHECK(hegel_collection_reject(s->ctx, s->tc, p->value, NULL)); return unit_ok();
}
LEAN_EXPORT lean_obj_res lean_hegel_collection_free(b_lean_obj_arg handle, uint64_t id) {
    SESSION();
    collection_entry **p = &s->collections;
    while (*p) {
        if ((*p)->id == id) {
            collection_entry *old = *p; *p = old->next;
            hegel_collection_free(s->ctx, old->value); free(old); return unit_ok();
        }
        p = &(*p)->next;
    }
    return error_value(HEGEL_E_INVALID_HANDLE, "Expired collection");
}
LEAN_EXPORT lean_obj_res lean_hegel_target(b_lean_obj_arg handle, double score,
    b_lean_obj_arg label) {
    CASE(); CSTRING(label);
    CHECK(hegel_target(s->ctx, s->tc, score, lean_string_cstr(label))); return unit_ok();
}

static pthread_once_t strict_panic_once = PTHREAD_ONCE_INIT;
static void enable_strict_panics(void) { lean_set_exit_on_panic(true); }
LEAN_EXPORT lean_obj_res lean_hegel_start_run(b_lean_obj_arg handle) {
    SESSION();
    if (s->run || !s->settings)
        return error_value(HEGEL_E_INVALID_ARG, "Run already started or cloned stream");
    pthread_once(&strict_panic_once, enable_strict_panics);
    CHECK(hegel_run_start(s->ctx, s->settings, silent_output, s->output, &s->run));
    return unit_ok();
}
LEAN_EXPORT lean_obj_res lean_hegel_clone(b_lean_obj_arg handle) {
    CASE();
    session *child = calloc(1, sizeof(session));
    if (!child) return error_value(HEGEL_E_INTERNAL, "Could not allocate cloned stream");
    child->ctx = hegel_context_new();
    child->family = s->family;
    child->shared_family = s->shared_family;
    atomic_fetch_add(&child->shared_family->refs, 1);
    child->output = s->output;
    atomic_fetch_add(&child->output->refs, 1);
    child->is_clone = true;
    atomic_init(&child->owner_state, 0);
    hegel_result_t rc = hegel_test_case_clone(s->ctx, s->tc, &child->tc);
    if (rc != HEGEL_OK) {
        lean_object *err = engine_error(s, rc);
        release_session(child); free(child); return err;
    }
    return lean_io_result_mk_ok(lean_alloc_external(session_class, child));
}

uint64_t hegel_lean_register_resource(session *s, void *resource,
    void (*release)(hegel_context_t *, void *)) {
    resource_entry *entry = malloc(sizeof(resource_entry));
    if (!entry) return 0;
    entry->id = ++s->next_id; entry->value = resource; entry->release = release;
    entry->next = s->resources; s->resources = entry;
    return entry->id;
}
void *hegel_lean_get_resource(session *s, uint64_t id) {
    for (resource_entry *entry = s->resources; entry; entry = entry->next)
        if (entry->id == id) return entry->value;
    return NULL;
}
hegel_result_t hegel_lean_free_resource(session *s, uint64_t id) {
    resource_entry **link = &s->resources;
    while (*link) {
        resource_entry *entry = *link;
        if (entry->id == id) {
            *link = entry->next;
            entry->release(s->ctx, entry->value); free(entry); return HEGEL_OK;
        }
        link = &entry->next;
    }
    return HEGEL_E_INVALID_HANDLE;
}
void hegel_lean_record_pool_event(session *s, uint32_t kind, uint64_t pool, uint64_t index,
    uint64_t source_pool, uint64_t source_index) {
    pool_event *entry = malloc(sizeof(pool_event));
    if (!entry) lean_internal_panic_out_of_memory();
    entry->fields[0] = kind; entry->fields[1] = pool; entry->fields[2] = index;
    entry->fields[3] = source_pool; entry->fields[4] = source_index; entry->next = NULL;
    if (s->events_tail) s->events_tail->next = entry; else s->events_head = entry;
    s->events_tail = entry;
}
LEAN_EXPORT lean_obj_res lean_hegel_drain_pool_events(b_lean_obj_arg handle) {
    SESSION();
    lean_object *out = lean_mk_empty_array();
    while (s->events_head) {
        pool_event *entry = s->events_head; s->events_head = entry->next;
        lean_object *event = lean_alloc_ctor(0, 5, 0);
        for (size_t i = 0; i < 5; ++i) lean_ctor_set(event, i, lean_uint64_to_nat(entry->fields[i]));
        out = lean_array_push(out, event); free(entry);
    }
    s->events_tail = NULL;
    return lean_io_result_mk_ok(out);
}

uint64_t hegel_lean_fresh_pool_id(session *s) {
    return atomic_fetch_add(&s->shared_family->next_pool, 1);
}
LEAN_EXPORT lean_obj_res lean_hegel_output(b_lean_obj_arg handle) {
    SESSION();
    pthread_mutex_lock(&s->output->lock);
    lean_object *out = lean_mk_string_from_bytes(s->output->data ? s->output->data : "", s->output->len);
    pthread_mutex_unlock(&s->output->lock);
    return lean_io_result_mk_ok(out);
}
