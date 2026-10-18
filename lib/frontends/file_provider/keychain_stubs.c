/* The vault keystore of macOS (security-model §10.6): one generic-password item
   of the login keychain per domain. No call ever shows a dialog. */

#include <string.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

static const char *service_name = "org.feverdreamtv.tsync.vault";

/* The login keychain is the file-based one: its no-dialog switch is the
   process-wide SecKeychainSetUserInteractionAllowed, deprecated with that
   keychain but the only one it honours. kSecUseAuthenticationUIFail is set too,
   for the data-protection keychain. */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* Once, at registration: the daemon never wants a keychain dialog. */
CAMLprim value tsync_keychain_no_dialogs(value _unit) {
  CAMLparam1(_unit);
  SecKeychainSetUserInteractionAllowed(false);
  CAMLreturn(Val_unit);
}

static CFStringRef string_of_value(value _text) {
  return CFStringCreateWithBytes(NULL, (const UInt8 *)String_val(_text),
                                 caml_string_length(_text), kCFStringEncodingUTF8,
                                 false);
}

/* The base query naming the domain's item; the caller releases it. */
static CFMutableDictionaryRef item_query(value _domain) {
  CFMutableDictionaryRef query = CFDictionaryCreateMutable(
      NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFStringRef service = CFStringCreateWithCString(NULL, service_name,
                                                  kCFStringEncodingUTF8);
  CFStringRef account = string_of_value(_domain);
  CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
  CFDictionarySetValue(query, kSecAttrService, service);
  CFDictionarySetValue(query, kSecAttrAccount, account);
  CFDictionarySetValue(query, kSecUseAuthenticationUI,
                       kSecUseAuthenticationUIFail);
  CFRelease(service);
  CFRelease(account);
  return query;
}

/* Raises Failure with the keychain's sentence for a status. */
static void fail_with(OSStatus status) {
  char message[256] = "keychain error";
  CFStringRef text = SecCopyErrorMessageString(status, NULL);
  if (text != NULL) {
    CFStringGetCString(text, message, sizeof(message), kCFStringEncodingUTF8);
    CFRelease(text);
  }
  caml_failwith(message);
}

CAMLprim value tsync_keychain_put(value _domain, value _secret) {
  CAMLparam2(_domain, _secret);
  CFMutableDictionaryRef query = item_query(_domain);
  OSStatus status = SecItemDelete(query);
  if (status != errSecSuccess && status != errSecItemNotFound) {
    CFRelease(query);
    fail_with(status);
  }
  CFDataRef secret = CFDataCreate(NULL, (const UInt8 *)String_val(_secret),
                                  caml_string_length(_secret));
  CFStringRef label = CFStringCreateWithCString(NULL, "tsync vault key",
                                                kCFStringEncodingUTF8);
  CFDictionarySetValue(query, kSecValueData, secret);
  CFDictionarySetValue(query, kSecAttrLabel, label);
  status = SecItemAdd(query, NULL);
  CFRelease(secret);
  CFRelease(label);
  CFRelease(query);
  if (status != errSecSuccess) fail_with(status);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_keychain_get(value _domain) {
  CAMLparam1(_domain);
  CAMLlocal2(_secret, _result);
  CFMutableDictionaryRef query = item_query(_domain);
  CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
  CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
  CFTypeRef found = NULL;
  OSStatus status = SecItemCopyMatching(query, &found);
  CFRelease(query);
  if (status == errSecItemNotFound) CAMLreturn(Val_none);
  if (status != errSecSuccess) fail_with(status);
  CFDataRef secret = (CFDataRef)found;
  CFIndex secret_length = CFDataGetLength(secret);
  _secret = caml_alloc_string(secret_length);
  memcpy(Bytes_val(_secret), CFDataGetBytePtr(secret), secret_length);
  CFRelease(found);
  _result = caml_alloc_some(_secret);
  CAMLreturn(_result);
}

CAMLprim value tsync_keychain_delete(value _domain) {
  CAMLparam1(_domain);
  CFMutableDictionaryRef query = item_query(_domain);
  OSStatus status = SecItemDelete(query);
  CFRelease(query);
  if (status != errSecSuccess && status != errSecItemNotFound) fail_with(status);
  CAMLreturn(Val_unit);
}
