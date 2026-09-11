# What a statement answered with.

"""
    ColumnInfo

What the engine reported about one column of a result set: its `name` as the
engine cased it, the declared `datatype` (`NUMBER`, `VARCHAR`,
`TIMESTAMP_NTZ`, ...), whether it is `nullable`, and the `precision` and `scale`
of the fixed-point numerics.

`nullable`, `precision` and `scale` are `nothing` when the server did not say —
an engine that predates a field reports nothing rather than `false` or `0`.
"""
struct ColumnInfo
    name::String
    datatype::String
    nullable::Union{Bool,Nothing}
    precision::Union{Int,Nothing}
    scale::Union{Int,Nothing}
end

ColumnInfo(name::AbstractString, datatype::AbstractString; nullable=nothing,
           precision=nothing, scale=nothing) =
    ColumnInfo(String(name), String(datatype), nullable, precision, scale)

Base.show(io::IO, c::ColumnInfo) = print(io, c.name, " ", c.datatype)

"""
    Result

One result set: what a single statement answered with.

| Field | What it holds |
| --- | --- |
| `columns` | a [`ColumnInfo`](@ref) per column, in order |
| `values` | every cell, positionally aligned with `columns` — the lossless view |
| `updatecount` | rows affected by DML, or `-1` when the statement returned data |
| `counters` | the raw `number of rows ...` counters behind `updatecount` |

A `Result` iterates and indexes over its rows, so `for row in result` and
`result[1][2]` work directly, and [`rows`](@ref) gives the same rows keyed by
column name.

A DML statement answers with a status grid rather than data — one row of
`number of rows inserted`-style counters — and that grid is reported here as it
arrived. `updatecount` is the friendly reading of it.
"""
mutable struct Result
    columns::Vector{ColumnInfo}
    values::Vector{Vector{Any}}
    updatecount::Int
    counters::Dict{String,Int}
    # `rows` is built on first use and kept, so a caller who only reads `values`
    # never pays for it.
    _named_rows::Union{Vector{Dict{String,Any}},Nothing}
end

Result(columns::Vector{ColumnInfo}, values::Vector{Vector{Any}}, updatecount::Int,
       counters::Dict{String,Int}=Dict{String,Int}()) =
    Result(columns, values, updatecount, counters, nothing)

"""
    rows(result) -> Vector{Dict{String,Any}}

Each row keyed by column name, built on first use and kept.

A dictionary cannot represent two columns called the same thing — a self-join
reports `ID` twice and the later one wins — so `result.values` stays the
lossless view.
"""
function rows(result::Result)
    cached = result._named_rows
    cached === nothing || return cached
    built = Vector{Dict{String,Any}}(undef, length(result.values))
    for (i, cells) in enumerate(result.values)
        row = Dict{String,Any}()
        for (j, column) in enumerate(result.columns)
            row[column.name] = j <= length(cells) ? cells[j] : nothing
        end
        built[i] = row
    end
    result._named_rows = built
    return built
end

"""
    scalar(result) -> Any

The first cell of the first row, or `nothing` when there is none — what a
single-value query (`SELECT COUNT(*)`, `SELECT CURRENT_VERSION()`) is after.
"""
function scalar(result::Result)
    isempty(result.values) && return nothing
    first_row = result.values[1]
    return isempty(first_row) ? nothing : first_row[1]
end

"Rows returned, or rows affected for a DML statement."
rowcount(result::Result) =
    result.updatecount >= 0 ? result.updatecount : length(result.values)

"Whether this result came from a DML statement rather than a query."
isupdate(result::Result) = result.updatecount >= 0

"The column names, in order."
columnnames(result::Result) = [column.name for column in result.columns]

"""
    columnindex(result, name) -> Int

The position of a column, matched exactly first and case-insensitively after, or
`0` when the result has no such column.
"""
function columnindex(result::Result, name::AbstractString)
    for (i, column) in enumerate(result.columns)
        column.name == name && return i
    end
    folded = uppercase(String(name))
    for (i, column) in enumerate(result.columns)
        uppercase(column.name) == folded && return i
    end
    return 0
end

Base.length(result::Result) = length(result.values)
Base.isempty(result::Result) = isempty(result.values)
Base.eltype(::Type{Result}) = Vector{Any}
Base.firstindex(::Result) = 1
Base.lastindex(result::Result) = length(result.values)
Base.keys(result::Result) = Base.OneTo(length(result.values))

Base.iterate(result::Result, i::Int=1) =
    i > length(result.values) ? nothing : (result.values[i], i + 1)

Base.getindex(result::Result, i::Integer) = result.values[i]
Base.getindex(result::Result, i::Integer, j::Integer) = result.values[i][j]

function Base.getindex(result::Result, i::Integer, name::AbstractString)
    j = columnindex(result, name)
    j == 0 && throw(KeyError(name))
    return result.values[i][j]
end

function Base.show(io::IO, result::Result)
    if isupdate(result)
        print(io, "Result(updatecount: ", result.updatecount, ")")
    else
        print(io, "Result(", length(result.columns), " column(s), ",
              length(result.values), " row(s))")
    end
end

function Base.show(io::IO, ::MIME"text/plain", result::Result)
    show(io, result)
    isempty(result.columns) && return
    println(io)
    print(io, "  ", join((string(c.name, "::", c.datatype) for c in result.columns), "  "))
    for cells in Iterators.take(result.values, 10)
        println(io)
        print(io, "  ", join((cell === nothing ? "NULL" : repr(cell) for cell in cells), "  "))
    end
    length(result.values) > 10 && print(io, "\n  ... ", length(result.values) - 10, " more row(s)")
end
