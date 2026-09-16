# Statements and parameters

[`execute`](@ref) runs a statement and returns a [`Result`](@ref). A string holding several
`;`-separated statements returns one result per statement: [`execute_all`](@ref) returns all of
them, and `execute` returns the first.

## Statement packs

From engine 0.1.0, as on Snowflake, a request carries one statement unless it says otherwise, and a
longer pack is refused on its count. `multi_statement_count` declares how many statements one
request holds, with `0` for any number:

```julia
results = execute_all(conn, "SELECT 1; SELECT 2"; multi_statement_count=2)
```

The count applies to that request only: it overrides the session's `MULTI_STATEMENT_COUNT` without
changing it, so nothing needs restoring afterwards. Without the keyword no count is sent and the
session's value decides; `execute(conn, "ALTER SESSION SET MULTI_STATEMENT_COUNT = 0")` changes
that value for the whole session.

## Parameters

Parameters are inlined into the SQL on the client, because the protocol has no server-side
binding. The rules match Frostlake's JDBC driver:

- A `?` inside a string literal, quoted identifier, `$$…$$` body or comment is never a
  placeholder.
- When arguments are supplied, their number must match the placeholders exactly.
- With no arguments at all, markers pass through to the server unchanged. There a `?` is a
  Snowflake Scripting cursor placeholder bound by `OPEN c USING (...)`, and `:name` is a
  Scripting variable.

A statement uses either positional `?` or named `:name` placeholders, not both. Named arguments
come as a dictionary or a named tuple:

```julia
execute(conn, "SELECT :a + :b AS total", (a=2, b=40))
execute(conn, "SELECT :a + :b AS total", Dict("a" => 2, "b" => 40))
```

Names match case-insensitively, in any order. A `::` cast, a `:=` assignment and a `:1`
positional reference are never parameters. Neither is Snowflake's VARIANT path access: a colon
directly after an expression (`v:field`, `PARSE_JSON('…'):k`, `"V":k`) reads a field, so a named
marker must follow an operator, a comma or a keyword.

## Value conversion

| Julia value | SQL literal |
| --- | --- |
| `nothing`, `missing` | `NULL` |
| `Bool` | `TRUE` / `FALSE` |
| `Integer` (`Int`, `BigInt`, …) | the exact digits; a negative value in parentheses |
| `AbstractFloat` | the shortest round-tripping form; NaN and ±Inf as text cast to `FLOAT` |
| `AbstractString` | `'…'`, with backslashes and quotes escaped |
| `Vector{UInt8}` | `X'hex'` |
| `Date` | `'…'::DATE` |
| `Time` | `'…'::TIME` |
| `DateTime` | `'…'::TIMESTAMP_NTZ` |
| [`ZonedTimestamp`](@ref) | `'…'::TIMESTAMP_TZ`, with its offset |
| `AbstractVector` | `[…]`, elements converted recursively |
| `AbstractDict` | `{'key': …}`, values converted recursively |

`Vector{UInt8}` is the marker for binary data; any other vector, such as `Vector{Int}`, becomes an
array. Snowflake has both types, and guessing from the element type would give `[1, 2, 3]` two
meanings.

A Julia `DateTime` has no time zone, like `TIMESTAMP_NTZ`; casting it to `TIMESTAMP_TZ` would
invent an offset. Bind a `ZonedTimestamp` when the offset matters.
