#import <Foundation/Foundation.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include "environ.h"
#include "utils.h"

#include "bridge_tbl.h"
#include "osm_bridge.h"
#include "osmesa_internal.h"

static osmesa_library handle;
static dispatch_semaphore_t osmBlitSemaphore;

void dlsym_OSMesa() {
    void* dl_handle = dlopen([NSString stringWithFormat:@"@rpath/%s", getenv("POJAV_RENDERER")].UTF8String, RTLD_GLOBAL);
    assert(dl_handle);
    handle.OSMesaMakeCurrent = dlsym(dl_handle,"OSMesaMakeCurrent");
    handle.OSMesaGetCurrentContext = dlsym(dl_handle,"OSMesaGetCurrentContext");
    handle.OSMesaCreateContext = dlsym(dl_handle, "OSMesaCreateContext");
    handle.OSMesaCreateContextExt = dlsym(dl_handle, "OSMesaCreateContextExt");
    handle.OSMesaCreateContextAttribs = dlsym(dl_handle, "OSMesaCreateContextAttribs");
    handle.OSMesaDestroyContext = dlsym(dl_handle, "OSMesaDestroyContext");
    handle.OSMesaPixelStore = dlsym(dl_handle,"OSMesaPixelStore");
    handle.glGetString = dlsym(dl_handle,"glGetString");
    handle.glClearColor = dlsym(dl_handle, "glClearColor");
    handle.glClear = dlsym(dl_handle,"glClear");
    handle.glFinish = dlsym(dl_handle,"glFinish");
}

bool osm_init() {
    dlsym_OSMesa();
    if (!osmBlitSemaphore) {
        osmBlitSemaphore = dispatch_semaphore_create(1);
    }
    return true; // no more specific initialization required
}

static OSMesaContext osm_create_context_with_fallback(OSMesaContext shareContext) {
    if (handle.OSMesaCreateContextAttribs) {
        const int attribs41[] = {
            OSMESA_FORMAT, OSMESA_RGBA,
            OSMESA_DEPTH_BITS, 24,
            OSMESA_STENCIL_BITS, 8,
            OSMESA_ACCUM_BITS, 0,
            OSMESA_PROFILE, OSMESA_COMPAT_PROFILE,
            OSMESA_CONTEXT_MAJOR_VERSION, 4,
            OSMESA_CONTEXT_MINOR_VERSION, 1,
            0
        };
        OSMesaContext ctx = handle.OSMesaCreateContextAttribs(attribs41, shareContext);
        if (ctx) return ctx;

        const int attribs33[] = {
            OSMESA_FORMAT, OSMESA_RGBA,
            OSMESA_DEPTH_BITS, 24,
            OSMESA_STENCIL_BITS, 8,
            OSMESA_ACCUM_BITS, 0,
            OSMESA_PROFILE, OSMESA_COMPAT_PROFILE,
            OSMESA_CONTEXT_MAJOR_VERSION, 3,
            OSMESA_CONTEXT_MINOR_VERSION, 3,
            0
        };
        ctx = handle.OSMesaCreateContextAttribs(attribs33, shareContext);
        if (ctx) return ctx;

        const int attribs30[] = {
            OSMESA_FORMAT, OSMESA_RGBA,
            OSMESA_DEPTH_BITS, 16,
            OSMESA_STENCIL_BITS, 0,
            OSMESA_ACCUM_BITS, 0,
            OSMESA_PROFILE, OSMESA_COMPAT_PROFILE,
            OSMESA_CONTEXT_MAJOR_VERSION, 3,
            OSMESA_CONTEXT_MINOR_VERSION, 0,
            0
        };
        ctx = handle.OSMesaCreateContextAttribs(attribs30, shareContext);
        if (ctx) return ctx;
    }

    if (handle.OSMesaCreateContextExt) {
        OSMesaContext ctx = handle.OSMesaCreateContextExt(GL_RGBA, 24, 8, 0, shareContext);
        if (ctx) return ctx;
        ctx = handle.OSMesaCreateContextExt(GL_RGBA, 16, 0, 0, shareContext);
        if (ctx) return ctx;
    }

    if (handle.OSMesaCreateContext) {
        return handle.OSMesaCreateContext(GL_RGBA, shareContext);
    }

    return NULL;
}

osm_render_window_t* osm_init_context(osm_render_window_t* share) {
    osm_render_window_t* render_window = calloc(1, sizeof(osm_render_window_t));
    OSMesaContext context = osm_create_context_with_fallback(share ? share->context : NULL);
    if(!context) {
        NSLog(@"OSMBridge: FAILED to create context");
        free(render_window);
        return NULL;
    }
    render_window->context = context;
    return render_window;
}

void osm_apply_current_ll() {
    if (currentBundle->osm.width == windowWidth && currentBundle->osm.height == windowHeight) {
        return;
    }

    currentBundle->osm.width = windowWidth;
    currentBundle->osm.height = windowHeight;
    currentBundle->osm.buffer = reallocf(currentBundle->osm.buffer, windowWidth * windowHeight * 4);
    if (!currentBundle->osm.buffer) {
        NSLog(@"OSMBridge: failed to allocate color buffer");
        return;
    }

    if (!handle.OSMesaMakeCurrent(currentBundle->osm.context, currentBundle->osm.buffer, GL_UNSIGNED_BYTE, currentBundle->osm.width, currentBundle->osm.height)) {
        NSLog(@"OSMBridge: OSMesaMakeCurrent failed");
        return;
    }
    handle.OSMesaPixelStore(OSMESA_ROW_LENGTH, currentBundle->osm.width);
    handle.OSMesaPixelStore(OSMESA_Y_UP, 0);
}

void osm_make_current(osm_render_window_t* bundle) {
    if(!bundle) {
        if (!currentBundle) return;
        free(currentBundle->osm.buffer);
        if (currentBundle->osm.color_space) {
            CGColorSpaceRelease(currentBundle->osm.color_space);
        }
        if (handle.OSMesaDestroyContext && currentBundle->osm.context) {
            handle.OSMesaDestroyContext(currentBundle->osm.context);
        }
        currentBundle->osm.buffer = NULL;
        currentBundle->osm.color_space = NULL;
        currentBundle->osm.context = NULL;
        currentBundle->osm.width = currentBundle->osm.height = 0;
        currentBundle = NULL;
        //technically this does nothing as its not possible to unbind a context in OSMesa
        handle.OSMesaMakeCurrent(NULL, NULL, 0, 0, 0);
        return;
    }

    currentBundle = (basic_render_window_t *)bundle;
    if (!currentBundle->osm.color_space) {
        currentBundle->osm.color_space = CGColorSpaceCreateDeviceRGB();
    }
    osm_apply_current_ll();
    if (handle.glGetString) {
        const GLubyte *glVersion = handle.glGetString(GL_VERSION);
        if (glVersion) {
            NSDebugLog(@"OSMBridge: OpenGL version = %s", glVersion);
        }
    }
}

void osm_swap_buffers() {
    if (!currentBundle) return;
    if (!osmBlitSemaphore) {
        osmBlitSemaphore = dispatch_semaphore_create(1);
    }
    if (dispatch_semaphore_wait(osmBlitSemaphore, DISPATCH_TIME_NOW) != 0) {
        // Drop frame if a previous blit is still in flight on main thread.
        return;
    }

    osm_apply_current_ll();
    if (!currentBundle || !currentBundle->osm.buffer || !currentBundle->osm.color_space) {
        dispatch_semaphore_signal(osmBlitSemaphore);
        return;
    }
    handle.glFinish(); // this will force osmesa to write the last rendered image into the buffer
    osm_render_window_t bundle = currentBundle->osm;
    CGColorSpaceRef colorSpace = CGColorSpaceRetain(bundle.color_space);
    dispatch_async(dispatch_get_main_queue(), ^{
    CGDataProviderRef bitmapProvider = CGDataProviderCreateWithData(NULL, bundle.buffer, bundle.width * bundle.height * 4, NULL);
    CGImageRef bitmap = CGImageCreate(bundle.width, bundle.height, 8, 32, 4 * bundle.width, colorSpace, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault, bitmapProvider, NULL, FALSE, kCGRenderingIntentDefault);
    SurfaceViewController.surface.layer.contents = (__bridge id)bitmap;
    CGImageRelease(bitmap);
    CGDataProviderRelease(bitmapProvider);
    CGColorSpaceRelease(colorSpace);
    dispatch_semaphore_signal(osmBlitSemaphore);
    });
}

void osm_swap_interval(int swapInterval) {
    // Nothing to do here
}

void osm_terminate() {
    if (!currentBundle) return;
    if (osmBlitSemaphore) {
        dispatch_semaphore_wait(osmBlitSemaphore, DISPATCH_TIME_FOREVER);
        dispatch_semaphore_signal(osmBlitSemaphore);
    }
    if (currentBundle->osm.buffer) {
        free(currentBundle->osm.buffer);
        currentBundle->osm.buffer = NULL;
    }
    if (currentBundle->osm.color_space) {
        CGColorSpaceRelease(currentBundle->osm.color_space);
        currentBundle->osm.color_space = NULL;
    }
    if (handle.OSMesaDestroyContext && currentBundle->osm.context) {
        handle.OSMesaDestroyContext(currentBundle->osm.context);
        currentBundle->osm.context = NULL;
    }
    currentBundle = NULL;
}

void set_osm_bridge_tbl() {
    br_init = osm_init;
    br_init_context = (br_init_context_t) osm_init_context;
    br_make_current = (br_make_current_t) osm_make_current;
    br_swap_buffers = osm_swap_buffers;
    br_swap_interval = osm_swap_interval;
    br_terminate = osm_terminate;
}
