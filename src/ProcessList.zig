const std = @import("std");
const builtin = @import("builtin");
const Dir = std.fs.Dir;
const PlatformProcessList = switch (builtin.os.tag) {
    .windows => WindowsProcessList,
    .linux => LinuxProcessList,
    else => DummyProcessList,
};

const log = std.log.scoped(.ProcessList);

impl: PlatformProcessList = undefined,

pub const is_supported = PlatformProcessList != DummyProcessList;

pub fn open() OpenError!Self {
    return .{
        .impl = try .open(),
    };
}

pub fn next(self: *Self) !?Entry {
    return self.impl.next();
}

pub fn close(self: *Self) void {
    self.impl.close();
    self.impl = undefined;
}

pub const Entry = struct {
    /// Full filepath of the where the process binary was executed from.
    ///
    /// Windows:
    /// - D:/ZigProjects/desk-breaker/.zig-cache/o/dcd778a906c554b03e5aa79391184607/desk-breaker
    /// - C:/SteamLibrary/steamapps/common/Hollow Knight Silksong/Hollow Knight Silksong
    ///
    /// Linux:
    /// - /var/home/USER/Documents/ZigProjects/desk-breaker/zig-out/bin/desk-breaker
    /// - /var/home/USER/.local/share/Steam/steamapps/common/Hollow Knight Silksong/Hollow Knight Silksong
    exe_filepath: []const u8,
};

pub const OpenError = error{ AccessDenied, OutOfMemory, Unexpected };

// Based of example code here: https://learn.microsoft.com/en-us/windows/win32/psapi/enumerating-all-processes
const WindowsProcessList = struct {
    const windows = std.os.windows;

    /// For my personal use, I had around ~250 or so.
    const MaxProcessList = 8192;

    processes: [MaxProcessList]windows.DWORD = undefined,
    index: u32,
    len: u32,
    it_exe_filepath: [std.fs.max_path_bytes:0]u8 = undefined,

    fn open() OpenError!@This() {
        var processes: [MaxProcessList]windows.DWORD = undefined;
        const max_processes_len_in_bytes: windows.DWORD = processes.len * @sizeOf(windows.DWORD);
        var given_processes_len_in_bytes: windows.DWORD = 0;
        if (K32EnumProcesses(&processes[0], max_processes_len_in_bytes, &given_processes_len_in_bytes) == 0)
            return windows.unexpectedError(windows.GetLastError());
        // From MDN: if lpcbNeeded equals cb (given), consider retrying the call with a larger array.
        if (given_processes_len_in_bytes >= max_processes_len_in_bytes) {
            return error.OutOfMemory;
        }
        return .{
            .processes = processes,
            .index = 0,
            .len = given_processes_len_in_bytes / @sizeOf(windows.DWORD),
        };
    }

    fn next(self: *@This()) !?Entry {
        while (self.index < self.len) : (self.index += 1) {
            const process_id = self.processes[self.index];
            if (process_id == 0) continue;

            const name: []const u8 = procblk: {
                const process_handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, windows.FALSE, process_id) orelse {
                    const win32err = windows.GetLastError();
                    switch (win32err) {
                        // If the specified process is the System process or one of the Client Server Run-Time Subsystem (CSRSS) processes,
                        // this function fails and the last error code is ERROR_ACCESS_DENIED because their access restrictions
                        // prevent user-level code from opening them.
                        // From MsoftDocs: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess
                        .ACCESS_DENIED => continue,
                        // If the specified process is the System Idle Process (0x00000000),
                        // the function fails and the last error code is ERROR_INVALID_PARAMETER
                        // From MsoftDocs: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess
                        .INVALID_PARAMETER => continue,
                        // NOTE(jae): 2025-12-20
                        // Not sure why this one happens but ignoring it seems to work fine for my use-case of "game is running" detection
                        .PARTIAL_COPY => continue,
                        else => return windows.unexpectedError(win32err),
                    }
                };
                defer windows.CloseHandle(process_handle);

                // Get full binary path of process
                var name: []u8 = nameblk: {
                    var name_buffer_len: u32 = windows.PATH_MAX_WIDE + 1;
                    var name_buffer: [windows.PATH_MAX_WIDE:0]u16 = undefined;
                    if (QueryFullProcessImageNameW(process_handle, 0, name_buffer[0..], &name_buffer_len) == 0) {
                        const err = windows.GetLastError();
                        switch (err) {
                            // Undocumented in 2025: If we can't do anything with it, just ignore it.
                            .ACCESS_DENIED => continue,
                            else => return windows.unexpectedError(windows.GetLastError()),
                        }
                    }
                    const name_u16 = name_buffer[0..name_buffer_len :0];
                    const len = try std.unicode.utf16LeToUtf8(&self.it_exe_filepath, name_u16[0..]);
                    const name = self.it_exe_filepath[0..len];
                    break :nameblk name;
                };

                // Make paths consistent with Linux and Mac API by replacing \ with / and removing '.exe' OR '.EXE'
                std.mem.replaceScalar(u8, name, '\\', '/');
                name = name[0 .. name.len - ".exe".len];
                break :procblk name;
            };

            // TODO(jae): 2025-12-20
            // Explore re-opening process if it's a 'javaw' application and if it has certain modules running, then assume
            // it is a game. Mostly want to explore this to make Minecraft Java Edition work.
            //
            // Initially I used this but this method requires a mix of "PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ"
            // and I'm wary of "PROCESS_VM_READ" being detected by Easy Anti-Cheat.
            //
            // if (std.mem.eql(u8, std.fs.path.basenamePosix(name), "javaw")) {
            //     const java_name: []u8 = nameblk: {
            //         // Read the first module, which tells us where the application EXE is
            //         var module_handle: windows.HMODULE = undefined;
            //         var needed: u32 = 0; // Got: 880 / 4 = 220, so some processes have a *lot* of modules
            //         if (K32EnumProcessModulesEx(process_handle, &module_handle, @sizeOf(@TypeOf(module_handle)), &needed, LIST_MODULES_ALL) == 0) {
            //             const err = windows.GetLastError();
            //             switch (err) {
            //                 // NOTE(jae): Occurred when running VRChat, might be due to Easy Anti-Cheat?
            //                 .ACCESS_DENIED => continue,
            //                 // NOTE(jae): PARTIAL_COPY occurs in some cases and I'm not sure why. I tried switching to 'K32EnumProcessModulesEx' as per: https://stackoverflow.com/a/11134981/5013410
            //                 // But still no luck. So let's skip this one.
            //                 .PARTIAL_COPY => continue,
            //                 else => return windows.unexpectedError(windows.GetLastError()),
            //             }
            //          }
            //
            //         std.debug.panic("needed: {}", .{needed});
            //
            //         var name_buffer: [windows.PATH_MAX_WIDE + 4:0]u16 = undefined;
            //         // GetModuleFileNameExW requires this prefix to be present
            //         @memcpy(name_buffer[0..4], &[_]u16{ '\\', '?', '?', '\\' });
            //
            //         // Get path and then convert to utf-8
            //         const len_u16 = windows.kernel32.GetModuleFileNameExW(process_handle, module_handle, @ptrCast(&name_buffer[4]), windows.PATH_MAX_WIDE);
            //         const name_u16 = name_buffer[0 .. len_u16 + 4 :0];
            //         const len = try std.unicode.utf16LeToUtf8(&self.it_exe_filepath, name_u16[4..]);
            //         const java_name = self.it_exe_filepath[0..len];
            //         // TODO: Detect prefix of '//?/' that occurs specifically for 'C:/WINDOWS/system32/conhost' only seemingly and remove it
            //         break :nameblk java_name;
            //     };
            //     @panic(java_name);
            // }

            self.index += 1;
            return .{
                .exe_filepath = name,
            };
        }
        return null;
    }

    fn close(self: *@This()) void {
        self.* = undefined;
    }

    /// [out] lpidProcess: A pointer to an array that receives the list of process identifiers.
    /// [in]  cb: The size of the pProcessIds array, in bytes.
    /// [out] lpcbNeeded: The number of bytes returned in the pProcessIds array.
    ///
    /// Source: https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-enumprocesses
    extern "kernel32" fn K32EnumProcesses(lpIdProcess: ?*windows.DWORD, cb: windows.DWORD, lpcbNeeded: ?*u32) callconv(.winapi) windows.BOOL;

    // NOTE(jae): 2025-12-20
    // Didn't end up needing these
    const PROCESS_VM_READ: windows.DWORD = 0x0010;
    // const PROCESS_QUERY_INFORMATION: windows.DWORD = 0x0400;

    /// Required to retrieve certain information about a process (see GetExitCodeProcess, GetPriorityClass, IsProcessInJob, QueryFullProcessImageName).
    ///
    /// Supports: Windows Vista or higher
    const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;

    /// https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess
    extern "kernel32" fn OpenProcess(dwDesiredAccess: windows.DWORD, bInheritHandle: windows.BOOL, dwProcessId: windows.DWORD) callconv(.winapi) ?windows.HANDLE;

    const PROCESS_NAME_NATIVE: windows.DWORD = 0x00000001;

    extern "kernel32" fn QueryFullProcessImageNameW(hProcess: windows.HANDLE, dwFlags: windows.DWORD, lpExeName: windows.LPWSTR, lpdwSize: *windows.DWORD) callconv(.winapi) windows.BOOL;

    // NOTE(jae): Does not support iteration of 32-bit EXE's from 64-bit EXE and vice versa
    // See: https://stackoverflow.com/a/11134981/5013410
    //
    // [in]  cb: The size of the lphModule array, in bytes.
    // [out] lpcbNeeded: The number of bytes returned in the pProcessIds array.
    // https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-enumprocessmodules
    // extern "kernel32" fn K32EnumProcessModules(hProcess: windows.HANDLE, lphModule: ?*windows.HMODULE, cb: windows.DWORD, lpcbNeeded: ?*u32) callconv(.winapi) windows.BOOL;

    // const LIST_MODULES_DEFAULT: windows.DWORD = 0x00;

    // https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-enumprocessmodulesex
    const LIST_MODULES_ALL: windows.DWORD = 0x03;

    // https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-enumprocessmodulesex?redirectedfrom=MSDN
    extern "kernel32" fn K32EnumProcessModulesEx(hProcess: windows.HANDLE, lphModule: ?*windows.HMODULE, cb: windows.DWORD, lpcbNeeded: ?*u32, dwFilterFlag: windows.DWORD) callconv(.winapi) windows.BOOL;
};

const LinuxProcessList = struct {
    proc: Dir,
    it: Dir.Iterator,
    it_exe_filepath: [std.fs.max_path_bytes:0]u8 = undefined,

    fn open() OpenError!@This() {
        var proc = std.fs.openDirAbsolute("/proc", .{
            .iterate = true,
        }) catch |err| switch (err) {
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.AccessDenied,
            else => unreachable,
        };
        const it = proc.iterate();
        return .{
            .proc = proc,
            .it = it,
            .it_exe_filepath = undefined,
        };
    }

    /// Borrowed how to get process list from this: https://stackoverflow.com/a/3797621
    /// Tested on Bazzite/KDE.
    fn next(self: *@This()) !?Entry {
        var buf_path: [64]u8 = undefined;
        while (try self.it.next()) |entry| {
            if (entry.name.len >= 1 and entry.name[0] >= '0' and entry.name[0] <= '9') {
                const proc_exe_path = try std.fmt.bufPrintZ(buf_path[0..], "{s}/exe", .{entry.name});
                const filepath = self.proc.readLinkZ(proc_exe_path, self.it_exe_filepath[0..]) catch |err| switch (err) {
                    // Ignore processes that
                    // - We don't have access to
                    // - That were closed / no longer exist
                    error.AccessDenied, error.FileNotFound => continue,
                    else => return err,
                };
                return .{
                    .exe_filepath = filepath,
                };
            }
        }
        return null;
    }

    fn close(self: *@This()) void {
        self.proc.close();
        self.* = undefined;
    }
};

const DummyProcessList = struct {
    fn open() OpenError!@This() {
        @compileError("Do not call open() as target is not supported. Check with 'isSupported' first.");
    }

    fn next(_: *@This()) !?Entry {
        @compileError("Do not call next() as target is not supported. Check with 'isSupported' first.");
    }

    fn close(_: *@This()) void {
        @compileError("Do not call close() as target is not supported. Check with 'isSupported' first.");
    }
};

const Self = @This();
