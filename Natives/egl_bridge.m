#import "SurfaceViewController.h"

#include "jni.h"
#include <assert.h>
#include <dlfcn.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

#include "EGL/egl.h"
#include "EGL/eglext.h"
#include "GL/osmesa.h"

#include "glfw_keycodes.h"
#include "ctxbridges/bridge_tbl.h"
#include "ctxbridges/osmesa_internal.h"
#include "utils.h"

int clientAPI;

void JNI_LWJGL_changeRenderer(const char* value_c) {
    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    jstring key = (*env)->NewStringUTF(env, "org.lwjgl.opengl.libname");
    jstring value = (*env)->NewStringUTF(env, value_c);
    jclass clazz = (*env)->FindClass(env, "java/lang/System");
    jmethodID method = (*env)->GetStaticMethodID(env, clazz, "setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    (*env)->CallStaticObjectMethod(env, clazz, method, key, value);
}

void pojavTerminate() {
    CallbackBridge_nativeSetInputReady(NO);
    if (!br_terminate) return;
    br_terminate();
}

void* pojavGetCurrentContext() {
    return br_get_current();
}

int pojavInit(BOOL useStackQueue) {
    clientAPI = GLFW_OPENGL_API;
    isInputReady = 1;
    isUseStackQueueCall = useStackQueue;
    return JNI_TRUE;
}

int pojavInitOpenGL() {
    NSString *renderer = NSProcessInfo.processInfo.environment[@"POJAV_RENDERER"];
    if (renderer.length == 0) {
        renderer = @"auto";
    }
    unsetenv("GALLIUM_DRIVER");
    unsetenv("MESA_LOADER_DRIVER_OVERRIDE");
    BOOL shaderWorkload = [NSProcessInfo.processInfo.environment[@"POJAV_SHADER_WORKLOAD"] boolValue];
    BOOL isAuto = [renderer isEqualToString:@"auto"];
    if (isAuto) {
        if (shaderWorkload) {
            renderer = @ RENDERER_NAME_VK_ZINK;
            setenv("POJAV_RENDERER", renderer.UTF8String, 1);
            setenv("GALLIUM_DRIVER", "zink", 1);
            setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1);
            set_osm_bridge_tbl();
        } else {
            // Generic auto fallback stays on gl4es for old/mod-light setups.
            renderer = @ RENDERER_NAME_GL4ES;
            setenv("POJAV_RENDERER", renderer.UTF8String, 1);
            set_gl_bridge_tbl();
        }
    } else if ([renderer isEqualToString:@ RENDERER_NAME_GL4ES]) {
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES]) {
        renderer = @ RENDERER_NAME_MOBILEGLUES;
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MTL_ANGLE]) {
        set_gl_bridge_tbl();
    } else if ([renderer hasPrefix:@"libOSMesa"]) {
        setenv("GALLIUM_DRIVER","zink",1);
        setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1);
        set_osm_bridge_tbl();
    } else {
        // Safety fallback for invalid renderer values.
        renderer = @ RENDERER_NAME_GL4ES;
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);
        set_gl_bridge_tbl();
    }
    JNI_LWJGL_changeRenderer(renderer.UTF8String);
    // Preload renderer library
    dlopen([NSString stringWithFormat:@"@rpath/%@", renderer].UTF8String, RTLD_GLOBAL);

    BOOL initialized = br_init();
    if (!initialized && ![renderer hasPrefix:@"libOSMesa"]) {
        NSDebugLog(@"EGLBridge: renderer %@ failed to initialize, falling back to Zink", renderer);
        renderer = @ RENDERER_NAME_VK_ZINK;
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);
        setenv("GALLIUM_DRIVER", "zink", 1);
        setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1);
        set_osm_bridge_tbl();
        JNI_LWJGL_changeRenderer(renderer.UTF8String);
        dlopen([NSString stringWithFormat:@"@rpath/%@", renderer].UTF8String, RTLD_GLOBAL);
        initialized = br_init();
    }
    return !initialized;
    //return 0;
}

void pojavSetWindowHint(int hint, int value) {
    const char *rendererEnv = getenv("POJAV_RENDERER");
    if (hint == GLFW_CLIENT_API) {
        clientAPI = value;
    } else if (rendererEnv != NULL && strcmp(rendererEnv, "auto")==0 && hint == GLFW_CONTEXT_VERSION_MAJOR) {
        BOOL shaderWorkload = [NSProcessInfo.processInfo.environment[@"POJAV_SHADER_WORKLOAD"] boolValue];
        switch (value) {
            case 1:
            case 2:
                setenv("POJAV_RENDERER", RENDERER_NAME_GL4ES, 1);
                JNI_LWJGL_changeRenderer(RENDERER_NAME_GL4ES);
                break;
            case 3:
                if (shaderWorkload) {
                    setenv("POJAV_RENDERER", RENDERER_NAME_VK_ZINK, 1);
                    setenv("GALLIUM_DRIVER", "zink", 1);
                    setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1);
                    JNI_LWJGL_changeRenderer(RENDERER_NAME_VK_ZINK);
                } else {
                    setenv("POJAV_RENDERER", RENDERER_NAME_MOBILEGLUES, 1);
                    JNI_LWJGL_changeRenderer(RENDERER_NAME_MOBILEGLUES);
                }
                break;
            default:
                setenv("POJAV_RENDERER", RENDERER_NAME_VK_ZINK, 1);
                setenv("GALLIUM_DRIVER", "zink", 1);
                setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1);
                JNI_LWJGL_changeRenderer(RENDERER_NAME_VK_ZINK);
                break;
        }
    }
}

void pojavSwapBuffers() {
    br_swap_buffers();
}

void pojavMakeCurrent(basic_render_window_t* window) {
    br_make_current(window);
}

void* pojavCreateContext(basic_render_window_t* contextSrc) {
    if (clientAPI == GLFW_NO_API) {
        // Game has selected Vulkan API to render
        return (__bridge void *)SurfaceViewController.surface.layer;
    }

    static BOOL inited = NO;
    if (!inited) {
        inited = YES;
        pojavInitOpenGL();
    }

    return br_init_context(contextSrc);
}

void pojavSwapInterval(int interval) {
    if (!br_swap_interval) return;
    br_swap_interval(interval);
}
