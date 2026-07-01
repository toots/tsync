#include <caml/mlvalues.h>
#include <sys/stat.h>

CAMLprim value caml_is_dataless(value _path)
{
    struct stat st;
    if (stat(String_val(_path), &st) == 0)
        return Val_bool(st.st_flags & SF_DATALESS);
    return Val_false;
}
