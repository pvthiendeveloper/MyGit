#include "CIndexStore.h"

#include <dlfcn.h>
#include <stdio.h>

typedef indexstore_string_ref_t string_ref;

static struct {
    bool loaded;
    const char *(*error_get_description)(indexstore_error_t);
    void (*error_dispose)(indexstore_error_t);
    indexstore_t (*store_create)(const char *, indexstore_error_t *);
    void (*store_dispose)(indexstore_t);
    bool (*store_units_apply)(indexstore_t, unsigned, bool (^)(string_ref));
    indexstore_unit_reader_t (*unit_reader_create)(indexstore_t, const char *, indexstore_error_t *);
    void (*unit_reader_dispose)(indexstore_unit_reader_t);
    bool (*unit_reader_dependencies_apply)(indexstore_unit_reader_t, bool (^)(indexstore_unit_dependency_t));
    int (*unit_dependency_get_kind)(indexstore_unit_dependency_t);
    string_ref (*unit_dependency_get_filepath)(indexstore_unit_dependency_t);
    string_ref (*unit_dependency_get_name)(indexstore_unit_dependency_t);
    indexstore_record_reader_t (*record_reader_create)(indexstore_t, const char *, indexstore_error_t *);
    void (*record_reader_dispose)(indexstore_record_reader_t);
    bool (*record_reader_search_symbols)(indexstore_record_reader_t,
                                         bool (^)(indexstore_symbol_t, bool *),
                                         void (^)(indexstore_symbol_t));
    bool (*record_reader_occurrences_apply)(indexstore_record_reader_t, bool (^)(indexstore_occurrence_t));
    indexstore_symbol_t (*occurrence_get_symbol)(indexstore_occurrence_t);
    uint64_t (*occurrence_get_roles)(indexstore_occurrence_t);
    void (*occurrence_get_line_col)(indexstore_occurrence_t, unsigned *, unsigned *);
    string_ref (*symbol_get_usr)(indexstore_symbol_t);
    string_ref (*symbol_get_name)(indexstore_symbol_t);
    bool (*occurrence_relations_apply)(indexstore_occurrence_t, bool (^)(indexstore_symbol_relation_t));
    uint64_t (*symbol_relation_get_roles)(indexstore_symbol_relation_t);
    indexstore_symbol_t (*symbol_relation_get_symbol)(indexstore_symbol_relation_t);
} api;

bool mygit_indexstore_load(const char *dylib_path, char *error, size_t error_len) {
    if (api.loaded) return true;
    void *lib = dlopen(dylib_path, RTLD_LAZY | RTLD_LOCAL);
    if (!lib) {
        if (error) snprintf(error, error_len, "%s", dlerror());
        return false;
    }
#define BIND(field, name)                                                        \
    *(void **)(&api.field) = dlsym(lib, "indexstore_" name);                    \
    if (!api.field) {                                                            \
        if (error) snprintf(error, error_len, "missing indexstore_%s", name);   \
        return false;                                                            \
    }
    BIND(error_get_description, "error_get_description")
    BIND(error_dispose, "error_dispose")
    BIND(store_create, "store_create")
    BIND(store_dispose, "store_dispose")
    BIND(store_units_apply, "store_units_apply")
    BIND(unit_reader_create, "unit_reader_create")
    BIND(unit_reader_dispose, "unit_reader_dispose")
    BIND(unit_reader_dependencies_apply, "unit_reader_dependencies_apply")
    BIND(unit_dependency_get_kind, "unit_dependency_get_kind")
    BIND(unit_dependency_get_filepath, "unit_dependency_get_filepath")
    BIND(unit_dependency_get_name, "unit_dependency_get_name")
    BIND(record_reader_create, "record_reader_create")
    BIND(record_reader_dispose, "record_reader_dispose")
    BIND(record_reader_search_symbols, "record_reader_search_symbols")
    BIND(record_reader_occurrences_apply, "record_reader_occurrences_apply")
    BIND(occurrence_get_symbol, "occurrence_get_symbol")
    BIND(occurrence_get_roles, "occurrence_get_roles")
    BIND(occurrence_get_line_col, "occurrence_get_line_col")
    BIND(symbol_get_usr, "symbol_get_usr")
    BIND(symbol_get_name, "symbol_get_name")
    BIND(occurrence_relations_apply, "occurrence_relations_apply")
    BIND(symbol_relation_get_roles, "symbol_relation_get_roles")
    BIND(symbol_relation_get_symbol, "symbol_relation_get_symbol")
#undef BIND
    api.loaded = true;
    return true;
}

indexstore_t mygit_indexstore_store_create(const char *store_path) {
    indexstore_error_t err = NULL;
    indexstore_t store = api.store_create(store_path, &err);
    if (err) api.error_dispose(err);
    return store;
}

void mygit_indexstore_store_dispose(indexstore_t store) { api.store_dispose(store); }

bool mygit_indexstore_store_units_apply(indexstore_t store, bool (^applier)(string_ref)) {
    return api.store_units_apply(store, 0, applier);
}

indexstore_unit_reader_t mygit_indexstore_unit_reader_create(indexstore_t store, const char *unit_name) {
    indexstore_error_t err = NULL;
    indexstore_unit_reader_t reader = api.unit_reader_create(store, unit_name, &err);
    if (err) api.error_dispose(err);
    return reader;
}

void mygit_indexstore_unit_reader_dispose(indexstore_unit_reader_t reader) { api.unit_reader_dispose(reader); }

bool mygit_indexstore_unit_reader_dependencies_apply(indexstore_unit_reader_t reader,
                                                     bool (^applier)(indexstore_unit_dependency_t)) {
    return api.unit_reader_dependencies_apply(reader, applier);
}

int mygit_indexstore_unit_dependency_get_kind(indexstore_unit_dependency_t dep) {
    return api.unit_dependency_get_kind(dep);
}

string_ref mygit_indexstore_unit_dependency_get_filepath(indexstore_unit_dependency_t dep) {
    return api.unit_dependency_get_filepath(dep);
}

string_ref mygit_indexstore_unit_dependency_get_name(indexstore_unit_dependency_t dep) {
    return api.unit_dependency_get_name(dep);
}

indexstore_record_reader_t mygit_indexstore_record_reader_create(indexstore_t store, const char *record_name) {
    indexstore_error_t err = NULL;
    indexstore_record_reader_t reader = api.record_reader_create(store, record_name, &err);
    if (err) api.error_dispose(err);
    return reader;
}

void mygit_indexstore_record_reader_dispose(indexstore_record_reader_t reader) {
    api.record_reader_dispose(reader);
}

bool mygit_indexstore_record_reader_search_symbols(indexstore_record_reader_t reader,
                                                   bool (^filter)(indexstore_symbol_t, bool *),
                                                   void (^receiver)(indexstore_symbol_t)) {
    return api.record_reader_search_symbols(reader, filter, receiver);
}

bool mygit_indexstore_record_reader_occurrences_apply(indexstore_record_reader_t reader,
                                                      bool (^applier)(indexstore_occurrence_t)) {
    return api.record_reader_occurrences_apply(reader, applier);
}

indexstore_symbol_t mygit_indexstore_occurrence_get_symbol(indexstore_occurrence_t occurrence) {
    return api.occurrence_get_symbol(occurrence);
}

uint64_t mygit_indexstore_occurrence_get_roles(indexstore_occurrence_t occurrence) {
    return api.occurrence_get_roles(occurrence);
}

void mygit_indexstore_occurrence_get_line_col(indexstore_occurrence_t occurrence,
                                              unsigned *line, unsigned *column) {
    api.occurrence_get_line_col(occurrence, line, column);
}

string_ref mygit_indexstore_symbol_get_usr(indexstore_symbol_t symbol) { return api.symbol_get_usr(symbol); }

string_ref mygit_indexstore_symbol_get_name(indexstore_symbol_t symbol) { return api.symbol_get_name(symbol); }

bool mygit_indexstore_occurrence_relations_apply(indexstore_occurrence_t occurrence,
                                                 bool (^applier)(indexstore_symbol_relation_t)) {
    return api.occurrence_relations_apply(occurrence, applier);
}

uint64_t mygit_indexstore_symbol_relation_get_roles(indexstore_symbol_relation_t relation) {
    return api.symbol_relation_get_roles(relation);
}

indexstore_symbol_t mygit_indexstore_symbol_relation_get_symbol(indexstore_symbol_relation_t relation) {
    return api.symbol_relation_get_symbol(relation);
}
