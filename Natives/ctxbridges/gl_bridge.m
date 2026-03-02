#import <Foundation/Foundation.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include "bridge_tbl.h"
#include "environ.h"
#include "gl_bridge.h"
#include "utils.h"

static EGLDisplay g_EglDisplay;
static egl_library handle;

static BOOL gl_choose_config(EGLint renderableType, EGLint depthBits, EGLint stencilBits, EGLConfig *outConfig) {
    const EGLint attribs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, depthBits,
        EGL_STENCIL_SIZE, stencilBits,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT|EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, renderableType,
        EGL_NONE
    };

    EGLint numConfigs = 0;
    EGLConfig config = NULL;
    if (!handle.eglChooseConfig(g_EglDisplay, attribs, &config, 1, &numConfigs)) {
        return NO;
    }
    if (numConfigs <= 0 || !config) {
        return NO;
    }
    *outConfig = config;
    return YES;
}

static EGLContext gl_create_context(EGLConfig config, EGLContext sharedContext, BOOL desktopGL) {
    if (desktopGL) {
        return handle.eglCreateContext(g_EglDisplay, config, sharedContext, NULL);
    }

    const EGLint ctxAttribsES3[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    EGLContext context = handle.eglCreateContext(g_EglDisplay, config, sharedContext, ctxAttribsES3);
    if (context) return context;

    const EGLint ctxAttribsES2[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };
    return handle.eglCreateContext(g_EglDisplay, config, sharedContext, ctxAttribsES2);
}

void dlsym_EGL() {
    void* dl_handle = dlopen("@rpath/libtinygl4angle.dylib", RTLD_GLOBAL);
    assert(dl_handle);
    handle.eglBindAPI = dlsym(dl_handle, "eglBindAPI");
    handle.eglChooseConfig = dlsym(dl_handle, "eglChooseConfig");
    handle.eglCreateContext = dlsym(dl_handle, "eglCreateContext");
    handle.eglCreateWindowSurface = dlsym(dl_handle, "eglCreateWindowSurface");
    handle.eglDestroyContext = dlsym(dl_handle, "eglDestroyContext");
    handle.eglDestroySurface = dlsym(dl_handle, "eglDestroySurface");
    handle.eglGetConfigAttrib = dlsym(dl_handle, "eglGetConfigAttrib");
    handle.eglGetCurrentContext = dlsym(dl_handle, "eglGetCurrentContext");
    handle.eglGetDisplay = dlsym(dl_handle, "eglGetDisplay");
    handle.eglGetError = dlsym(dl_handle, "eglGetError");
    handle.eglGetPlatformDisplay = dlsym(dl_handle, "eglGetPlatformDisplay");
    handle.eglInitialize = dlsym(dl_handle, "eglInitialize");
    handle.eglMakeCurrent = dlsym(dl_handle, "eglMakeCurrent");
    handle.eglSwapBuffers = dlsym(dl_handle, "eglSwapBuffers");
    handle.eglReleaseThread = dlsym(dl_handle, "eglReleaseThread");
    handle.eglSwapInterval = dlsym(dl_handle, "eglSwapInterval");
    handle.eglTerminate = dlsym(dl_handle, "eglTerminate");
    handle.eglGetCurrentSurface = dlsym(dl_handle, "eglGetCurrentSurface");
}

static bool gl_init() {
    dlsym_EGL();

    g_EglDisplay = handle.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_EglDisplay == EGL_NO_DISPLAY) {
        NSDebugLog(@"EGLBridge: eglGetDisplay(EGL_DEFAULT_DISPLAY) returned EGL_NO_DISPLAY");
        return false;
    }
    if (!handle.eglInitialize(g_EglDisplay, NULL, NULL)) {
        NSDebugLog(@"EGLBridge: Error eglInitialize() failed: 0x%x", handle.eglGetError());
        return false;
    }
    return true;
}

gl_render_window_t* gl_init_context(gl_render_window_t *share) {
    gl_render_window_t* bundle = calloc(1, sizeof(gl_render_window_t));

    NSString *renderer = NSProcessInfo.processInfo.environment[@"POJAV_RENDERER"];
    BOOL shaderWorkload = [NSProcessInfo.processInfo.environment[@"POJAV_SHADER_WORKLOAD"] boolValue];
    BOOL preferDesktopGL = [renderer isEqualToString:@ RENDERER_NAME_MTL_ANGLE] ||
        ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES] && shaderWorkload);

    BOOL modes[] = { preferDesktopGL, !preferDesktopGL };
    BOOL initialized = NO;
    for (int modeIndex = 0; modeIndex < 2 && !initialized; modeIndex++) {
        BOOL desktopGL = modes[modeIndex];
        if (modeIndex == 1 && modes[0] == modes[1]) {
            continue;
        }

        EGLint renderableTypes[2];
        int renderableCount = 0;
        if (desktopGL) {
            renderableTypes[renderableCount++] = EGL_OPENGL_BIT;
        } else {
            renderableTypes[renderableCount++] = EGL_OPENGL_ES3_BIT;
            renderableTypes[renderableCount++] = EGL_OPENGL_ES2_BIT;
        }

        for (int rt = 0; rt < renderableCount && !initialized; rt++) {
            EGLint renderableType = renderableTypes[rt];
            EGLConfig config = NULL;
            if (!gl_choose_config(renderableType, 24, 8, &config) &&
                !gl_choose_config(renderableType, 24, 0, &config) &&
                !gl_choose_config(renderableType, 16, 0, &config)) {
                continue;
            }

            EGLBoolean bindResult = desktopGL ?
                handle.eglBindAPI(EGL_OPENGL_API) :
                handle.eglBindAPI(EGL_OPENGL_ES_API);
            if (!bindResult) {
                NSDebugLog(@"EGLBridge: bind API failed for mode=%@ err=0x%x", desktopGL ? @"desktop" : @"es", handle.eglGetError());
                continue;
            }

            EGLSurface surface = handle.eglCreateWindowSurface(
                g_EglDisplay, config, (__bridge EGLNativeWindowType)SurfaceViewController.surface.layer, NULL);
            if (!surface) {
                NSDebugLog(@"EGLBridge: eglCreateWindowSurface failed: 0x%x", handle.eglGetError());
                continue;
            }

            EGLContext sharedContext = share ? share->context : EGL_NO_CONTEXT;
            EGLContext context = gl_create_context(config, sharedContext, desktopGL);
            if (!context) {
                NSDebugLog(@"EGLBridge: eglCreateContext failed for mode=%@, rt=0x%x err=0x%x",
                    desktopGL ? @"desktop" : @"es", renderableType, handle.eglGetError());
                handle.eglDestroySurface(g_EglDisplay, surface);
                continue;
            }

            bundle->config = config;
            bundle->surface = surface;
            bundle->context = context;
            initialized = YES;
            NSDebugLog(@"EGLBridge: Created context with mode=%@, renderable=0x%x",
                desktopGL ? @"desktop" : @"es", renderableType);
        }
    }

    if (!initialized) {
        free(bundle);
        return NULL;
    }
    return bundle;
}

void gl_make_current(gl_render_window_t* bundle) {
    if(!bundle) {
        if(handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            currentBundle = NULL;
        }
        return;
    }

    if(handle.eglMakeCurrent(g_EglDisplay, bundle->surface, bundle->surface, bundle->context)) {
        currentBundle = (basic_render_window_t *)bundle;
    } else {
        NSLog(@"EGLBridge: eglMakeCurrent returned with error: 0x%x", handle.eglGetError());
    }
}

void gl_swap_buffers() {
    if (!currentBundle) return;
    if (!handle.eglSwapBuffers(g_EglDisplay, currentBundle->gl.surface) && handle.eglGetError() == EGL_BAD_SURFACE) {
        NSLog(@"eglSwapBuffers error 0x%x", handle.eglGetError());
        //stopSwapBuffers = true;
        //closeGLFWWindow();
    }
}

void gl_swap_interval(int swapInterval) {
    handle.eglSwapInterval(g_EglDisplay, swapInterval);
}

void gl_terminate() {
    if (!currentBundle) return;
    handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    handle.eglDestroySurface(g_EglDisplay, currentBundle->gl.surface);
    handle.eglDestroyContext(g_EglDisplay, currentBundle->gl.context);
    handle.eglTerminate(g_EglDisplay);
    handle.eglReleaseThread();
    free(currentBundle);
    currentBundle = nil;
}

void set_gl_bridge_tbl() {
    br_init = gl_init;
    br_init_context = (br_init_context_t) gl_init_context;
    br_make_current = (br_make_current_t) gl_make_current;
    br_swap_buffers = gl_swap_buffers;
    br_swap_interval = gl_swap_interval;
    br_terminate = gl_terminate;
}
