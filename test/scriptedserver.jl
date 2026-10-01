# A stand-in engine that answers from a script and records what it was sent.
#
# The session-lifetime tests are about which round trips a scenario makes — a
# lost session replaced once, a re-run refused, one release on close — so every
# request a scenario makes is one it scripted, and every one it sent is on
# record. `GET /api/health` is answered as an engine answers it, unscripted; a
# request with nothing scripted for it is answered with HTTP 500 and kept in
# `unscripted` for the test to fail on.

module ScriptedServer

using Sockets
using Frostlake: json_decode

"One request the driver sent, with its JSON body read back."
struct Sent
    method::String
    path::String
    "The request's JSON object; empty for a request without a body."
    body::Dict{String,Any}
end

sql(s::Sent) = get(s.body, "sql", nothing)
session_id(s::Sent) = get(s.body, "sessionId", nothing)
"Whether the body carries the field at all, whatever its value."
has_require_session(s::Sent) = haskey(s.body, "requireSession")
require_session(s::Sent) = get(s.body, "requireSession", nothing)
autocommit(s::Sent) = get(s.body, "autoCommit", nothing)

mutable struct Server
    port::Int
    listener::Sockets.TCPServer
    "Scripted steps: `(:reply, status, body)`, `(:hang,)` or `(:drop,)`."
    script::Vector{Tuple}
    "Every request but the health check, in arrival order."
    sent::Vector{Sent}
    "Requests that arrived with nothing scripted for them."
    unscripted::Vector{Sent}
    "Sockets of requests held open by `hang!`, closed by `stop`."
    held::Vector{Any}
end

"Starts a stand-in on a free loopback port."
function start()
    listener = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(listener)[2])
    server = Server(port, listener, Tuple[], Sent[], Sent[], Any[])
    @async begin
        while true
            sock = try
                accept(listener)
            catch
                break
            end
            @async _serve(server, sock)
        end
    end
    return server
end

"Runs `f(server)` against a fresh stand-in, stopped on the way out."
function with_server(f)
    server = start()
    try
        return f(server)
    finally
        stop(server)
    end
end

function stop(server::Server)
    close(server.listener)
    for sock in server.held
        try
            close(sock)
        catch
        end
    end
    return nothing
end

"A DSN for this stand-in; `suffix` carries a path and a query string."
dsn(server::Server, suffix::AbstractString="") = "frostlake://127.0.0.1:$(server.port)$(suffix)"

"The next request is answered with `body` and `status`."
reply!(server::Server, body::AbstractString; status::Int=200) =
    push!(server.script, (:reply, status, String(body)))

"The next request is held open and never answered."
hang!(server::Server) = push!(server.script, (:hang,))

"The next request's socket is closed without an answer."
drop!(server::Server) = push!(server.script, (:drop,))

"How many scripted steps no request has taken yet."
pending(server::Server) = length(server.script)

"Every `POST /api/execute`, in order."
executes(server::Server) = filter(s -> s.path == "/api/execute", server.sent)

"The SQL of every `POST /api/execute`, in order."
statements(server::Server) = [sql(s) for s in executes(server)]

function _serve(server::Server, sock)
    keep = false
    try
        request_line = readline(sock)
        isempty(strip(request_line)) && return
        fields = split(request_line)
        method = String(fields[1])
        path = length(fields) >= 2 ? String(fields[2]) : ""
        sent = 0
        while true
            line = readline(sock)
            isempty(strip(line)) && break
            m = match(r"^Content-Length:\s*(\d+)"i, line)
            m === nothing || (sent = parse(Int, m[1]))
        end
        text = sent > 0 ? String(read(sock, sent)) : ""
        if path == "/api/health"
            _respond(sock, 200, "{\"status\":\"healthy\",\"activeSessions\":0}")
            return
        end
        decoded = isempty(text) ? nothing : json_decode(text)
        body = decoded isa AbstractDict ? Dict{String,Any}(decoded) : Dict{String,Any}()
        record = Sent(method, path, body)
        push!(server.sent, record)
        if isempty(server.script)
            push!(server.unscripted, record)
            _respond(sock, 500, "{\"success\":false,\"errorMessage\":\"unscripted request\"}")
            return
        end
        step = popfirst!(server.script)
        if step[1] === :reply
            _respond(sock, step[2], step[3])
        elseif step[1] === :hang
            push!(server.held, sock)
            keep = true
        end
        # :drop closes the socket below without an answer.
    catch
        # The client hung up, or the listener went away.
    finally
        if !keep
            try
                close(sock)
            catch
            end
        end
    end
end

function _respond(sock, status::Int, body::String)
    reason = status == 200 ? "OK" : status == 404 ? "Not Found" :
             status == 405 ? "Method Not Allowed" : "Status"
    write(sock, "HTTP/1.1 $(status) $(reason)\r\nContent-Type: application/json\r\n" *
                "Content-Length: $(ncodeunits(body))\r\nConnection: close\r\n\r\n" * body)
end

"A one-row result set holding a status line, as DDL and USE answer."
status_set(text::AbstractString) = string(
    "{\"columns\":[{\"dataType\":\"VARCHAR\",\"name\":\"status\",\"nullable\":false,",
    "\"precision\":0,\"scale\":0}],\"rowCount\":1,\"rows\":[[\"", text, "\"]],",
    "\"updateCount\":-1}")

"A one-row, one-column NUMBER result set."
number_set(name::AbstractString, value::Integer) = string(
    "{\"columns\":[{\"dataType\":\"NUMBER\",\"name\":\"", name, "\",\"nullable\":false,",
    "\"precision\":38,\"scale\":0}],\"rowCount\":1,\"rows\":[[", value, "]],",
    "\"updateCount\":-1}")

"An answer from an engine that reports `newSession` (0.1.0 and later)."
answer(session::AbstractString; started::Bool=false, sets=String[]) = string(
    "{\"errorMessage\":null,\"executionTimeMs\":1,\"newSession\":", started,
    ",\"resultSets\":[", join(sets, ","), "],\"sessionId\":\"", session,
    "\",\"success\":true}")

"An answer from an engine that predates `newSession` (0.0.7)."
legacy_answer(session::AbstractString; sets=String[]) = string(
    "{\"errorMessage\":null,\"executionTimeMs\":1,\"resultSets\":[", join(sets, ","),
    "],\"sessionId\":\"", session, "\",\"success\":true}")

"A statement the engine refused, in the session it ran in."
refused(session::AbstractString, message::AbstractString) = string(
    "{\"errorMessage\":\"", message, "\",\"executionTimeMs\":0,\"newSession\":true,",
    "\"resultSets\":[],\"sessionId\":\"", session, "\",\"success\":false}")

"The 404 body a request that requires its session gets when it is gone."
session_gone(session::AbstractString) = string(
    "{\"errorMessage\":\"Session '", session, "' does not exist or has expired.\",",
    "\"executionTimeMs\":0,\"newSession\":false,\"resultSets\":[],\"sessionId\":null,",
    "\"success\":false}")

"What `DELETE /api/sessions/{id}` answers for a live session."
const RELEASED = string("{\"errorMessage\":null,\"executionTimeMs\":0,\"newSession\":false,",
                        "\"resultSets\":[],\"sessionId\":null,\"success\":true}")

end # module ScriptedServer
