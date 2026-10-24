/* file-provider §3.1: macOS 15 lets a process into a group container without
   asking only if it obtained the path from FileManager (and a profile
   authorises the group). Compiled as Objective-C. */

#import <Foundation/Foundation.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

CAMLprim value tsync_group_container_lookup(value _group) {
  CAMLparam1(_group);
  CAMLlocal2(_path, _result);
  char path[PATH_MAX] = "";
  @autoreleasepool {
    NSString *group = [NSString stringWithUTF8String:String_val(_group)];
    NSURL *url = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:group];
    if (url != nil) [url getFileSystemRepresentation:path maxLength:sizeof(path)];
  }
  if (path[0] == '\0') CAMLreturn(Val_none);
  _path = caml_copy_string(path);
  _result = caml_alloc_some(_path);
  CAMLreturn(_result);
}
