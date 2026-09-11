# Failures the driver can raise.
#
# The split is the one a caller actually branches on: did the engine refuse the
# statement (`QueryError`), did the request never become an answer
# (`ConnectionError`), or did the driver never send it at all (`UsageError`)?

"""
    FrostlakeError

Supertype of every failure this driver raises, so a single

```julia
try
    execute(conn, sql)
catch e
    e isa FrostlakeError || rethrow()
end
```

catches the lot. The subtypes say which kind it was.
"""
abstract type FrostlakeError <: Exception end

"""
    ConnectionError <: FrostlakeError

The server could not be reached, the request died mid-flight, or what came back
was not a Frostlake response at all.

A statement that failed this way has an *unknown* fate: the request may have
arrived and run before the connection broke, so it must not be blindly retried —
re-running an `INSERT` would duplicate it.

Fields: `message`, `endpoint` (the URL called, when the failure names one),
`status` (the HTTP status, or `nothing` when the request never completed) and
`cause` (the underlying transport error, when there was one).
"""
struct ConnectionError <: FrostlakeError
    message::String
    endpoint::Union{String,Nothing}
    status::Union{Int,Nothing}
    cause::Any
end

ConnectionError(message::AbstractString; endpoint=nothing, status=nothing, cause=nothing) =
    ConnectionError(String(message), endpoint, status, cause)

"""
    QueryError <: FrostlakeError

The engine rejected a statement: it compiled badly, referenced something that
does not exist, or failed while running. `message` is the engine's own wording,
unmodified.

!!! warning "`statement` is sensitive"
    Binding is client-side, so `statement` holds the SQL **after parameter
    substitution** — a bound password or card number appears in it verbatim.
    `message` and the printed form of the error carry none of it, so log those
    freely and treat `statement` as sensitive.
"""
struct QueryError <: FrostlakeError
    message::String
    statement::String
    status::Union{Int,Nothing}
end

QueryError(message::AbstractString, statement::AbstractString; status=nothing) =
    QueryError(String(message), String(statement), status)

"""
    UsageError <: FrostlakeError

The driver was asked for something impossible and never sent a request: a
malformed DSN, a closed connection, a bind value with no SQL equivalent, an
argument count that does not match the placeholders.
"""
struct UsageError <: FrostlakeError
    message::String
end

UsageError(message::AbstractString) = UsageError(String(message))

Base.showerror(io::IO, e::ConnectionError) = print(io, "ConnectionError: ", e.message)
Base.showerror(io::IO, e::QueryError) = print(io, "QueryError: ", e.message)
Base.showerror(io::IO, e::UsageError) = print(io, "UsageError: ", e.message)
