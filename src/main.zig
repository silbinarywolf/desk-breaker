const de = @import("de");
const App = @import("App.zig");

pub const de_options: de.Options = .{
    .application_type = App,
    .platform_type = .sdl_zig,
};

pub const main = de.main;
