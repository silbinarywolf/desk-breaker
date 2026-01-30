//! NOTE(jae): 2026-01-20
//! Unused for now, we just handle Linux builds by getting 'zig cc' to compile via cmake

// NOTE(jae): 2024-10-24
// This configuration was copy-pasted out of my SDL_build_config.h file after creating it
// via the Linux build instructions. While this won't necessarily be accurate to all targets
// I figure it's a good start.
// const linuxConfig: SDLConfig = .{
//     .HAVE_GCC_ATOMICS = true,
//     // LibC headers
//     .HAVE_LIBC = true,
//     .HAVE_ALLOCA_H = true,
//     .HAVE_FLOAT_H = true,
//     .HAVE_ICONV_H = true,
//     .HAVE_INTTYPES_H = true,
//     .HAVE_LIMITS_H = true,
//     .HAVE_MALLOC_H = true,
//     .HAVE_MATH_H = true,
//     .HAVE_MEMORY_H = true,
//     .HAVE_SIGNAL_H = true,
//     .HAVE_STDARG_H = true,
//     .HAVE_STDBOOL_H = true,
//     .HAVE_STDDEF_H = true,
//     .HAVE_STDINT_H = true,
//     .HAVE_STDIO_H = true,
//     .HAVE_STDLIB_H = true,
//     .HAVE_STRINGS_H = true,
//     .HAVE_STRING_H = true,
//     .HAVE_SYS_TYPES_H = true,
//     .HAVE_WCHAR_H = true,
//
//     // C library functions
//     .HAVE_DLOPEN = true,
//     .HAVE_MALLOC = true,
//     .HAVE_CALLOC = true,
//     .HAVE_REALLOC = true,
//     .HAVE_FREE = true,
//     .HAVE_GETENV = true,
//     .HAVE_SETENV = true,
//     .HAVE_PUTENV = true,
//     .HAVE_UNSETENV = true,
//     .HAVE_ABS = true,
//     .HAVE_BCOPY = true,
//     .HAVE_MEMSET = true,
//     .HAVE_MEMCPY = true,
//     .HAVE_MEMMOVE = true,
//     .HAVE_MEMCMP = true,
//     .HAVE_WCSLEN = true,
//     .HAVE_WCSNLEN = true,
//     .HAVE_WCSLCPY = true,
//     .HAVE_WCSLCAT = true,
//     .HAVE_WCSDUP = true,
//     .HAVE_WCSSTR = true,
//     .HAVE_WCSCMP = true,
//     .HAVE_WCSNCMP = true,
//     .HAVE_WCSTOL = true,
//     .HAVE_STRLEN = true,
//     .HAVE_STRNLEN = true,
//     .HAVE_STRLCPY = true,
//     .HAVE_STRLCAT = true,
//     .HAVE_STRPBRK = true,
//     .HAVE_INDEX = true,
//     .HAVE_RINDEX = true,
//     .HAVE_STRCHR = true,
//     .HAVE_STRRCHR = true,
//     .HAVE_STRSTR = true,
//     .HAVE_STRTOK_R = true,
//     .HAVE_STRTOL = true,
//     .HAVE_STRTOUL = true,
//     .HAVE_STRTOLL = true,
//     .HAVE_STRTOULL = true,
//     .HAVE_STRTOD = true,
//     .HAVE_ATOI = true,
//     .HAVE_ATOF = true,
//     .HAVE_STRCMP = true,
//     .HAVE_STRNCMP = true,
//     .HAVE_STRCASESTR = true,
//     .HAVE_SSCANF = true,
//     .HAVE_VSSCANF = true,
//     .HAVE_VSNPRINTF = true,
//     .HAVE_ACOS = true,
//     .HAVE_ACOSF = true,
//     .HAVE_ASIN = true,
//     .HAVE_ASINF = true,
//     .HAVE_ATAN = true,
//     .HAVE_ATANF = true,
//     .HAVE_ATAN2 = true,
//     .HAVE_ATAN2F = true,
//     .HAVE_CEIL = true,
//     .HAVE_CEILF = true,
//     .HAVE_COPYSIGN = true,
//     .HAVE_COPYSIGNF = true,
//     .HAVE_COS = true,
//     .HAVE_COSF = true,
//     .HAVE_EXP = true,
//     .HAVE_EXPF = true,
//     .HAVE_FABS = true,
//     .HAVE_FABSF = true,
//     .HAVE_FLOOR = true,
//     .HAVE_FLOORF = true,
//     .HAVE_FMOD = true,
//     .HAVE_FMODF = true,
//     .HAVE_ISINF = true,
//     .HAVE_ISINFF = true,
//     .HAVE_ISINF_FLOAT_MACRO = true,
//     .HAVE_ISNAN = true,
//     .HAVE_ISNANF = true,
//     .HAVE_ISNAN_FLOAT_MACRO = true,
//     .HAVE_LOG = true,
//     .HAVE_LOGF = true,
//     .HAVE_LOG10 = true,
//     .HAVE_LOG10F = true,
//     .HAVE_LROUND = true,
//     .HAVE_LROUNDF = true,
//     .HAVE_MODF = true,
//     .HAVE_MODFF = true,
//     .HAVE_POW = true,
//     .HAVE_POWF = true,
//     .HAVE_ROUND = true,
//     .HAVE_ROUNDF = true,
//     .HAVE_SCALBN = true,
//     .HAVE_SCALBNF = true,
//     .HAVE_SIN = true,
//     .HAVE_SINF = true,
//     .HAVE_SQRT = true,
//     .HAVE_SQRTF = true,
//     .HAVE_TAN = true,
//     .HAVE_TANF = true,
//     .HAVE_TRUNC = true,
//     .HAVE_TRUNCF = true,
//     .HAVE_FOPEN64 = true,
//     .HAVE_FSEEKO = true,
//     .HAVE_FSEEKO64 = true,
//     .HAVE_MEMFD_CREATE = true,
//     .HAVE_POSIX_FALLOCATE = true,
//     .HAVE_SIGACTION = true,
//     .HAVE_SA_SIGACTION = true,
//     .HAVE_ST_MTIM = true,
//     .HAVE_SETJMP = true,
//     .HAVE_NANOSLEEP = true,
//     .HAVE_GMTIME_R = true,
//     .HAVE_LOCALTIME_R = true,
//     .HAVE_NL_LANGINFO = true,
//     .HAVE_SYSCONF = true,
//     .HAVE_CLOCK_GETTIME = true,
//     .HAVE_GETPAGESIZE = true,
//     .HAVE_ICONV = true,
//     .HAVE_PTHREAD_SETNAME_NP = true,
//     .HAVE_SEM_TIMEDWAIT = true,
//     .HAVE_GETAUXVAL = true,
//     .HAVE_POLL = true,
//     .HAVE__EXIT = true,
//     // End of C library functions
//
//     .HAVE_DBUS_DBUS_H = true,
//     .HAVE_FCITX = true,
//     .HAVE_IBUS_IBUS_H = true,
//     .HAVE_SYS_INOTIFY_H = true,
//     .HAVE_INOTIFY_INIT = true,
//     .HAVE_INOTIFY_INIT1 = true,
//     .HAVE_INOTIFY = true,
//     .HAVE_O_CLOEXEC = true,
//
//     .HAVE_LINUX_INPUT_H = true,
//     .HAVE_LIBUDEV_H = true,
//
//     .HAVE_LIBDECOR_H = true,
//     .SDL_LIBDECOR_VERSION_MAJOR = 0,
//     .SDL_LIBDECOR_VERSION_MINOR = 2,
//     .SDL_LIBDECOR_VERSION_PATCH = 2,
//
//     // .SDL_AUDIO_DRIVER_ALSA = true,
//     // .SDL_AUDIO_DRIVER_ALSA_DYNAMIC = "libasound.so.2",
//     .SDL_AUDIO_DRIVER_DISK = true,
//     .SDL_AUDIO_DRIVER_DUMMY = true,
//     // .SDL_AUDIO_DRIVER_JACK = true,
//     // .SDL_AUDIO_DRIVER_JACK_DYNAMIC = "libjack.so.0",
//
//     // Enable various input drivers
//     .SDL_INPUT_LINUXEV = true,
//     .SDL_INPUT_LINUXKD = true,
//     .SDL_JOYSTICK_HIDAPI = true,
//     .SDL_JOYSTICK_LINUX = true,
//     .SDL_JOYSTICK_VIRTUAL = true,
//     .SDL_HAPTIC_LINUX = true,
//     .SDL_UDEV_DYNAMIC = cMacroString("libudev.so.1"),
//
//     // Enable various process implementations
//     .SDL_PROCESS_POSIX = true,
//
//     // Enable various sensor drivers
//     .SDL_SENSOR_DUMMY = true,
//
//     // Enable various shared object loading systems
//     .SDL_LOADSO_DLOPEN = true,
//
//     // Enable various threading systems
//     .SDL_THREAD_PTHREAD = true,
//     .SDL_THREAD_PTHREAD_RECURSIVE_MUTEX = true,
//
//     // Enable various RTC systems
//     .SDL_TIME_UNIX = true,
//
//     // Enable various timer systems
//     .SDL_TIMER_UNIX = true,
//
//     // Enable various video drivers
//     .SDL_VIDEO_DRIVER_DUMMY = true,
//     // .SDL_VIDEO_DRIVER_KMSDRM = true, // TODO: Fix KMSDrm
//     // .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC = cMacroString("libdrm.so.2"),
//     // .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC_GBM = cMacroString("libgbm.so.1"),
//     // .SDL_VIDEO_DRIVER_OFFSCREEN = true,
//     // .SDL_VIDEO_DRIVER_WAYLAND = true, // TODO: Fix Wayland
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC = cMacroString("libwayland-client.so.0"),
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_CURSOR = cMacroString("libwayland-cursor.so.0"),
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_EGL = cMacroString("libwayland-egl.so.1"),
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_LIBDECOR = cMacroString("libdecor-0.so.0"),
//     // .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_XKBCOMMON = cMacroString("libxkbcommon.so.0"),
//     .SDL_VIDEO_DRIVER_X11 = true,
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC = cMacroString("libX11.so.6"),
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XEXT = cMacroString("libXext.so.6"), // TODO: Fix X11 ext
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XSS = cMacroString("libXss.so.1"), // TODO: Fix X11 xss
//     // .SDL_VIDEO_DRIVER_X11_HAS_XKBLOOKUPKEYSYM = true,
//     .SDL_VIDEO_DRIVER_X11_SUPPORTS_GENERIC_EVENTS = true,
//     // .SDL_VIDEO_DRIVER_X11_XCURSOR = true, // TODO: Fix X11-cursor
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XCURSOR = cMacroString("libXcursor.so.1"),
//     // .SDL_VIDEO_DRIVER_X11_XDBE = true, // TODO: Fix X11-dbe
//     // .SDL_VIDEO_DRIVER_X11_XFIXES = true, // TODO: Fix X11-xfixes
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XFIXES = cMacroString("libXfixes.so.3"),
//     // .SDL_VIDEO_DRIVER_X11_XINPUT2 = true,
//     // .SDL_VIDEO_DRIVER_X11_XINPUT2_SUPPORTS_MULTITOUCH = true,
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XINPUT2 = cMacroString("libXi.so.6"),
//     // .SDL_VIDEO_DRIVER_X11_XRANDR = true,
//     // .SDL_VIDEO_DRIVER_X11_DYNAMIC_XRANDR = cMacroString("libXrandr.so.2"),
//     // .SDL_VIDEO_DRIVER_X11_XSCRNSAVER = true,
//     // .SDL_VIDEO_DRIVER_X11_XSHAPE = true,
//
//     .SDL_VIDEO_RENDER_GPU = true,
//     .SDL_VIDEO_RENDER_VULKAN = true,
//     .SDL_VIDEO_RENDER_OGL = true,
//     .SDL_VIDEO_RENDER_OGL_ES2 = true,
//
//     // Enable OpenGL support
//     .SDL_VIDEO_OPENGL = true,
//     .SDL_VIDEO_OPENGL_ES = true,
//     .SDL_VIDEO_OPENGL_ES2 = true,
//     // .SDL_VIDEO_OPENGL_GLX = true, // TODO: add missing header
//     // .SDL_VIDEO_OPENGL_EGL = true, // TODO: need EGL/egl.h - src/video/x11/SDL_x11window
//
//     // Enable Vulkan support
//     .SDL_VIDEO_VULKAN = true,
//
//     // Enable GPU support
//     .SDL_GPU_VULKAN = true,
//
//     // Enable system power support
//     .SDL_POWER_LINUX = true,
//
//     // Whether SDL_DYNAMIC_API needs dlopen
//     .DYNAPI_NEEDS_DLOPEN = true,
//
//     // Enable ime support
//     .SDL_USE_IME = true,
//
//     // Configure use of intrinsics
//     .SDL_DISABLE_LSX = true,
//     .SDL_DISABLE_LASX = true,
//     .SDL_DISABLE_NEON = true,
// };
