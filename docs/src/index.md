# Frostlake.jl

A Julia client for [Frostlake](https://frostlake.dev), a SQL engine that emulates Snowflake. It
talks to a running Frostlake server (`DatabaseHttpServer`) over its HTTP API and depends only on
Julia's standard library: `Downloads` for the transport and `Dates` for temporal types.

## Requirements

- Julia 1.10 or newer.
- A Frostlake engine 0.0.7 or newer. `SELECT CURRENT_VERSION()` reports a server's version. The
  driver speaks the HTTP protocol rather than linking the engine, so this is a minimum, not a
  pinned version.

## Installation

```julia
pkg> add Frostlake
```

## Quick start

```julia
using Frostlake

conn = Connection("frostlake://localhost:18082/MY_DB?schema=PUBLIC")

execute(conn, "CREATE TABLE people (id INTEGER, name VARCHAR)")

inserted = execute(conn, "INSERT INTO people VALUES (?, ?), (?, ?)",
                   [1, "Ada", 2, "Grace"])
inserted.updatecount            # 2

result = execute(conn, "SELECT id, name FROM people WHERE id = ?", [1])
rows(result)[1]["NAME"]         # "Ada"

close(conn)
```

## Contents

```@contents
Pages = ["connecting.md", "statements.md", "results.md", "transactions.md", "errors.md",
         "limitations.md", "development.md", "api.md"]
Depth = 1
```
