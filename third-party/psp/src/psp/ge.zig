//! ge package is based off of the PSPSDK module "ge"
//! Source: https://github.com/pspdev/pspsdk/blob/20642f0ced70fb8b5294f73cef695681bd901d99/src/ge

/// Get the size of VRAM.
/// Returns the size of VRAM (in bytes).
pub extern fn sceGeEdramGetSize() callconv(.c) u32;

/// Get the eDRAM address.
/// Returns a pointer to the base of the eDRAM.
pub extern fn sceGeEdramGetAddr() callconv(.c) ?*anyopaque;
