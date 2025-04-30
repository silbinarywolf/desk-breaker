const std = @import("std");
const windows = std.os.windows;
const WINAPI = windows.WINAPI;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPCSTR = windows.LPCSTR;
const GetLastError = windows.GetLastError;
const Win32Error = windows.Win32Error;
const TRUE = windows.TRUE;
const FALSE = windows.FALSE;

const MutexHandle = enum(DWORD) {
    _,
};

const MutexError = error{ AlreadyExists, InvalidHandle, Unexpected };

pub fn createMutex(security_attributes: ?*const SECURITY_ATTRIBUTES, initial_owner: bool, name: [:0]const u8) MutexError!MutexHandle {
    const handle = CreateMutexA(security_attributes, if (initial_owner) TRUE else FALSE, name);
    const err = GetLastError();
    if (err != .SUCCESS) {
        return switch (GetLastError()) {
            .SUCCESS => unreachable,
            // If the mutex is a named mutex and the object existed before this function call,
            // the return value is a handle to the existing object, and the GetLastError function returns ERROR_ALREADY_EXISTS.
            .ALREADY_EXISTS => error.AlreadyExists,
            // If lpName matches the name of an existing event, semaphore, waitable timer, job, or file-mapping object,
            // the function fails and the GetLastError function returns ERROR_INVALID_HANDLE. This occurs because these objects share the same namespace.
            .INVALID_HANDLE => error.InvalidHandle,
            else => error.Unexpected,
        };
    }
    return @enumFromInt(handle);
}

/// Creates or opens a named or unnamed mutex object.
/// https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createmutexa
///
/// Useful for checking if only a single instance of an application is running:
/// https://stackoverflow.com/a/14176581
pub extern "kernel32" fn CreateMutexA(
    lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
    bInitialOwner: BOOL,
    lpName: LPCSTR,
) callconv(WINAPI) DWORD;
