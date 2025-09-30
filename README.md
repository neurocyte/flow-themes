# flow-themes
Themes compiler for Flow-Control, the text editor

## Requirements

 - zig 0.15.1
 - hjson (installed in your PATH)

## Build

`zig build`

This will download and compile all the themes and create a zig module
in `zig-out` that can be referenced as a dependency from another project's
`build.zig.zon`.
