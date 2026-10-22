# Dave

Library code goes in `temper` code blocks (indented blocks in a `.temper.md`
file are Temper by default). Prose outside the blocks is documentation.

    export let version(): String { "0.1.0" }

Tests live beside the code they test. Any module with a `test` block is a
test module on every backend.

    test("version is a semver triple") {
      assert(version().split(".").length == 3) { "got ${version()}" }
    }
