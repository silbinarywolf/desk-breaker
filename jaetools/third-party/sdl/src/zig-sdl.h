/** Provide ZIG_SDL_MAIN_USE_CALLBACKS as explicit value to change SDL behaviour at comptime reliably.  */
#ifdef SDL_MAIN_USE_CALLBACKS
    #define ZIG_SDL_MAIN_USE_CALLBACKS 1
#else
    #define ZIG_SDL_MAIN_USE_CALLBACKS 0
#endif

/* #define SDL_DISABLE_OLD_NAMES 1 */   /* <-- We handle in Zig build system */
#include <SDL3/SDL.h>
#include <SDL3/SDL_revision.h>
/* #define SDL_MAIN_HANDLED 1 */        /* <-- We handle in Zig build system */
#include <SDL3/SDL_main.h>
