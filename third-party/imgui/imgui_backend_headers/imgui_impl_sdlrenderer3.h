// NOTE(jae): 2024-10-08
// Modified to compile with C, ie.
// - prefixing struct arguments with "struct" tag

// dear imgui: Renderer Backend for SDL_Renderer for SDL3
// (Requires: SDL 3.0.0+)

// (**IMPORTANT: SDL 3.0.0 is NOT YET RELEASED AND CURRENTLY HAS A FAST CHANGING API. THIS CODE BREAKS OFTEN AS SDL3 CHANGES.**)

// Note how SDL_Renderer is an _optional_ component of SDL3.
// For a multi-platform app consider using e.g. SDL+DirectX on Windows and SDL+OpenGL on Linux/OSX.
// If your application will want to render any non trivial amount of graphics other than UI,
// please be aware that SDL_Renderer currently offers a limited graphic API to the end-user and
// it might be difficult to step out of those boundaries.

// Implemented features:
//  [X] Renderer: User texture binding. Use 'SDL_Texture*' as ImTextureID. Read the FAQ about ImTextureID!
//  [X] Renderer: Large meshes support (64k+ vertices) with 16-bit indices.

// You can copy and use unmodified imgui_impl_* files in your project. See examples/ folder for examples of using this.
// Prefer including the entire imgui/ repository into your project (either as a copy or as a submodule), and only build the backends you need.
// Learn about Dear ImGui:
// - FAQ                  https://dearimgui.com/faq
// - Getting Started      https://dearimgui.com/getting-started
// - Documentation        https://dearimgui.com/docs (same as your local docs/ folder).
// - Introduction, links and more at the top of imgui.cpp

#pragma once
// NOTE(jae): 2024-10-08
// IMGUI_IMPL_API no longer needed as we just set "IMGUI_IMPL_API" to blank with a macro in the Zig build
// #include "imgui.h"      // IMGUI_IMPL_API
#ifndef IMGUI_DISABLE

struct SDL_Renderer;

// Follow "Getting Started" link and check examples/ folder to learn about using backends!
IMGUI_IMPL_API bool     ImGui_ImplSDLRenderer3_Init(struct SDL_Renderer* renderer);
IMGUI_IMPL_API void     ImGui_ImplSDLRenderer3_Shutdown(void);
IMGUI_IMPL_API void     ImGui_ImplSDLRenderer3_NewFrame(void);
IMGUI_IMPL_API void     ImGui_ImplSDLRenderer3_RenderDrawData(struct ImDrawData* draw_data, struct SDL_Renderer* renderer);

// Called by Init/NewFrame/Shutdown
IMGUI_IMPL_API bool     ImGui_ImplSDLRenderer3_CreateFontsTexture();
IMGUI_IMPL_API void     ImGui_ImplSDLRenderer3_DestroyFontsTexture();
IMGUI_IMPL_API bool     ImGui_ImplSDLRenderer3_CreateDeviceObjects();
IMGUI_IMPL_API void     ImGui_ImplSDLRenderer3_DestroyDeviceObjects();

#endif // #ifndef IMGUI_DISABLE
