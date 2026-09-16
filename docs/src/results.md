# Results and types

## Results

[`execute`](@ref) returns a [`Result`](@ref):

| Member | Contents |
| --- | --- |
| `result.columns` | one [`ColumnInfo`](@ref) per column: name, declared type, nullability, precision, scale, and the length of a text or binary column |
| `result.values` | every cell, aligned with `columns` |
| `result.updatecount` | rows affected by DML, or `-1` for a query |
| `result.counters` | the raw `number of rows …` counters behind `updatecount` |
| `rows(result)` | each row as a dictionary keyed by column name, built on first use |
| `scalar(result)` | the first cell of the first row |
| `rowcount(result)` | rows returned, or rows affected by DML |
| `isupdate(result)` | whether the result came from DML |
| `columnnames(result)` | the column names, in order |

A `Result` iterates and indexes over its rows:

```julia
for row in result
    println(row[1], " ", row[2])
end

result[1]           # the first row
result[1, 2]        # one cell of it
result[1, "NAME"]   # the same, by column name (case-insensitive)
map(row -> row[1], result)
```

`rows` cannot hold two columns with the same name (a self-join reports `ID` twice, and the later
one wins); `values` keeps both.

## Types

| SQL type | Julia type |
| --- | --- |
| integral `NUMBER`, `INTEGER` and similar | `Int64`, or `BigInt` beyond 64 bits |
| fractional `NUMBER`, `FLOAT`, `DOUBLE`, `REAL` | `Float64` |
| `VARCHAR` and other text types | `String` |
| `BOOLEAN` | `Bool` |
| `BINARY` | `Vector{UInt8}` |
| `DATE` | `Date` |
| `TIME` | `Time` |
| `TIMESTAMP`, `TIMESTAMP_NTZ`, `DATETIME` | `DateTime` |
| `TIMESTAMP_LTZ`, `TIMESTAMP_TZ` | [`ZonedTimestamp`](@ref) |
| `VARIANT`, `OBJECT`, `ARRAY` | `String`, as the engine renders it |
| SQL `NULL` | `nothing` |

A `NUMBER(38,0)` can exceed `Int64`. The driver's JSON parser keeps each number's text, so such a
value arrives as an exact `BigInt` rather than a rounded `Float64`.

Julia's standard library has no zoned timestamp type, so `TIMESTAMP_TZ` and `TIMESTAMP_LTZ` become
a `ZonedTimestamp`: the wall clock (`z.datetime`) and its UTC offset (`z.offset`). Compare two of
them with `utc(z)`, which returns the instant.

`Date` and `DateTime` values are read exactly as stored, without conversion to the host's time
zone.
