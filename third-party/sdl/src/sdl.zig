const c = @cImport({
    @cInclude("SDL.h");
    @cInclude("SDL_syswm.h");
});
pub usingnamespace c;
