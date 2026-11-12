comptime {
    @compileError(
        \\vscode_theme needs the cbor module. Add it in your build.zig:
        \\    themes_dep.module("vscode_theme").addImport("cbor", cbor_mod);
    );
}
