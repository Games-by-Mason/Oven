# Oven

An asset pipeline for my games. Uses the Zig build system to bake assets to their in engine formats.

## Motivation

Interchange formats are a great way to get data into a game engine, but typically suboptimal choices for shipping in a build.

Take images for example. You likely want to store your original images in a high resolution lossless format, whereas you may want to ship a lower resolution with GPU friendly compression.

You could hand process all your assets from interchange to in engine formats, but eats away at your iteration time, and is just generally a waste of time when the chore could be automated.

Furthermore, information is lost when you do this manually--ideally you'd like a record of exactly what processing you applied to an asset, so that if you want to substitute in an updated version of that asset, you don't need to figure out the right options all over again.

See also [It's Not About The Technology - Game Engines are Art Tools](https://youtu.be/89bLKVvF85M) and the [Zex](https://github.com/Games-by-Mason/Zex) README.

## How does it work?

Oven recursively walks the given data directory at build time, and discovers all supported assets. A build graph to process the assets is generated using Zig's build system, and then the build system is able to process them all in parallel. If inputs are later modified, the build system is able to detect this and only rebuild the changed assets.

For conversions that support per asset configuration, you can provide that configuration via a ZON file. Using a file `foo/bar.png` as an example, configuration is searched for in the following locations:
* `foo/bar.png.zon`
* `foo/.png.zon`
* `.png.zon`

Multiple configuration files can affect a single asset. If the same option is specified multiple times, the version given closest to the file itself takes precedence.

This strategy allows customizing both specific files, and entire subtrees of files.

## What formats are supported?

Right now conversion from `png` to `ktx2`, and `glsl` to `spv` are supported, and `zon`files are installed as is with no additional validation. There isn't currently a way to extend it to new formats without modifying the source.

You're welcome to use the library as is, or to fork it to add support for the formats you need/remove ones you don't.

There may be value in allowing registering new formats external to the library itself so it can be customized more easily without forking, but I don't have time to set this up right now. If you have a proposal for how this could work feel free to file an issue!

## Usage

The simplest way to use Oven is to add it as a dependency to `build.zig.zon`, and then add the following to your `build.zig`:
```zig
const oven = @import("oven");

// Get the Oven dependency
const oven_dep = b.dependency("oven", .{
	// Always build release safe
    .optimize = .ReleaseSafe,
    // Always use the build machine's target
    .target = b.resolveTargetQuery(.{}),
});

// Bake the assets in the data folder
const baked = try oven.bake(b, oven_dep, .{
    .dirname = "data",
    .shader_compiler = try .init(b, optimize),
});

// Install the baked assets
b.installDirectory(.{
    .source_dir = baked.getDirectory(),
    .install_dir = .prefix,
    .install_subdir = "data",
});
```

## See Also

Zex currently uses the following libraries to convert assets. If you don't need the full pipeline and just want to convert your textures/shaders/such directly, you may want to check these out instead:
* [`shader_compiler`](https://github.com/Games-by-Mason/shader_compiler)
* [`Zex`](https://github.com/Games-by-Mason/Zex)
