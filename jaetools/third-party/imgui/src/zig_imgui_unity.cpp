/**
 * Compile all the ImGui code as a single-compilation unit (aka Unity build)
 */

#ifndef ZIG_IMGUI_UNITY_BUILD_IMPL
#define ZIG_IMGUI_UNITY_BUILD_IMPL

#include "imgui.cpp"
#include "imgui_tables.cpp"
#include "imgui_widgets.cpp"
#include "imgui_draw.cpp"
#include "imgui_demo.cpp"

#include "cimgui.cpp"

#ifdef IMGUI_ENABLE_FREETYPE
    #include "misc/freetype/imgui_freetype.cpp"
#endif

#ifdef ZIG_IMGUI_BACKEND_SDL3
    #include "backends/imgui_impl_sdl3.cpp"
    #include "backends/imgui_impl_sdlrenderer3.cpp"
#endif

#endif