# Development

## Running the tests

From a clone of the repository:

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

The unit tests need neither an engine nor a JVM. The integration tests start a real Frostlake
server and run statements through the driver, with nothing mocked; they need Java and the engine's
classpath, and skip themselves when `FROSTLAKE_CLASSPATH` is not set:

```bash
JAVA_HOME=/path/to/jdk17 FROSTLAKE_CLASSPATH="<engine jar>:<dependency jars>" \
    julia --project -e 'using Pkg; Pkg.test()'
```

The classpath is passed to `java -cp` unchanged, so use the platform's separator: `:` on Linux and
macOS, `;` on Windows. The engine is published on Maven Central as `dev.frostlake:frostlake-db`;
the CI workflow shows one way to assemble its classpath with Maven.

## Continuous integration

GitHub Actions runs the whole suite, integration tests included, against engines 0.0.7 and 0.1.0
on Julia 1.10 and the latest Julia release, reports coverage to Codecov, and builds this
documentation.
