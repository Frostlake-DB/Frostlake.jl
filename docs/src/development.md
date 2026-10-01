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

The same run replays the engine's language-neutral test corpus through the driver when `FL_CORPUS`
names the testkit directory of a Frostlake checkout (use an absolute path), against an engine
started from `FROSTLAKE_CLASSPATH` as above; without `FL_CORPUS` the corpus is reported as skipped:

```bash
FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit \
    JAVA_HOME=/path/to/jdk17 FROSTLAKE_CLASSPATH="<engine jar>:<dependency jars>" \
    julia --project -e 'using Pkg; Pkg.test()'
```

Every case's outcome lands in `results/testkit-julia.tsv`.

## Continuous integration

GitHub Actions runs the whole suite, integration tests included, against engine 0.2.0 on Julia
1.10 and the latest Julia release, reports coverage to Codecov, and builds this documentation.
