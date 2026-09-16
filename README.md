# Frostlake.jl

[![Stable docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://Frostlake-DB.github.io/Frostlake.jl/stable/)
[![Dev docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://Frostlake-DB.github.io/Frostlake.jl/dev/)
[![CI](https://github.com/Frostlake-DB/Frostlake.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/Frostlake-DB/Frostlake.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![Coverage](https://codecov.io/gh/Frostlake-DB/Frostlake.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/Frostlake-DB/Frostlake.jl)

A Julia client for [Frostlake](https://frostlake.dev), a SQL engine that emulates Snowflake. It
talks to a running Frostlake server over its HTTP API and depends only on Julia's standard library.

## Installation

```julia
pkg> add Frostlake
```

Requires Julia 1.10 or newer and a Frostlake engine 0.0.7 or newer.

## Example

```julia
using Frostlake

conn = Connection("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
execute(conn, "CREATE TABLE people (id INTEGER, name VARCHAR)")
execute(conn, "INSERT INTO people VALUES (?, ?), (?, ?)", [1, "Ada", 2, "Grace"])
scalar(execute(conn, "SELECT name FROM people WHERE id = ?", [1]))  # "Ada"
close(conn)
```

The [documentation](https://Frostlake-DB.github.io/Frostlake.jl/stable/) covers connection
options, parameter binding, type mapping and known limitations.

## License

Apache-2.0; see [LICENSE](LICENSE).
