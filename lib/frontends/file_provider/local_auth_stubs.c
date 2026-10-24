/* passwords/browser §5: the bridge verifies the user with LocalAuthentication
   (Touch ID or the account password). Compiled as Objective-C. */

#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

/* None when the user was verified, else Some reason. */
CAMLprim value tsync_local_auth_verify(value _reason) {
  CAMLparam1(_reason);
  CAMLlocal2(_failure, _result);
  char failure[512] = "";
  NSString *reason = [NSString stringWithUTF8String:String_val(_reason)];
  caml_release_runtime_system();
  @autoreleasepool {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
      snprintf(failure, sizeof(failure), "%s",
               error ? error.localizedDescription.UTF8String : "no verifier");
    } else {
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      __block BOOL ok = NO;
      __block NSString *why = nil;
      [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
              localizedReason:reason
                        reply:^(BOOL success, NSError *e) {
                          ok = success;
                          if (!success) why = e.localizedDescription;
                          dispatch_semaphore_signal(done);
                        }];
      dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
      if (!ok) snprintf(failure, sizeof(failure), "%s", why ? why.UTF8String : "not verified");
    }
  }
  caml_acquire_runtime_system();
  if (failure[0] == '\0') CAMLreturn(Val_none);
  _failure = caml_copy_string(failure);
  _result = caml_alloc_some(_failure);
  CAMLreturn(_result);
}
