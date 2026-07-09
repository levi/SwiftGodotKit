#include "apple_plugin_stubs.h"

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE
__attribute__((weak)) void godot_apple_embedded_plugins_initialize() {}
__attribute__((weak)) void godot_apple_embedded_plugins_deinitialize() {}
#endif

// --- SDL compatibility stubs ---

extern "C" {
    bool SDL_IsAppleTV(void) {
        return false;
    }

    bool SDL_IsIPad(void) {
        return true;
    }
}
