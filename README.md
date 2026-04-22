# sfcasm

A quick & dirty, yet fully-featured, 65C816 macro assembler written in Objective-C. Originally written to replace ca65 as the assembler in [Super Bomberman's disassembly](https://github.com/LIJI32/superbomberman).

## Features

* Support for custom ROM and address layouts
* Fully featured expression variable
* Variables and macro variables
* Local labels/symbols and variables
* Relocations that work in almost any context
* Optional automatic checksum calculation
* Macros, repeat blocks, and nested ifs
* RAM and ROM struct definition support
* Allows defining and using multiple character encodings
* Make-compatible dependency generation, with support for resource generation
* Optional symbol table and variable dump outputs

## Missing Features

* Better error reporting
* Separate linkage step – currently linkage and compilation must be done together; the output must be a complete ROM
* Documentation
* The expression evaluator was adapted from a different project of mine

## Important Differences

Some non-conventional "artistic" decisions were made while designing the syntax of `sfcasm`. Most importantly, addressing modes will always use `[square brackets]` to denote indirect accesses, and *never* `(parentheses)`. This is so parentheses can be safely used in expressions without implying specific addressing modes. To differentiate between near/16-bit and far/24-bit indirect addressing modes, `a:` and `f:` are used, in a similar fashion to ca65.

Macro variables (defined with the `define` direction) and macro arguments, are always expanded even when inside string constants. For example:

```
define definition quack
db "$definition"
```

...will output the byte sequence `quack` rather than `$definition`. If the string literal `"$definition"` needs to be used, it can be written as `"$" + "definition"`.

Note that this does not apply to symbols/labels and non-macro variables, which are referenced without a `$`.

**Notice**: `sfcasm` is a work in progress. The syntax is not stable yet and might change in future versions.

## Building and installation

### macOS

Once you have Xcode or the Command Line Tools installed, `sfcasm` can be built and installed by running `make` and `sudo make install`. No external dependencies required.

### Linux and other Unix-like systems

`sfcasm` uses the Objective-C runtime and the Foundation framework, so it requires GNUstep to run on these platforms.

Unfortunately, the version of GNUstep available in most repositories is an ancient version targeting the old GCC runtime that does not support ARC, which is required to run `sfcasm`, and building GNUstep's base library is a pain due to over engineering of the build system and their continued support of multiple old and deprecated ABIs.

Fortunately, `sfcasm` comes with a handy installation script (`install_gnustep.sh`) that will install download, compile, build and install the runtime libraries of Objective-C and Foundation for you, as well as put the Foundation headers in the project root for `sfcasm`'s build system to use. It will also let you know if you're missing any build dependencies.

If you're not using GNUstep for anything else, running `install_gnustep.sh` is the recommended way to get the required runtime libraries for `sfcasm` installed. Once you have the libraries and header installed, you can run `make` and `sudo make install`.

### Windows

Good luck. It might work if you somehow manage to get GNUstep installed on Windows, but it too painful for me to even try. You're better off using a Linux VM or WSL.

## License

`sfcasm` is licensed under the Expat license.