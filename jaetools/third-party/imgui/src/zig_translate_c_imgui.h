// Zig Translate-C header file

#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS 1
#include "cimgui.h"

// IMGUI_IMPL_API: Make blank as it's not used here
#define IMGUI_IMPL_API

// Define bool
#include <stdbool.h>

#ifdef ZIG_IMGUI_BACKEND_SDL3
    #include "imgui_impl_sdl3.h"
    #include "imgui_impl_sdlrenderer3.h"
#endif
