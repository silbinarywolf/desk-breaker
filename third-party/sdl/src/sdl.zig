const c = @cImport({
    @cInclude("SDL3/SDL.h");
    // @cInclude("SDL.h"); // SDL2 only
    // @cInclude("SDL_syswm.h"); // SDL2 only
});
pub usingnamespace c;
