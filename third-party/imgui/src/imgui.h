#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS 1
#include "cimgui.h"

// IMGUI_IMPL_API: Make blank as it's not used here
#define IMGUI_IMPL_API 
// unknown type name 'bool'
#define bool int
#include "imgui_impl_sdl3.h"
#include "imgui_impl_sdlrenderer3.h"
