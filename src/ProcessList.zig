const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Dir = std.fs.Dir;
const PlatformProcessList = switch (builtin.os.tag) {
    .windows => WindowsProcessList,
    .linux => LinuxProcessList,
    else => DummyProcessList,
};

const log = std.log.scoped(.ProcessList);

impl: PlatformProcessList = undefined,

pub const is_supported = PlatformProcessList != DummyProcessList;

pub fn init(self: *Self) !void {
    self.* = .{
        .impl = undefined,
    };
    try self.impl.init();
}

pub fn deinit(self: *Self) void {
    self.impl.deinit();
    self.impl = undefined;
}

pub fn open(self: *Self, allocator: std.mem.Allocator) OpenError!void {
    try self.impl.open(allocator);
}

pub fn next(self: *Self) !?Entry {
    return self.impl.next();
}

pub fn close(self: *Self) void {
    self.impl.close();
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
    /// (Optional) If the application is 'java' ('javaw' on Windows) will contain all the launch arguments.
    ///
    /// Linux:
    /// - -Xms512m -Xmx4096m -Duser.language=en -Djava.library.path=/var/home/USER/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/libraries/org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar:/var/home/USER/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/libraries/com/mojang/minecraft/1.21.11/minecraft-1.21.11-client.jar org.prismlauncher.EntryPoint
    jar_arguments: []const u8,
};

pub const OpenError = error{ AccessDenied, OutOfMemory, Unexpected };

// Based of example code here: https://learn.microsoft.com/en-us/windows/win32/psapi/enumerating-all-processes
const WindowsProcessList = struct {
    const windows = std.os.windows;
    iterator: Iterator = .empty,

    exe_filepath_buffer: [std.fs.max_path_bytes:0]u8,
    processes_buffer: [8192]windows.DWORD, // NOTE(jae): Arbitrarily chose 8192, on my machine I'm apparently running ~250 processes usually.
    wmi: Wmi,

    const Iterator = struct {
        pub const empty: Iterator = .{
            .allocator = undefined,
            .index = 0,
            .processes = &[0]windows.DWORD{},
            .command_line_arguments = &[0]u8{},
        };
        allocator: std.mem.Allocator,
        processes: []windows.DWORD,
        index: u32,
        command_line_arguments: []const u8,
    };

    fn init(self: *@This()) !void {
        self.* = .{
            .iterator = .empty,
            .exe_filepath_buffer = undefined,
            .processes_buffer = undefined,
            .wmi = .none,
        };
        try self.wmi.init();
    }

    fn deinit(self: *@This()) void {
        self.wmi.deinit();
        self.* = undefined;
    }

    fn open(self: *@This(), allocator: std.mem.Allocator) OpenError!void {
        const process_buffer_in_bytes = self.processes_buffer.len * @sizeOf(windows.DWORD);
        var given_processes_len_in_bytes: windows.DWORD = 0;
        if (kernel32.K32EnumProcesses(&self.processes_buffer[0], process_buffer_in_bytes, &given_processes_len_in_bytes) == 0)
            return windows.unexpectedError(windows.GetLastError());
        // From MDN: if lpcbNeeded equals cb (given), consider retrying the call with a larger array.
        if (given_processes_len_in_bytes >= process_buffer_in_bytes) {
            return error.OutOfMemory;
        }
        const processes = self.processes_buffer[0 .. given_processes_len_in_bytes / @sizeOf(windows.DWORD)];
        self.iterator = .{
            .allocator = allocator,
            .processes = processes,
            .index = 0,
            .command_line_arguments = &[0]u8{},
        };
    }

    fn next(self: *@This()) !?Entry {
        while (self.iterator.index < self.iterator.processes.len) : (self.iterator.index += 1) {
            const process_id = self.iterator.processes[self.iterator.index];
            if (process_id == 0) continue;

            const name: []const u8 = procblk: {
                const process_handle = kernel32.OpenProcess(kernel32.PROCESS_QUERY_LIMITED_INFORMATION, windows.FALSE, process_id) orelse {
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
                    if (kernel32.QueryFullProcessImageNameW(process_handle, 0, name_buffer[0..], &name_buffer_len) == 0) {
                        const err = windows.GetLastError();
                        switch (err) {
                            // Undocumented in 2025: If we can't do anything with it, just ignore it.
                            .ACCESS_DENIED => continue,
                            else => return windows.unexpectedError(windows.GetLastError()),
                        }
                    }
                    const name_u16 = name_buffer[0..name_buffer_len :0];
                    const len = std.unicode.wtf16LeToWtf8(&self.exe_filepath_buffer, name_u16[0..]);
                    const name = self.exe_filepath_buffer[0..len];
                    break :nameblk name;
                };

                // Make paths consistent with Linux and Mac API by replacing \ with / and removing '.exe' OR '.EXE'
                std.mem.replaceScalar(u8, name, '\\', '/');
                name = name[0 .. name.len - ".exe".len];
                break :procblk name;
            };

            // If we retrieved arguments last time, free the memory
            if (self.iterator.command_line_arguments.len > 0) {
                self.iterator.allocator.free(self.iterator.command_line_arguments);
                self.iterator.command_line_arguments = &[0]u8{};
            }

            // If a Java application, extract command-line arguments so we can inspect and know what application was launched
            if (std.mem.eql(u8, std.fs.path.basenamePosix(name), "javaw")) {
                self.iterator.command_line_arguments = try self.wmi.getCommandLineArguments(self.iterator.allocator, process_id);
            }

            self.iterator.index += 1;
            return .{
                .exe_filepath = name,
                .jar_arguments = self.iterator.command_line_arguments,
            };
        }
        return null;
    }

    fn close(self: *@This()) void {
        if (self.iterator.command_line_arguments.len > 0) {
            self.iterator.allocator.free(self.iterator.command_line_arguments);
            self.iterator.command_line_arguments = &[0]u8{};
        }
        self.iterator = .empty;
    }

    const Wmi = struct {
        services: ?*wbemuuid.IWbemServices,
        /// Is UTF-16 string of "WQL" in BSTR format.
        /// ie. SysAllocString(wtf8ToWtf16LeStringLiteral("WQL"))
        language: windows.BSTR,
        /// Is UTF-16 string of the process list query, ie. "SELECT CommandLine FROM Win32_Process where ProcessId = 4294967295"
        query: *[QueryProcessMaxBuffer.len:0]windows.WCHAR,

        const none: Wmi = .{
            .services = null,
            .language = undefined,
            .query = undefined,
        };

        const QueryProcess = "SELECT CommandLine FROM Win32_Process where ProcessId = {}";

        /// Appending '4294967295' allows fitting the largest uint32 in string format (4294967295) and then some in our query when we modify
        /// it and then pad it out with spaces.
        const QueryProcessMaxBuffer = std.unicode.wtf8ToWtf16LeStringLiteral(QueryProcess ++ "4294967295");

        fn init(self: *@This()) !void {
            // Initialize COM
            {
                var co_init_ex_hr = ole32.CoInitializeEx(null, ole32.COINIT_APARTMENTTHREADED);
                if (co_init_ex_hr == ole32.RPC_E_CHANGED_MODE) {
                    // If a previous call to CoInitializeEx specified an incompatible concurrency model for this thread, do it
                    // as COINIT_MULTITHREADED.
                    //
                    // Copies logic from SDL_windows.c
                    co_init_ex_hr = ole32.CoInitializeEx(null, ole32.COINIT_MULTITHREADED);
                }
                // - S_FALSE = The COM library is already initialized on this thread. Still requires calling "CoUninitialize"
                if (co_init_ex_hr != windows.S_OK and co_init_ex_hr != windows.S_FALSE) return windows.unexpectedError(windows.HRESULT_CODE(co_init_ex_hr));
            }
            errdefer ole32.CoUninitialize();

            // Init CoInitializeSecurity
            {
                const hr = ole32.CoInitializeSecurity(null, -1, null, null, ole32.RPC_C_AUTHN_LEVEL_DEFAULT, ole32.RPC_C_IMP_LEVEL_IMPERSONATE, null, ole32.EOAC_NONE, null);
                if (hr != windows.S_OK) return windows.unexpectedError(windows.HRESULT_CODE(hr));
            }

            // Connect to WMI
            // https://learn.microsoft.com/en-us/windows/win32/wmisdk/example-creating-a-wmi-application
            const locator: *wbemuuid.IWbemLocator = hrblk: {
                var result: *wbemuuid.IWbemLocator = undefined;
                const hr = ole32.CoCreateInstance(&wbemuuid.CLSID_WbemLocator, null, ole32.CLSCTX_INPROC_SERVER, &wbemuuid.IID_IWbemLocator, @ptrCast(&result));
                if (hr != windows.S_OK) return windows.unexpectedError(windows.HRESULT_CODE(hr));
                break :hrblk result;
            };
            errdefer _ = locator.lpVtbl.*.Release.?(locator);

            // BSTR strings we'll use (http://msdn.microsoft.com/en-us/library/ms221069.aspx)
            const language: windows.BSTR = try ole32.SysAllocString(std.unicode.wtf8ToWtf16LeStringLiteral("WQL"));
            errdefer ole32.SysFreeString(language);

            // NOTE(jae): 2025-12-22
            // Allocate the query string once at the start, then just modify the string query,
            // filling the end of it with spaces so that the prefixed-length of the BSTR doesn't need to change.
            const query_raw = try ole32.SysAllocString(QueryProcessMaxBuffer);
            errdefer ole32.SysFreeString(query_raw);
            const query: *[QueryProcessMaxBuffer.len:0]windows.WCHAR = query_raw[0..QueryProcessMaxBuffer.len :0];

            const services: *wbemuuid.IWbemServices = hrblk: {
                const resource: windows.BSTR = try ole32.SysAllocString(std.unicode.wtf8ToWtf16LeStringLiteral("ROOT\\CIMV2"));
                defer ole32.SysFreeString(resource);

                var r: *wbemuuid.IWbemServices = undefined;
                const hr = locator.lpVtbl.*.ConnectServer.?(locator, resource, null, null, null, 0, null, null, @ptrCast(&r));
                if (hr != windows.S_OK) return windows.unexpectedError(windows.HRESULT_CODE(hr));
                break :hrblk r;
            };
            errdefer _ = services.lpVtbl.*.Release.?(services);

            self.* = .{
                .services = services,
                .language = language,
                .query = query,
            };
        }

        fn deinit(self: *@This()) void {
            assert(self.services != null);
            if (self.services) |services| {
                _ = services.lpVtbl.*.Release.?(services);
            }
            ole32.SysFreeString(self.language);
            ole32.SysFreeString(self.query);
            ole32.CoUninitialize();
            self.* = undefined;
        }

        fn getCommandLineArguments(self: *@This(), allocator: std.mem.Allocator, process_id: windows.DWORD) ![]const u8 {
            const services = self.services orelse {
                return error.Unexpected;
            };

            // Replace existing UTF-16 query string with process id
            // and pad the end of the string with spaces to avoid changing the allocated length.
            // (BSTR is NOT a null-terimated UTF-16 string, it has a prefix that describes the slice length)
            {
                var buf_data: [QueryProcessMaxBuffer.len]u8 = undefined;
                const buf = try std.fmt.bufPrint(buf_data[0..], QueryProcess, .{process_id});
                const next_char = try std.unicode.wtf8ToWtf16Le(self.query[0..], buf);
                for (self.query[next_char..]) |*c| {
                    c.* = ' ';
                }
            }

            // Issue a WMI query
            const results: *wbemuuid.IEnumWbemClassObject = hrblk: {
                var r: *wbemuuid.IEnumWbemClassObject = undefined;
                const hr = services.lpVtbl.*.ExecQuery.?(services, self.language, self.query, wbemuuid.WBEM_FLAG_FORWARD_ONLY, null, @ptrCast(&r));
                if (hr != windows.S_OK) return windows.unexpectedError(windows.HRESULT_CODE(hr));
                break :hrblk r;
            };
            defer _ = results.lpVtbl.*.Release.?(results);

            // Enumerate the retrieved objects
            while (true) {
                const ms_wait = 5000;

                // Get next item
                // https://learn.microsoft.com/en-us/windows/win32/api/wbemcli/nf-wbemcli-ienumwbemclassobject-next
                var result: *wbemuuid.IWbemClassObject = undefined;
                var returned_count: windows.ULONG = 0;
                {
                    const hr = results.lpVtbl.*.Next.?(results, ms_wait, 1, @ptrCast(&result), &returned_count);
                    if (hr != windows.S_OK) break;
                }
                defer _ = result.lpVtbl.*.Release.?(result);
                if (returned_count == 0) break;

                // Get 'CommandLine' value
                //
                // Example outputs:
                // - .\.zig-cache\o\d21ec2a994a87d3d01f6126afdfc2140\desk-breaker.exe
                // - C:\zig\current\zig.exe build run
                // - \??\C:\WINDOWS\system32\conhost.exe 0x4
                // - "C:\Program Files\Git\bin\..\usr\bin\bash.exe" --init-file "c:\Microsoft VS Code\resources\app/out/vs/workbench/contrib/terminal/common/scripts/shellIntegration-bash.sh"
                // - exe: "C:\Microsoft VS Code\Code.exe" --type=utility --utility-sub-type=node.mojom.NodeService
                var column: wbemuuid.VARIANT = undefined;
                {
                    const hr = result.lpVtbl.*.Get.?(result, std.unicode.wtf8ToWtf16LeStringLiteral("CommandLine"), 0, &column, 0, 0);
                    if (hr != windows.S_OK) return windows.unexpectedError(windows.HRESULT_CODE(hr));
                }
                const column_ptr = column.unnamed_0.unnamed_0.unnamed_0.bstrVal;
                if (column_ptr == null) continue;
                const column_length = ole32.SysStringLen(column_ptr);
                const exe_and_command_line = column_ptr[0..column_length];

                // Skip the program application path, do this before allocating a new UTF-8 string to lower the size of the memory being allocated.
                const command_line_args_start_index: usize = findexeblk: {
                    var it = std.unicode.Wtf16LeIterator.init(exe_and_command_line);
                    // Iterate until we find '.exe' so we can *only* get the characters after the filepath
                    lexblk: while (it.nextCodepoint()) |char| {
                        // If not .exe, then continue searching
                        if (char != '.') continue;
                        if (it.nextCodepoint() != 'e') continue;
                        if (it.nextCodepoint() != 'x') continue;
                        if (it.nextCodepoint() != 'e') continue;

                        while (it.nextCodepoint()) |next_char| {
                            if (next_char != ' ') continue;
                            break :lexblk;
                        }
                        break :lexblk;
                    }
                    if (it.i == 0) break :findexeblk it.i; // Avoid div by 0
                    break :findexeblk it.i / 2; // Convert u8 index into u16 index
                };
                const command_line_args_wtf16 = exe_and_command_line[command_line_args_start_index..];
                if (command_line_args_wtf16.len == 0) continue;

                const command_line_args = try std.unicode.wtf16LeToWtf8Alloc(allocator, command_line_args_wtf16);
                errdefer allocator.free(command_line_args);

                return command_line_args;
            }
            return &[0]u8{};
        }
    };
};

const LinuxProcessList = struct {
    allocator: std.mem.Allocator,
    proc: ?Dir,
    it: Dir.Iterator,
    it_exe_filepath_buf: [std.fs.max_path_bytes + 32:0]u8,
    it_exe_and_args_buf: []u8,

    fn init(self: *@This()) !void {
        self.* = .{
            .proc = null,
            .it_exe_and_args_buf = &[0]u8{},
            .allocator = undefined,
            .it = undefined,
            .it_exe_filepath_buf = undefined,
        };
    }

    fn deinit(self: *@This()) void {
        // If forgot to call 'close' this will catch an issue
        assert(self.it_exe_and_args_buf.len == 0);
        assert(self.proc == null);
    }

    fn open(self: *@This(), allocator: std.mem.Allocator) OpenError!void {
        var proc = std.fs.openDirAbsolute("/proc", .{
            .iterate = true,
        }) catch |err| switch (err) {
            error.AccessDenied => return error.AccessDenied,
            error.FileNotFound => return error.AccessDenied,
            else => unreachable,
        };
        const it = proc.iterate();

        assert(self.it_exe_and_args_buf.len == 0);
        self.* = .{
            .allocator = allocator,
            .proc = proc,
            .it = it,
            .it_exe_filepath_buf = undefined,
            .it_exe_and_args_buf = &[0]u8{},
        };
    }

    /// Borrowed how to get process list from this: https://stackoverflow.com/a/3797621
    /// Tested on Bazzite/KDE.
    fn next(self: *@This()) !?Entry {
        const proc = self.proc orelse {
            return error.Unexpected;
        };
        var proc_pid_info_buf: [64]u8 = undefined;
        entryloop: while (try self.it.next()) |entry| {
            if (entry.name.len >= 1 and entry.name[0] >= '0' and entry.name[0] <= '9') {
                const proc_exe_path = try std.fmt.bufPrintZ(proc_pid_info_buf[0..], "{s}/exe", .{entry.name});
                const filepath = proc.readLinkZ(proc_exe_path, self.it_exe_filepath_buf[0..]) catch |err| switch (err) {
                    // Ignore processes that
                    // - We don't have access to
                    // - That were closed / no longer exist
                    error.AccessDenied, error.FileNotFound => continue :entryloop,
                    else => return err,
                };
                const basename = std.fs.path.basename(filepath);

                const jar_arguments: []const u8 = argblk: {
                    if (!std.mem.eql(u8, basename, "java")) {
                        break :argblk &[0]u8{};
                    }

                    // If we set 'jar_arguments' on the last iteration, free the buffer
                    self.freeExeAndArgsIfSet();

                    // If Java application, then extract the argument contains references to '.jar' files
                    const proc_args = try std.fmt.bufPrintZ(proc_pid_info_buf[0..], "{s}/cmdline", .{entry.name});
                    const allocator = self.allocator;
                    self.it_exe_and_args_buf = proc.readFileAlloc(allocator, proc_args, 2_097_152) catch |err| switch (err) {
                        // Ignore processes that
                        // - We don't have access to
                        // - That were closed / no longer exist
                        error.AccessDenied, error.FileNotFound => continue :entryloop,
                        else => return err,
                    };
                    errdefer {
                        allocator.free(self.it_exe_and_args_buf);
                        self.it_exe_and_args_buf = &[0]u8{};
                    }
                    const after_exe_path_index = std.mem.indexOfScalar(u8, self.it_exe_and_args_buf, '\x00') orelse {
                        allocator.free(self.it_exe_and_args_buf);
                        self.it_exe_and_args_buf = &[0]u8{};
                        break :argblk &[0]u8{};
                    };
                    const args = self.it_exe_and_args_buf[after_exe_path_index + 1 ..];
                    std.mem.replaceScalar(u8, args, '\x00', ' ');
                    break :argblk args;
                };
                return .{
                    .exe_filepath = filepath,
                    .jar_arguments = jar_arguments,
                };
            }
        }
        return null;
    }

    fn close(self: *@This()) void {
        self.freeExeAndArgsIfSet();
        if (self.proc) |*proc| {
            proc.close();
            self.proc = null;
        }
    }

    fn freeExeAndArgsIfSet(self: *@This()) void {
        if (self.it_exe_and_args_buf.len > 0) {
            const allocator = self.allocator;
            allocator.free(self.it_exe_and_args_buf);
            self.it_exe_and_args_buf = &[0]u8{};
        }
    }
};

const DummyProcessList = struct {
    fn init(_: *@This()) !void {}

    fn deinit(_: *@This()) void {}

    fn open(_: *@This(), _: std.mem.Allocator) OpenError!void {
        @compileError("Do not call open() as target is not supported. Check with 'isSupported' first.");
    }

    fn next(_: *@This()) !?Entry {
        @compileError("Do not call next() as target is not supported. Check with 'isSupported' first.");
    }

    fn close(_: *@This()) void {
        @compileError("Do not call close() as target is not supported. Check with 'isSupported' first.");
    }
};

const kernel32 = struct {
    const windows = std.os.windows;
    const DWORD = windows.DWORD;
    const UINT = windows.UINT;
    const WCHAR = windows.WCHAR;
    const CHAR = windows.CHAR;
    const BOOL = windows.BOOL;

    pub extern "kernel32" fn WideCharToMultiByte(CodePage: UINT, dwFlags: DWORD, lpWideCharStr: [*c]const WCHAR, cchWideChar: c_int, lpMultiByteStr: [*c]CHAR, cbMultiByte: c_int, lpDefaultChar: [*c]const CHAR, lpUsedDefaultChar: [*c]BOOL) callconv(.winapi) c_int;

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

const ole32 = struct {
    const windows = std.os.windows;
    const LPVOID = windows.LPVOID;
    const DWORD = windows.DWORD;
    const HRESULT = windows.HRESULT;
    const OLECHAR = u16;
    const BSTR = windows.BSTR;
    const UINT = windows.UINT;
    const GUID = windows.GUID;

    pub const COINIT_APARTMENTTHREADED: DWORD = 2;
    pub const COINIT_MULTITHREADED: DWORD = 0;
    pub const COINIT_DISABLE_OLE1DDE: DWORD = 4;
    pub const COINIT_SPEED_OVER_MEMORY: DWORD = 8;

    pub const RPC_E_CHANGED_MODE: c_long = -0x7FFEFEFA; // ie. 0x80010106;

    pub const EOAC_NONE: c_int = 0;

    pub const RPC_C_AUTHN_LEVEL_DEFAULT: c_int = 0;
    pub const RPC_C_IMP_LEVEL_IMPERSONATE: c_int = 3;

    pub const CLSCTX_INPROC_SERVER: c_int = 1;

    pub const SOLE_AUTHENTICATION_SERVICE = extern struct {
        dwAuthnSvc: DWORD = 0,
        dwAuthzSvc: DWORD = 0,
        pPrincipalName: [*c]OLECHAR = std.mem.zeroes([*c]OLECHAR),
        hr: HRESULT = 0,
    };

    pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) HRESULT;
    pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    pub extern "ole32" fn CoInitializeSecurity(pSecDesc: ?*anyopaque, cAuthSvc: c_long, asAuthSvc: [*c]SOLE_AUTHENTICATION_SERVICE, pReserved1: ?*anyopaque, dwAuthnLevel: DWORD, dwImpLevel: DWORD, pAuthList: ?*anyopaque, dwCapabilities: DWORD, pReserved3: ?*anyopaque) callconv(.winapi) HRESULT;
    pub extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*unknwn.IUnknown, dwClsContext: DWORD, riid: *const GUID, ppv: ?*anyopaque) callconv(.winapi) HRESULT;

    pub fn SysAllocString(str: [*c]const OLECHAR) error{OutOfMemory}!BSTR {
        const r = oleaut32.SysAllocString(str);
        if (str != null and r == null) return error.OutOfMemory;
        return r;
    }
    pub extern "oleaut32" fn SysFreeString(BSTR) callconv(.winapi) void;
    pub extern "oleaut32" fn SysStringLen(BSTR) callconv(.winapi) UINT;

    const oleaut32 = struct {
        /// If successful, returns the string. If psz is a zero-length string, returns a zero-length BSTR.
        /// If psz is NULL or insufficient memory exists, returns NULL.
        pub extern "oleaut32" fn SysAllocString([*c]const OLECHAR) [*c]windows.WCHAR;
    };

    // const CP_UTF8: c_long = 65001;
};

/// https://learn.microsoft.com/en-us/windows/win32/api/unknwn/
pub const unknwn = struct {
    const windows = std.os.windows;

    pub const QueryInterface = *const fn (*IUnknown, *const windows.GUID, [*c]?*anyopaque) callconv(.c) windows.HRESULT;
    pub const AddRef = *const fn (*IUnknown, *const windows.GUID, [*c]?*anyopaque) callconv(.c) windows.HRESULT;
    pub const Release = **const fn (*IUnknown) callconv(.c) windows.ULONG;

    /// https://learn.microsoft.com/en-us/windows/win32/api/unknwn/nn-unknwn-iunknown
    pub const IUnknown = extern struct {
        vtbl: ?*VTable,

        pub const VTable = extern struct {
            QueryInterface: QueryInterface,
            AddRef: AddRef,
            Release: Release,
        };
    };
};

pub const wbemuuid = struct {
    const windows = std.os.windows;

    /// The IWbemServices interface is used by clients and providers to access WMI services. The interface is implemented by WMI and WMI providers, and is the primary WMI interface.
    const c = @cImport({
        @cDefine("WIN32_LEAN_AND_MEAN", "1");
        @cDefine("_WIN32_WINNT", "0x0400");
        @cDefine("_WIN32_DCOM", "1");
        @cInclude("wbemcli.h");
    });

    pub const WBEM_FLAG_FORWARD_ONLY: c_int = 32;

    pub extern "wbemuuid" const CLSID_WbemLocator: windows.GUID;
    pub extern "wbemuuid" const IID_IWbemLocator: windows.GUID;

    pub const IWbemLocator = c.IWbemLocator;
    pub const IWbemServices = c.IWbemServices;
    pub const IEnumWbemClassObject = c.IEnumWbemClassObject;
    pub const IWbemClassObject = c.IWbemClassObject;

    pub const VARIANT = c.VARIANT;
};

const Self = @This();
