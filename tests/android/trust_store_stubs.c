/* Init then boot through the bridge's C entries, as a host makes them. */
#define CAML_NAME_SPACE
#include <stdlib.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "tsync_bridge.h"

CAMLprim value tsync_test_init_and_boot(value _trust_store, value _root,
                                        value _domain) {
  CAMLparam3(_trust_store, _root, _domain);
  CAMLlocal1(_sentence);
  char *trust_store = Is_some(_trust_store)
                          ? strdup(String_val(Some_val(_trust_store)))
                          : NULL;
  char *root = strdup(String_val(_root));
  char *domain = strdup(String_val(_domain));
  size_t length = 0;
  caml_release_runtime_system();
  tsync_bridge_init(trust_store, root, 0, 0, 0);
  char *sentence = tsync_bridge_text("boot", domain, strlen(domain), &length);
  caml_acquire_runtime_system();
  _sentence = caml_copy_string(sentence == NULL ? "(no reply)" : sentence);
  free(sentence);
  free(trust_store);
  free(root);
  free(domain);
  CAMLreturn(_sentence);
}
