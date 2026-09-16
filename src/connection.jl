# The transport: one HTTP session per connection, and the engine session behind
# it.
#
# `Downloads` is the standard library's libcurl binding, which gives keep-alive,
# TLS and timeouts without adding a package to the manifest.

"How much of an unrecognisable response is quoted back in an error."
const MAX_ERROR_BODY = 512

"""
    Connection

A connection to a Frostlake HTTP server, and the engine session behind it.

Statements are serialized: a statement holds the connection until it has an
answer, so session state — `USE`, session variables, an open transaction —
carries from one statement to the next, which is exactly what a half-interleaved
second statement would break.

Build one with `Connection(dsn)` and release it with `close`.
"""
mutable struct Connection
    config::Config
    downloader::Union{Downloads.Downloader,Nothing}
    "Held for a whole call, so pending USE statements and the statement itself reach the session as one unit."
    lock::ReentrantLock
    sessionid::Union{String,Nothing}
    autocommit::Bool
    closed::Bool
    "USE statements still owed to the session, in dependency order."
    pending_use::Vector{String}
    "The scope the DSN named, kept so a lapsed session can be put back on it."
    session_defaults::Vector{String}
    "`time_ns()` when the connection last had an answer, or `nothing` before its first."
    last_used_at::Union{UInt64,Nothing}
    "Whether the caller has selected a scope themselves; if they have, the DSN's defaults are no longer the whole truth about this session."
    session_touched::Bool
end

"""
    Connection(dsn; kwargs...) -> Connection
    Connection(f, dsn; kwargs...)

Opens a connection to a Frostlake HTTP server. `Frostlake.connect` is the same
function under the name other drivers use; it is not exported, because `connect`
is `Sockets`' name too.

```julia
conn = Connection("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
```

The server is contacted before this returns: its health endpoint is called, and
the database, schema, role and warehouse the DSN names are selected. A name that
does not exist is therefore reported here, rather than surfacing later on
whichever query happened to run first.

Given a function, the connection is passed to it and closed afterwards:

```julia
Connection("frostlake://localhost:18082") do conn
    execute(conn, "SELECT 1")
end
```

Every keyword may also be given in the DSN query string, where an explicit
keyword outranks it. Timeouts are seconds, or a fixed-length `Dates.Period`
such as `Minute(10)`; `0` removes the bound.

| Keyword | Meaning |
| --- | --- |
| `timeout` | how long one statement may take |
| `connect_timeout` | how long to wait for the socket |
| `idle_limit` | how long a connection may idle before its scope is re-applied |
| `cacert` | a CA bundle for HTTPS, instead of the system's |
| `verify_certificate` | `false` to accept any HTTPS certificate |
"""
function connect(dsn::AbstractString; timeout=nothing, connect_timeout=nothing,
                 idle_limit=nothing, cacert=nothing, verify_certificate=nothing)
    base = parse_dsn(dsn)
    config = Config(
        host=base.host,
        port=base.port,
        secure=base.secure,
        database=base.database,
        schema=base.schema,
        role=base.role,
        warehouse=base.warehouse,
        connect_timeout=something(_seconds(connect_timeout), base.connect_timeout),
        timeout=something(_seconds(timeout), base.timeout),
        idle_limit=something(_seconds(idle_limit), base.idle_limit),
    )
    if !config.secure && (cacert !== nothing || verify_certificate !== nothing)
        throw(UsageError("cacert and verify_certificate apply to https DSNs only"))
    end

    pending = use_statements(config)
    conn = Connection(config, _downloader(config, cacert, verify_certificate),
                      ReentrantLock(), nothing, true, false, pending, copy(pending),
                      nothing, false)
    try
        ping(conn)
        apply_dsn_scope(conn)
    catch
        # Nothing usable came of it, so do not leave a client behind.
        close(conn)
        rethrow()
    end
    return conn
end

function connect(f::Function, dsn::AbstractString; kwargs...)
    conn = connect(dsn; kwargs...)
    try
        return f(conn)
    finally
        close(conn)
    end
end

# `Connection(dsn)` is the spelling Julia's database packages use, and the one
# that does not collide with `Sockets.connect` in a caller's namespace.
Connection(dsn::AbstractString; kwargs...) = connect(dsn; kwargs...)
Connection(f::Function, dsn::AbstractString; kwargs...) = connect(f, dsn; kwargs...)

# Connections with the same transport settings share one Downloader, and with it
# libcurl's pool of keep-alive sockets. A Downloader of its own per connection
# would leave every closed connection's idle sockets open until the grace period
# or the collector reached them; enough of those and a request on a newer
# connection fails with "select/poll returned error" under Julia 1.10's libcurl.
# The key holds everything the easy-handle hook reads, so connections that differ
# in any of it get a Downloader of their own.
const _DOWNLOADERS = Dict{Tuple{Int,Union{String,Nothing},Bool},Downloads.Downloader}()
const _DOWNLOADERS_LOCK = ReentrantLock()

function _downloader(config::Config, cacert, verify_certificate)
    key = (round(Int, config.connect_timeout * 1000),
           cacert === nothing ? nothing : String(cacert),
           verify_certificate === false)
    return lock(_DOWNLOADERS_LOCK) do
        get!(() -> _new_downloader(key...), _DOWNLOADERS, key)
    end
end

function _new_downloader(connect_ms::Int, cacert::Union{String,Nothing}, skip_verify::Bool)
    downloader = Downloads.Downloader()
    cacert === nothing || (downloader.ca_roots = cacert)
    # libcurl's connect timeout and certificate checking have no keyword on
    # `Downloads.request`, so they are set on the easy handle. A Julia that has
    # moved the hook is not a reason to refuse to connect — the request-level
    # timeout still bounds the call.
    try
        downloader.easy_hook = (easy, info) -> begin
            connect_ms > 0 &&
                Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_CONNECTTIMEOUT_MS, connect_ms)
            if skip_verify
                Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_SSL_VERIFYPEER, 0)
                Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_SSL_VERIFYHOST, 0)
            end
        end
    catch
        skip_verify && throw(UsageError("this Julia cannot turn certificate verification off"))
    end
    return downloader
end

"The engine's id for this connection's session, once it has one."
session_id(conn::Connection) = conn.sessionid

"Whether a transaction is open — `begin_transaction` without a matching `commit` or `rollback`."
in_transaction(conn::Connection) = !conn.autocommit

"The server this connection speaks to, as `scheme://host:port`."
base_url(conn::Connection) = base_url(conn.config)

Base.isopen(conn::Connection) = !conn.closed

Base.show(io::IO, conn::Connection) =
    print(io, "Connection(", base_url(conn.config), conn.closed ? ", closed" : "", ")")

"""
    close(conn)

Closes the connection.

The HTTP API has no endpoint for ending a session, so the engine's own idle
sweep is what reclaims the session behind it; closing lets the next statement on
this object fail loudly rather than quietly opening a second session. The
sockets belong to a pool shared by every connection with the same transport
settings, and an idle one is closed 30 seconds after the pool's last request.
Closing twice is not an error.
"""
function Base.close(conn::Connection)
    conn.closed && return nothing
    # Let a statement already in flight finish first, so its caller gets an
    # answer rather than a torn connection.
    lock(conn.lock) do
        conn.closed = true
        conn.downloader = nothing
    end
    return nothing
end

_check_open(conn::Connection) =
    conn.closed && throw(UsageError("the connection is closed"))

"""
    execute(conn, sql; multi_statement_count=nothing) -> Result
    execute(conn, sql, parameters; multi_statement_count=nothing) -> Result

Runs one statement and returns its first result set.

`parameters` fill the statement's placeholders: a vector or tuple for positional
`?` markers, a dictionary or named tuple for `:name` markers. The count has to
match exactly whenever arguments are supplied; with none at all the markers pass
through to the server, where Snowflake Scripting binds them (`OPEN c USING
(...)`, `EXECUTE IMMEDIATE :v`).

```julia
execute(conn, "INSERT INTO people VALUES (?, ?)", [1, "Ada"])
execute(conn, "SELECT :a + :b AS total", (a=2, b=40))
```

`multi_statement_count` says how many statements this one request carries; see
[`execute_all`](@ref).

A string holding several `;`-separated statements answers with the first one's
result — use [`execute_all`](@ref) for the rest.
"""
execute(conn::Connection, sql::AbstractString; multi_statement_count=nothing) =
    first(execute_all(conn, sql; multi_statement_count=multi_statement_count))
execute(conn::Connection, sql::AbstractString, parameters; multi_statement_count=nothing) =
    first(execute_all(conn, sql, parameters; multi_statement_count=multi_statement_count))

"""
    execute_all(conn, sql; multi_statement_count=nothing) -> Vector{Result}
    execute_all(conn, sql, parameters; multi_statement_count=nothing) -> Vector{Result}

Runs a statement string and returns every result set it produced, in order. A
single statement gives a one-element vector.

The engine refuses a request holding more statements than it was told to expect,
so a pack says how many it holds:

```julia
execute_all(conn, "SELECT 1; SELECT 2"; multi_statement_count=2)
```

The count travels with this one request. It outranks the session's
`MULTI_STATEMENT_COUNT` without changing it, so there is nothing to put back
afterwards, and `0` allows any number. Left out, no count is sent at all and the
session's value decides.
"""
function execute_all(conn::Connection, sql::AbstractString; multi_statement_count=nothing)
    text = String(sql)
    # With no parameters the markers are the server's and pass through verbatim;
    # the render call still refuses a statement mixing the two placeholder styles.
    return _run(conn, text, substitute_positional(text, ()),
                _statement_count(multi_statement_count))
end

function execute_all(conn::Connection, sql::AbstractString,
                     parameters::Union{AbstractVector,Tuple}; multi_statement_count=nothing)
    text = String(sql)
    return _run(conn, text, substitute_positional(text, parameters),
                _statement_count(multi_statement_count))
end

function execute_all(conn::Connection, sql::AbstractString, parameters::AbstractDict;
                     multi_statement_count=nothing)
    text = String(sql)
    return _run(conn, text, substitute_named(text, parameters),
                _statement_count(multi_statement_count))
end

execute_all(conn::Connection, sql::AbstractString, parameters::NamedTuple;
            multi_statement_count=nothing) =
    execute_all(conn, sql, Dict{String,Any}(string(k) => v for (k, v) in pairs(parameters));
                multi_statement_count=multi_statement_count)

# Anything else is a mistake worth naming. A bare `MethodError` would say which
# signatures exist; this says what to pass.
execute_all(::Connection, ::AbstractString, parameters; multi_statement_count=nothing) =
    throw(UsageError(string("parameters must be a vector or tuple for ? placeholders, or a ",
                            "dictionary or named tuple for :name placeholders, got ",
                            typeof(parameters))))

# The statement count a call declares, checked here so a bad value is a usage
# error rather than a request body the engine cannot read.
function _statement_count(given)
    given === nothing && return nothing
    (given isa Integer && !(given isa Bool) && given >= 0) || throw(UsageError(
        string("multi_statement_count must be a whole number of statements, 0 for any ",
               "number, got ", repr(given))))
    return Int(given)
end

function _run(conn::Connection, sql::String, rendered::String,
              multi_statement_count::Union{Int,Nothing}=nothing)
    _check_open(conn)
    # The pending USE statements and the statement itself have to reach the
    # session as one unit: another caller must not slip a query in between, and
    # two must not both try to send the same pending entry.
    return lock(conn.lock) do
        _check_open(conn)
        _restore_session_defaults(conn)
        # The pending USE statements are one statement each, whatever this
        # request declares, so the count goes only on the caller's own.
        _drain_pending_use(conn)
        body = _round_trip(conn, rendered, multi_statement_count)
        changes_session_scope(sql) && (conn.session_touched = true)
        return _shape_results(body)
    end
end

# Each USE leaves the queue only once it has succeeded. A DSN naming a database
# that does not exist has to keep failing; the alternative is later statements
# quietly running in the default scope.
function _drain_pending_use(conn::Connection)
    while !isempty(conn.pending_use)
        _round_trip(conn, conn.pending_use[1])
        popfirst!(conn.pending_use)
    end
end

"""
    apply_dsn_scope(conn)

Selects the database, schema, role and warehouse the DSN names. [`connect`](@ref)
calls this, so it is only worth calling again after the session has been moved
somewhere else deliberately.
"""
function apply_dsn_scope(conn::Connection)
    _check_open(conn)
    isempty(conn.session_defaults) && return nothing
    lock(conn.lock) do
        # Re-queue the whole scope: `connect` drained the queue already, so
        # without this a second call would send nothing and report success.
        conn.pending_use = copy(conn.session_defaults)
        conn.session_touched = false
        _drain_pending_use(conn)
    end
    return nothing
end

"""
    ping(conn)

Checks that a Frostlake engine is answering, via `GET /api/health`.

A 200 on its own only says something is listening — anything can serve that. The
health payload is what says it is an engine, so a body that is not one is
reported rather than passed off as healthy.
"""
function ping(conn::Connection)
    _check_open(conn)
    endpoint = string(base_url(conn.config), "/api/health")
    status, body = _get(conn, endpoint)
    health = _decode_body(endpoint, status, body)
    get(health, "status", nothing) === nothing && throw(ConnectionError(
        string(endpoint, " answered HTTP ", status,
               " with a body that is not a Frostlake response: ", _snippet(body));
        endpoint=endpoint, status=status))
    return nothing
end

# The engine reclaims a session once it has been idle long enough, then quietly
# builds a fresh one for the id we keep sending — losing the scope we selected.
# Nothing in the reply gives it away: the id we sent is echoed back either way.
# So past the limit the only safe reading is that the session is new, and the
# DSN's defaults go back on.
#
# Not once the caller has selected a scope themselves: putting our defaults over
# their choice is its own surprise.
function _restore_session_defaults(conn::Connection)
    (isempty(conn.session_defaults) || conn.session_touched) && return nothing
    conn.config.idle_limit == 0 && return nothing
    last = conn.last_used_at
    last === nothing && return nothing
    idle = (time_ns() - last) / 1e9
    idle < conn.config.idle_limit && return nothing
    conn.pending_use = copy(conn.session_defaults)
    return nothing
end

# ---------------------------------------------------------------- transactions

"""
    begin_transaction(conn)

Opens a transaction: autocommit goes off and `BEGIN` is sent.
"""
function begin_transaction(conn::Connection)
    _check_open(conn)
    lock(conn.lock) do
        conn.autocommit = false
        try
            _round_trip(conn, "BEGIN")
        catch
            conn.autocommit = true
            rethrow()
        end
    end
    return nothing
end

"Commits the open transaction and restores autocommit."
function commit(conn::Connection)
    _check_open(conn)
    lock(conn.lock) do
        try
            _round_trip(conn, "COMMIT")
        finally
            conn.autocommit = true
        end
    end
    return nothing
end

"Rolls the open transaction back and restores autocommit."
function rollback(conn::Connection)
    _check_open(conn)
    lock(conn.lock) do
        try
            _round_trip(conn, "ROLLBACK")
        finally
            conn.autocommit = true
        end
    end
    return nothing
end

"""
    transaction(f, conn)

Runs `f(conn)` inside `BEGIN` ... `COMMIT`, rolling back if it throws and
re-raising the original error either way.

```julia
transaction(conn) do c
    execute(c, "INSERT INTO acc VALUES (1)")
end
```

The connection is *not* held for the duration: a transaction lives on the
session, so anything else run on this same connection meanwhile joins the
transaction. Give a transaction its own connection if that is not what you want.
"""
function transaction(f::Function, conn::Connection)
    begin_transaction(conn)
    local result
    try
        result = f(conn)
    catch
        try
            rollback(conn)
        catch
            # A failed rollback must not replace the error that caused it.
        end
        rethrow()
    end
    commit(conn)
    return result
end

# ---------------------------------------------------------------- transport

function _round_trip(conn::Connection, sql::String,
                     multi_statement_count::Union{Int,Nothing}=nothing)
    endpoint = string(base_url(conn.config), "/api/execute")
    payload = string("{\"sql\":", json_encode(sql),
                     conn.sessionid === nothing ? "" :
                     string(",\"sessionId\":", json_encode(conn.sessionid)),
                     ",\"autoCommit\":", conn.autocommit ? "true" : "false",
                     # Absent unless the caller asked for a count: a request
                     # without the field is the one the server has always seen,
                     # and the session's value decides.
                     multi_statement_count === nothing ? "" :
                     string(",\"multiStatementCount\":", multi_statement_count), "}")

    status, body = _post(conn, endpoint, payload)
    decoded = _decode_body(endpoint, status, body)

    session = get(decoded, "sessionId", nothing)
    (session isa AbstractString && !isempty(session)) && (conn.sessionid = String(session))

    if get(decoded, "success", nothing) !== true
        throw(QueryError(_failure_message(decoded, status, body), sql; status=status))
    end
    conn.last_used_at = time_ns()
    return decoded
end

function _post(conn::Connection, endpoint::String, payload::String)
    return _request(conn, endpoint; method="POST", input=IOBuffer(payload),
                    headers=["Content-Type" => "application/json"])
end

function _get(conn::Connection, endpoint::String)
    status, body = _request(conn, endpoint; method="GET")
    status == 200 || throw(ConnectionError(
        string(endpoint, " answered HTTP ", status, ": ", _snippet(body));
        endpoint=endpoint, status=status))
    return (status, body)
end

function _request(conn::Connection, endpoint::String; method::String, input=nothing,
                  headers=Pair{String,String}[])
    downloader = conn.downloader
    downloader === nothing && throw(UsageError("the connection is closed"))
    out = IOBuffer()
    limit = conn.config.timeout
    answer = try
        Downloads.request(endpoint; method=method, input=input, output=out,
                          headers=headers, timeout=(limit == 0 ? Inf : limit),
                          throw=false, downloader=downloader)
    catch e
        throw(ConnectionError(string(endpoint, ": ", sprint(showerror, e));
                              endpoint=endpoint, cause=e))
    end
    if answer isa Downloads.RequestError
        # CURLE_OPERATION_TIMEDOUT. Saying which deadline passed is the
        # difference between a bug report and a configuration change.
        answer.code == 28 && throw(ConnectionError(
            string(endpoint, " did not answer within ", _describe(limit));
            endpoint=endpoint, cause=answer))
        throw(ConnectionError(string("cannot reach ", endpoint, ": ", answer.message);
                              endpoint=endpoint, cause=answer))
    end
    return (Int(answer.status), String(take!(out)))
end

# Reads a response body as the JSON object a Frostlake answer is.
#
# A proxy error page, the wrong port, a crashed server: report what came back
# rather than where the JSON parser gave up, which is the difference between
# "malformed JSON at offset 0" and a message naming the address that answered.
function _decode_body(endpoint::String, status::Int, body::String)
    decoded = try
        json_decode(body)
    catch e
        e isa JSONParseError || rethrow()
        nothing
    end
    decoded isa AbstractDict && return decoded
    throw(ConnectionError(
        string(endpoint, " answered HTTP ", status,
               " with a body that is not a Frostlake response: ", _snippet(body));
        endpoint=endpoint, status=status))
end

# Never returns the empty string: a response can report failure carrying no
# message at all, and an error that prints as nothing tells the caller less than
# the status code would.
function _failure_message(body::AbstractDict, status::Int, raw::String)
    message = get(body, "errorMessage", nothing)
    (message isa AbstractString && !isempty(message)) && return String(message)
    error_text = get(body, "error", nothing)
    (error_text isa AbstractString && !isempty(error_text)) && return String(error_text)
    return string("the statement failed with HTTP ", status,
                  " and no error message: ", _snippet(raw))
end

# ---------------------------------------------------------------- result shape

function _shape_results(body::AbstractDict)
    sets = get(body, "resultSets", nothing)
    shaped = sets isa AbstractVector ?
             Result[_shape_result(set) for set in sets if set isa AbstractDict] : Result[]
    # A statement that returned no grid at all — DDL, a bare USE — still answers
    # with one result, so that `execute` always has one to hand back.
    isempty(shaped) && return [Result(ColumnInfo[], Vector{Any}[], -1)]
    return shaped
end

function _shape_result(set::AbstractDict)
    columns = ColumnInfo[]
    raw_columns = get(set, "columns", nothing)
    if raw_columns isa AbstractVector
        for column in raw_columns
            column isa AbstractDict || continue
            push!(columns, ColumnInfo(
                _as_string(get(column, "name", nothing), ""),
                _as_string(get(column, "dataType", nothing), ""),
                get(column, "nullable", nothing) isa Bool ? column["nullable"] : nothing,
                _as_int(get(column, "precision", nothing)),
                _as_int(get(column, "scale", nothing)),
                # Text and binary columns only; every other type omits it, and
                # so does a server that predates the field.
                _as_int(get(column, "length", nothing)),
            ))
        end
    end

    values = Vector{Any}[]
    raw_rows = get(set, "rows", nothing)
    if raw_rows isa AbstractVector
        for row in raw_rows
            row isa AbstractVector || continue
            push!(values, Any[convert_cell(i <= length(row) ? row[i] : nothing, columns[i])
                              for i in eachindex(columns)])
        end
    end

    # The protocol carries no statement type, so a DML answer is recognised by
    # its shape: a single row whose every column is a "number of ..." counter.
    # INSERT and DELETE report one, UPDATE adds "number of multi-joined rows
    # updated", and MERGE reports an inserted and an updated count.
    if length(values) == 1 && !isempty(columns) &&
       all(c -> startswith(lowercase(c.name), "number of "), columns)
        counters = Dict{String,Int}()
        affected = 0
        for (i, column) in enumerate(columns)
            count = _as_int(values[1][i])
            count === nothing && continue
            counters[column.name] = count
            # "number of multi-joined rows updated" is a diagnostic sub-count of
            # rows already counted as updated, so only the "number of rows ..."
            # counters are summed.
            startswith(lowercase(column.name), "number of rows ") && (affected += count)
        end
        # The grid itself is kept rather than folded away. A statement whose
        # answer merely LOOKS like a status grid is indistinguishable from one
        # that is, and hiding its rows would lose the only copy of them.
        return Result(columns, values, affected, counters)
    end

    return Result(columns, values, -1)
end

_as_string(value, fallback::String) = value isa AbstractString ? String(value) : fallback

function _as_int(value)
    value isa Bool && return nothing
    value isa Integer && return Int(value)
    value isa JSONNumber && return asint(value)
    if value isa AbstractFloat
        (isfinite(value) && value == round(value)) || return nothing
        return Int(value)
    end
    value isa AbstractString && return tryparse(Int, value)
    return nothing
end

function _snippet(payload::AbstractString)
    text = strip(String(payload))
    isempty(text) && return "(empty body)"
    length(text) > MAX_ERROR_BODY && return string(first(text, MAX_ERROR_BODY), "...")
    return text
end

function _describe(limit::Real)
    limit < 1 && return string(round(Int, limit * 1000), "ms")
    return limit == round(limit) ? string(round(Int, limit), "s") : string(limit, "s")
end
