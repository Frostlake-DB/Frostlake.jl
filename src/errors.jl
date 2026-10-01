# Failures the driver can raise.
#
# The split is the one a caller actually branches on: did the engine refuse the
# statement (`QueryError`), did the request never become an answer
# (`ConnectionError`), did the session it belonged to go away before it ran
# (`SessionLostError`), or did the driver never send it at all (`UsageError`)?

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
    SessionLostError <: FrostlakeError

The engine no longer holds the connection's session — it expired, was released,
or the server restarted — and the statement did **not** run.

A lost session is replaced without a word when nothing went with it: the DSN's
scope goes onto a fresh session and the statement is sent once more. This is
thrown instead when the lost session held something a fresh one cannot
reproduce — an open transaction, or context set up with `USE`, `SET`,
`ALTER SESSION` or a temporary object — because re-running the statement would
put it somewhere its author did not intend.

The connection stays usable: the next statement starts a fresh session on the
DSN's scope. Whatever the unit of work had done in the lost session is gone, so
it is the unit of work that has to start over.

`statement` is the SQL that did not run, **after parameter substitution** — as
sensitive as `QueryError.statement`.
"""
struct SessionLostError <: FrostlakeError
    message::String
    statement::String
end

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
Base.showerror(io::IO, e::SessionLostError) = print(io, "SessionLostError: ", e.message)
