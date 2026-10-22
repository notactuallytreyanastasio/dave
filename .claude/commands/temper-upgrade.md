---
description: Rebuild the Temper CLI from ../temper and report the version change
allowed-tools: Bash(git:*), Bash(bin/temper:*), Bash(cd:*), Bash(./gradlew:*), Bash(JAVA_HOME=*)
---

# Rebuild the CLI

`bin/temper` runs `../temper/cli/build/install/temper/bin/temper`. That
binary is only as new as the last `installDist`, and `../temper` is a live
checkout, so it drifts.

```bash
bin/temper version                               # e.g. Temper 0.6.1-dev+498-gf911cadd
git -C ../temper log -1 --format='%h %ad %s' --date=short
cd ../temper && JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :cli:installDist --offline -q
cd - && bin/temper version
```

Drop `--offline` if gradle needs new dependencies. The build takes a few
minutes the first time and under a minute after.

Afterwards run `/temper-test` to confirm the project still builds; a
compiler change can move a diagnostic or tighten a check. Report old
version, new version, and whether the tests still pass.
