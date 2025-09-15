const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;

/// NOTE: Required so this can be imported by other build.zig files
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // psp
    {
        _ = b.addModule("psp", .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/psp/root.zig"),
        });
        // b.installArtifact(b.addLibrary(.{
        //     .name = "psp",
        //     .root_module = psp,
        //     .linkage = .static,
        // }));
    }

    // NOTE(jae): 2025-07-20
    // Below was an attempt to compile everything from the PSP SDK with Zig.
    // Not worth it due to linker issues + vfpu assembly instructions specific to the PSP in C-code not compiling, etc

    // const pspsdk_dep = b.lazyDependency("pspsdk", .{}) orelse return;
    // const pspsdk_src_path = pspsdk_dep.path("src");

    // pspsdk/gu
    // {
    //     const pspgu = b.createModule(.{
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     pspgu.addCSourceFiles(.{
    //         .root = pspsdk_src_path.path(b, "gu"),
    //         .files = &pspgu_src_files,
    //         .flags = &pspsdk_flags,
    //     });
    //     pspgu.addCMacro("_PSP_FW_VERSION", pspsdk_fw_version);
    //     // TODO: Tighten this up by using dependencies in build.zig.zon
    //     // for (psp_include_paths) |include_path| {
    //     //     lib.addIncludePath(pspsdk_src_path.path(b, include_path));
    //     // }
    //     b.installArtifact(b.addLibrary(.{
    //         .name = "pspgu",
    //         .root_module = pspgu,
    //         .linkage = .static,
    //     }));
    // }

    // pspsdk/vfpu
    // const pspvfpu_lib = blk: {
    //     const pspvfpu = b.createModule(.{
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     pspvfpu.addCSourceFiles(.{
    //         .root = pspsdk_src_path.path(b, "vfpu"),
    //         .files = &.{"pspvfpu.c"},
    //         .flags = &.{"-std=gnu99"},
    //     });
    //     // TODO: Tighten this up by using dependencies in build.zig.zon
    //     // for (psp_include_paths) |include_path| {
    //     //     lib.addIncludePath(pspsdk_src_path.path(b, include_path));
    //     // }
    //     const pspvfpu_lib = b.addLibrary(.{
    //         .name = "pspvfpu",
    //         .root_module = pspvfpu,
    //         .linkage = .static,
    //     });
    //     b.installArtifact(pspvfpu_lib);
    //     break :blk pspvfpu_lib;
    // };

    // libpspvram
    // if (b.lazyDependency("libpspvram", .{
    //     .target = target,
    //     .optimize = optimize,
    // })) |pspvram_dep| {
    //     const pspvram = b.createModule(.{
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     pspvram.addCSourceFiles(.{
    //         .root = pspvram_dep.path(""),
    //         .files = &.{
    //             "vram.c",
    //             // "vramalloc.c", // For libpspvramalloc.a
    //         },
    //         .flags = &pspsdk_flags,
    //     });
    //     pspvram.addCMacro("_PSP_FW_VERSION", pspsdk_fw_version);
    //     // TODO: Tighten this up by using dependencies in build.zig.zon
    //     // for (psp_include_paths) |include_path| {
    //     //     lib.addIncludePath(pspsdk_src_path.path(b, include_path));
    //     // }
    //     b.installArtifact(b.addLibrary(.{
    //         .name = "pspvram",
    //         .root_module = pspvram,
    //         .linkage = .static,
    //     }));
    // }

    // GL
    // if (b.lazyDependency("pspgl", .{
    //     .target = target,
    //     .optimize = optimize,
    // })) |pspgl_dep| {
    //     const gl = b.createModule(.{
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     gl.addCSourceFiles(.{
    //         .root = pspgl_dep.path(""),
    //         .files = &pspgl_src_files,
    //         .flags = &.{"-std=gnu99"}, // "-fsingle-precision-constant" is not supported
    //     });
    //     gl.addIncludePath(pspgl_dep.path(""));
    //     // Fix pspgl/eglQueryString.c
    //     // Source: https://www.reddit.com/r/cpp_questions/comments/1kxrhnt/comment/murkeky/
    //     gl.addCMacro("__DATE__", "\"date_not_available_for_clang\"");
    //     gl.addCMacro("__TIME__", "\"time_not_available_for_clang\"");
    //     // TODO: Actually generate proctable functions we need(?)
    //     gl.addIncludePath(b.path("src/pspgl/pspgl_proctable_include"));
    //     const gl_lib = b.addLibrary(.{
    //         .name = "GL",
    //         .root_module = gl,
    //         .linkage = .static,
    //     });
    //     gl_lib.linkLibrary(pspvfpu_lib);
    //     b.installArtifact(gl_lib);
    // }
}

pub const Tools = @import("src/pspbuild/Tools.zig");

const psp_include_paths = Tools.psp_sdk_include_paths;

/// Flags Source: https://github.com/pspdev/pspsdk/blob/e9905349fbc5b685b8badacff32a3283d2942500/configure.ac#L76
const pspsdk_flags = [_][]const u8{ "-mno-gpopt", "-Wall", "-Werror" };

/// FW version Source: https://github.com/pspdev/pspsdk/blob/e9905349fbc5b685b8badacff32a3283d2942500/configure.ac#L76
const pspsdk_fw_version = "600";

/// List all "gu" module files:
/// https://github.com/pspdev/pspsdk/tree/e9905349fbc5b685b8badacff32a3283d2942500/src/gu
const pspgu_src_files = [_][]const u8{
    "guInternal.c",
    "sceGuAlphaFunc.c",
    "sceGuAmbient.c",
    "sceGuAmbientColor.c",
    "sceGuBeginObject.c",
    "sceGuBlendFunc.c",
    "sceGuBoneMatrix.c",
    "sceGuBreak.c",
    "sceGuCallList.c",
    "sceGuCallMode.c",
    "sceGuCheckList.c",
    "sceGuClear.c",
    "sceGuClearColor.c",
    "sceGuClearDepth.c",
    "sceGuClearStencil.c",
    "sceGuClutLoad.c",
    "sceGuClutMode.c",
    "sceGuColor.c",
    "sceGuColorFunc.c",
    "sceGuColorMaterial.c",
    "sceGuContinue.c",
    "sceGuCopyImage.c",
    "sceGuDepthBuffer.c",
    "sceGuDepthFunc.c",
    "sceGuDepthMask.c",
    "sceGuDepthOffset.c",
    "sceGuDepthRange.c",
    "sceGuDisable.c",
    "sceGuDispBuffer.c",
    "sceGuDisplay.c",
    "sceGuDrawArray.c",
    "sceGuDrawArrayN.c",
    "sceGuDrawBezier.c",
    "sceGuDrawBuffer.c",
    "sceGuDrawBufferList.c",
    "sceGuDrawSpline.c",
    "sceGuEnable.c",
    "sceGuEndObject.c",
    "sceGuFinish.c",
    "sceGuFinishId.c",
    "sceGuFog.c",
    "sceGuFrontFace.c",
    "sceGuGetAllStatus.c",
    "sceGuGetMemory.c",
    "sceGuGetStatus.c",
    "sceGuInit.c",
    "sceGuLight.c",
    "sceGuLightAtt.c",
    "sceGuLightColor.c",
    "sceGuLightMode.c",
    "sceGuLightSpot.c",
    "sceGuLogicalOp.c",
    "sceGuMaterial.c",
    "sceGuModelColor.c",
    "sceGuMorphWeight.c",
    "sceGuOffset.c",
    "sceGuPatchDivide.c",
    "sceGuPatchFrontFace.c",
    "sceGuPatchPrim.c",
    "sceGuPixelMask.c",
    "sceGuScissor.c",
    "sceGuSendCommandf.c",
    "sceGuSendCommandi.c",
    "sceGuSendList.c",
    "sceGuSetAllStatus.c",
    "sceGuSetCallback.c",
    "sceGuSetDither.c",
    "sceGuSetMatrix.c",
    "sceGuSetStatus.c",
    "sceGuShadeModel.c",
    "sceGuSignal.c",
    "sceGuSpecular.c",
    "sceGuStart.c",
    "sceGuStencilFunc.c",
    "sceGuStencilOp.c",
    "sceGuSwapBuffers.c",
    "sceGuSync.c",
    "sceGuTerm.c",
    "sceGuTexEnvColor.c",
    "sceGuTexFilter.c",
    "sceGuTexFlush.c",
    "sceGuTexFunc.c",
    "sceGuTexImage.c",
    "sceGuTexLevelMode.c",
    "sceGuTexMapMode.c",
    "sceGuTexMode.c",
    "sceGuTexOffset.c",
    "sceGuTexProjMapMode.c",
    "sceGuTexScale.c",
    "sceGuTexSlope.c",
    "sceGuTexSync.c",
    "sceGuTexWrap.c",
    "sceGuViewport.c",
    "vram.c",
};

const pspgl_src_files = [_][]const u8{
    "eglBindTexImage.c",
    "eglChooseConfig.c",
    "eglCreateContext.c",
    "eglCreatePbufferSurface.c",
    "eglCreateWindowSurface.c",
    "eglDestroyContext.c",
    "eglDestroySurface.c",
    "eglGetConfigAttrib.c",
    "eglGetConfigs.c",
    "eglGetDisplay.c",
    "eglGetError.c",
    "eglGetProcAddress.c",
    "eglInitialize.c",
    "eglMakeCurrent.c",
    "eglQueryString.c",
    "eglSwapBuffers.c",
    "eglSwapInterval.c",
    "eglTerminate.c",
    "eglWaitGL.c",
    "eglWaitNative.c",
    "glAlphaFunc.c",
    "glArrayElement.c",
    "glBegin.c",
    "glBindBufferARB.c",
    "glBindTexture.c",
    "glBlendEquation.c",
    "glBlendFunc.c",
    "glBufferDataARB.c",
    "glBufferSubDataARB.c",
    "glClear.c",
    "glClearColor.c",
    "glClearDepth.c",
    "glClearDepthf.c",
    "glClearStencil.c",
    "glColor.c",
    "glColorMask.c",
    "glColorPointer.c",
    "glColorTable.c",
    "glCompressedTexImage2D.c",
    "glCopyTexImage2D.c",
    "glCullFace.c",
    "glDeleteBuffersARB.c",
    // "glDeleteLists.c", // Commented out in PSPGL makefile
    "glDeleteTextures.c",
    "glDepthFunc.c",
    "glDepthMask.c",
    "glDepthRange.c",
    "glDepthRangef.c",
    "glDisplayList.c",
    "glDrawArrays.c",
    "glDrawBezierArrays.c",
    "glDrawBezierElements.c",
    "glDrawBuffer.c",
    "glDrawElements.c",
    "glDrawSplineArrays.c",
    "glDrawSplineElements.c",
    "glEnable.c",
    "glEnableClientState.c",
    "glEnd.c",
    "glFinish.c",
    "glFlush.c",
    "glFog.c",
    "glFrontFace.c",
    "glFrustum.c",
    "glFrustumf.c",
    "glGenBuffersARB.c",
    // "glGenLists.c", // Commented out in pspgl Makefile
    "glGenTextures.c",
    "glGetBufferSubDataARB.c",
    "glGetError.c",
    "glGetFloatv.c",
    "glGetIntegerv.c",
    "glGetString.c",
    "glInterleavedArrays.c",
    "glIsBufferARB.c",
    // "glIsList.c", // Commented out in pspgl Makefile
    "glIsTexture.c",
    "glLight.c",
    "glLightModel.c",
    "glLineWidth.c",
    "glLoadIdentity.c",
    "glLoadMatrixf.c",
    "glLockArraysEXT.c",
    "glLogicOp.c",
    "glMapBufferARB.c",
    "glMaterial.c",
    "glMatrixMode.c",
    "glMultMatrixf.c",
    "glNormal.c",
    "glNormald.c",
    "glNormalPointer.c",
    "glOrtho.c",
    "glOrthof.c",
    "glPixelStore.c",
    "glPolygonMode.c",
    "glPolygonOffset.c",
    "glPopMatrix.c",
    "glPrioritizeTextures.c",
    "glPushAttrib.c",
    "glPushClientAttrib.c",
    "glPushMatrix.c",
    "glReadBuffer.c",
    "glReadPixels.c",
    "glRotatef.c",
    "glScaled.c",
    "glScalef.c",
    "glScissor.c",
    "glShadeModel.c",
    "glStencilFunc.c",
    "glStencilMask.c",
    "glStencilOp.c",
    "glTexCoord.c",
    "glTexCoordPointer.c",
    "glTexEnv.c",
    "glTexGen.c",
    "glTexImage2D.c",
    "glTexParameter.c",
    "glTexSubImage2D.c",
    "glTranslatef.c",
    "gluBuildMipmaps.c",
    "gluLookAt.c",
    "gluLookAtf.c",
    "glUnmapBufferARB.c",
    "gluPerspective.c",
    "gluPerspectivef.c",
    "gluScaleImage.c",
    "glut_shapes.c",
    "glut.c",
    "glVertex.c",
    "glVertexd.c",
    "glVertexi.c",
    "glVertexPointer.c",
    "glViewport.c",
    "glWeightPointerPSP.c",
    "pspgl_buffers.c",
    "pspgl_context.c",
    "pspgl_copy_pixels.c",
    "pspgl_dlist.c",
    "pspgl_ge_init.c",
    "pspgl_hash.c",
    "pspgl_matrix.c",
    "pspgl_misc.c",
    "pspgl_stats.c",
    "pspgl_texobj.c",
    "pspgl_varray_draw_elts.c",
    "pspgl_varray_draw_range_elts.c",
    "pspgl_varray_draw.c",
    "pspgl_varray.c",
    "pspgl_vidmem.c",
    "pspglu.c",
    // "swiz.c",
};
