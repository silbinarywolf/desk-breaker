/*
 * PSP Link file
 * - Borrowed from: https://github.com/rust-lang/rust/blob/1af256fe8aea69909e1bf068506a29ebbf82eccf/compiler/rustc_target/src/spec/targets/mipsel_sony_psp_linker_script.ld
 * - PSP SDK GCC Linkfile: https://github.com/pspdev/pspsdk/blob/8a3bef901248232063fe82ec1bbe6d46108d4961/src/base/linkfile.prx.in
 *
 * Research
 * - LD Scripting: https://sourceware.org/binutils/docs/ld/
 * - Symbol Processing: https://maskray.me/blog/2021-06-20-symbol-processing
 */

ENTRY(module_start)
/* SEARCH_DIR("@PSPDEV_LIBDIR@"); */
SECTIONS
{
  /* PRX format requires text to begin at 0 */
  .text 0 : { *(.text .text.*) }

  /* Sort stubs for convenient ordering */
  .sceStub.text : { *(.sceStub.text) *(SORT(.sceStub.text.*)) }

  /* PSP import library stub sections. Bundles together `.lib.stub.entry.*`
   * sections for better `--gc-sections` support. */
  .lib.stub.top : { *(.lib.stub.top) }
  .lib.stub :     { *(.lib.stub) *(.lib.stub.entry.*) }
  .lib.stub.btm : { *(.lib.stub.btm) }

  /* Keep these sections around, even though they may appear unused to the linker */
  .lib.ent.top :  { KEEP(*(.lib.ent.top)) }
  .lib.ent :      { KEEP(*(.lib.ent)) }
  .lib.ent.btm :  { KEEP(*(.lib.ent.btm)) }

  .eh_frame_hdr : { *(.eh_frame_hdr) }

  /* Add symbols for LLVM's libunwind */
  __eh_frame_hdr_start = SIZEOF(.eh_frame_hdr) > 0 ? ADDR(.eh_frame_hdr) : 0;
  __eh_frame_hdr_end = SIZEOF(.eh_frame_hdr) > 0 ? . : 0;
  .eh_frame :
  {
    __eh_frame_start = .;
    KEEP(*(.eh_frame))
    __eh_frame_end = .;
  }

  /* These are explicitly listed to avoid being merged into .rodata */
  .rodata.sceResident : { *(.rodata.sceResident) *(.rodata.sceResident.*) }
  .rodata.sceModuleInfo : { *(.rodata.sceModuleInfo) }
  /* Sort NIDs for convenient ordering */
  .rodata.sceNid : { *(.rodata.sceNid) *(SORT(.rodata.sceNid.*)) }

  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  .gcc_except_table : { *(.gcc_except_table .gcc_except_table.*) }
  .bss : { *(.bss .bss.*) }

  /DISCARD/ : { *(.rel.sceStub.text .MIPS.abiflags .reginfo .gnu.version .gnu.version_d .gnu.version_r .note.GNU-stack) }
  /DISCARD/ : { *(.comment .comment.*) }
}

/* VERSION
{
  {
    global: foobar;
    local: *;
  };
}
*/