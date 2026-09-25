// Minimal binding to Xcode's libIndexStore (the index Xcode writes while it
// builds, under DerivedData/<proj>/Index.noindex/DataStore).
//
// Xcode ships the dylib but not its header, so the handful of entry points
// MyGit needs are declared here — they mirror LLVM's indexstore.h (C API,
// version 0.x), which has been ABI-stable since Xcode 9. The library is
// dlopen'd at runtime: nothing links against Xcode.

#ifndef MYGIT_CINDEXSTORE_H
#define MYGIT_CINDEXSTORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void *indexstore_error_t;
typedef void *indexstore_t;
typedef void *indexstore_unit_reader_t;
typedef void *indexstore_unit_dependency_t;
typedef void *indexstore_record_reader_t;
typedef void *indexstore_symbol_t;
typedef void *indexstore_occurrence_t;
typedef void *indexstore_symbol_relation_t;

typedef struct {
    const char *data;
    size_t length;
} indexstore_string_ref_t;

// indexstore_unit_dependency_kind_t
#define MYGIT_INDEXSTORE_DEP_UNIT 1
#define MYGIT_INDEXSTORE_DEP_RECORD 2
#define MYGIT_INDEXSTORE_DEP_FILE 3

// indexstore_symbol_role_t bits
#define MYGIT_INDEXSTORE_ROLE_DECLARATION (1 << 0)
#define MYGIT_INDEXSTORE_ROLE_DEFINITION  (1 << 1)
#define MYGIT_INDEXSTORE_ROLE_REFERENCE   (1 << 2)
#define MYGIT_INDEXSTORE_ROLE_IMPLICIT    (1 << 8)
// Relation roles (on an occurrence's relations).
#define MYGIT_INDEXSTORE_ROLE_REL_CHILDOF     (1 << 9)
#define MYGIT_INDEXSTORE_ROLE_REL_OVERRIDEOF  (1 << 11)
#define MYGIT_INDEXSTORE_ROLE_REL_ACCESSOROF  (1 << 15)

/// Load the library. Returns false (and fills `error`, if given) when the
/// dylib or one of its symbols is missing. Safe to call repeatedly.
bool mygit_indexstore_load(const char *dylib_path, char *error, size_t error_len);

indexstore_t mygit_indexstore_store_create(const char *store_path);
void mygit_indexstore_store_dispose(indexstore_t store);
bool mygit_indexstore_store_units_apply(indexstore_t store,
                                        bool (^applier)(indexstore_string_ref_t unit_name));

indexstore_unit_reader_t mygit_indexstore_unit_reader_create(indexstore_t store, const char *unit_name);
void mygit_indexstore_unit_reader_dispose(indexstore_unit_reader_t reader);
bool mygit_indexstore_unit_reader_dependencies_apply(indexstore_unit_reader_t reader,
                                                     bool (^applier)(indexstore_unit_dependency_t dep));
int mygit_indexstore_unit_dependency_get_kind(indexstore_unit_dependency_t dep);
indexstore_string_ref_t mygit_indexstore_unit_dependency_get_filepath(indexstore_unit_dependency_t dep);
indexstore_string_ref_t mygit_indexstore_unit_dependency_get_name(indexstore_unit_dependency_t dep);

indexstore_record_reader_t mygit_indexstore_record_reader_create(indexstore_t store, const char *record_name);
void mygit_indexstore_record_reader_dispose(indexstore_record_reader_t reader);
bool mygit_indexstore_record_reader_search_symbols(indexstore_record_reader_t reader,
                                                   bool (^filter)(indexstore_symbol_t symbol, bool *stop),
                                                   void (^receiver)(indexstore_symbol_t symbol));
bool mygit_indexstore_record_reader_occurrences_apply(indexstore_record_reader_t reader,
                                                      bool (^applier)(indexstore_occurrence_t occurrence));

indexstore_symbol_t mygit_indexstore_occurrence_get_symbol(indexstore_occurrence_t occurrence);
uint64_t mygit_indexstore_occurrence_get_roles(indexstore_occurrence_t occurrence);
void mygit_indexstore_occurrence_get_line_col(indexstore_occurrence_t occurrence,
                                              unsigned *line, unsigned *column);
indexstore_string_ref_t mygit_indexstore_symbol_get_usr(indexstore_symbol_t symbol);
indexstore_string_ref_t mygit_indexstore_symbol_get_name(indexstore_symbol_t symbol);

/// An occurrence's relations: e.g. an implementation's `overrideOf` its
/// protocol requirement, an accessor's `accessorOf` its property.
bool mygit_indexstore_occurrence_relations_apply(indexstore_occurrence_t occurrence,
                                                 bool (^applier)(indexstore_symbol_relation_t relation));
uint64_t mygit_indexstore_symbol_relation_get_roles(indexstore_symbol_relation_t relation);
indexstore_symbol_t mygit_indexstore_symbol_relation_get_symbol(indexstore_symbol_relation_t relation);

#endif
