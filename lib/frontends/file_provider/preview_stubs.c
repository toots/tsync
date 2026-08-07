/* A small picture of a file, made by QuickLook — the same generators the Finder
 * shows, so cover art, poster frames, documents and images all arrive without a
 * case here per format.
 *
 * This is the reason a preview belongs to the daemon rather than the menu bar
 * app: the app is sandboxed, and a file in the shared container is "data from
 * other apps" to it, while QuickLook here opens it directly. */

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

#include <stdlib.h>
#include <string.h>

/* A generator that never answers must not hold this thread: it is one of the
 * pool Lwt hands out, and the caller would wait for it forever. */
static const int64_t timeout_seconds = 10;

/* Encoded to PNG whatever the source was, so the caller has one thing to
 * decode. */
static unsigned char *encode_png(CGImageRef image, size_t *length)
{
    unsigned char *bytes = NULL;
    CFMutableDataRef png = CFDataCreateMutable(NULL, 0);
    if (png == NULL)
        return NULL;

    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData(png, CFSTR("public.png"), 1, NULL);
    if (destination != NULL) {
        CGImageDestinationAddImage(destination, image, NULL);
        if (CGImageDestinationFinalize(destination)) {
            *length = (size_t)CFDataGetLength(png);
            bytes = malloc(*length);
            if (bytes != NULL)
                memcpy(bytes, CFDataGetBytePtr(png), *length);
        }
        CFRelease(destination);
    }
    CFRelease(png);
    return bytes;
}

/* Returns NULL, leaving *length untouched, for a file QuickLook has no preview
 * for. */
static unsigned char *render_thumbnail(const char *path, long max_side,
                                       size_t *length)
{
    @autoreleasepool {
        NSString *name = [NSString stringWithUTF8String:path];
        if (name == nil)
            return NULL;

        QLThumbnailGenerationRequest *request =
            [[QLThumbnailGenerationRequest alloc]
                initWithFileAtURL:[NSURL fileURLWithPath:name]
                             size:CGSizeMake(max_side, max_side)
                            scale:1.0
              /* A real look at the contents, not the generic document icon
               * that "all" would fall back to: the caller draws its own icon,
               * and would rather know there was nothing to show. */
              representationTypes:
                  QLThumbnailGenerationRequestRepresentationTypeThumbnail];

        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        __block CGImageRef image = NULL;
        [[QLThumbnailGenerator sharedGenerator]
            generateBestRepresentationForRequest:request
                               completionHandler:^(
                                   QLThumbnailRepresentation *thumbnail,
                                   NSError *error) {
                                 (void)error;
                                 if (thumbnail != nil)
                                     image = CGImageRetain(thumbnail.CGImage);
                                 dispatch_semaphore_signal(ready);
                               }];

        if (dispatch_semaphore_wait(
                ready, dispatch_time(DISPATCH_TIME_NOW,
                                     timeout_seconds * NSEC_PER_SEC)) != 0)
            return NULL;
        if (image == NULL)
            return NULL;

        unsigned char *bytes = encode_png(image, length);
        CGImageRelease(image);
        return bytes;
    }
}

/* The empty string stands for "no picture": the caller runs on the event loop
 * and an exception here would have to be caught there anyway. */
CAMLprim value caml_preview_thumbnail(value _path, value _max_side)
{
    CAMLparam2(_path, _max_side);
    CAMLlocal1(_result);
    char *path;
    long max_side;
    unsigned char *bytes;
    size_t length = 0;

    /* Copied before the lock goes, since the heap may move underneath. */
    path = strdup(String_val(_path));
    max_side = Long_val(_max_side);
    if (path == NULL)
        CAMLreturn(caml_alloc_initialized_string(0, ""));

    caml_release_runtime_system();
    bytes = render_thumbnail(path, max_side, &length);
    free(path);
    caml_acquire_runtime_system();

    if (bytes == NULL)
        CAMLreturn(caml_alloc_initialized_string(0, ""));
    _result = caml_alloc_initialized_string(length, (const char *)bytes);
    free(bytes);
    CAMLreturn(_result);
}
