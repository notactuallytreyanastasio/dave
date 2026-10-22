# Dave

A framework for building agents, bots and more, written once in Temper and
translated to each target language. This file is the library root: every
directory under `src/` that is imported here is a module of the library.

## Core metadata

    export let name = "dave";
    export let version = "0.1.0";
    export let license = "MIT";

## Modules

The top-level module (this directory) must be imported explicitly once any
other module is listed.

    import(".");
    import("./chat");
    import("./rounds");
    import("./repair");
    import("./compose");
