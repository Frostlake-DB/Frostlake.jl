# A socket that answers HTTP badly on purpose.
#
# The transport failures worth testing are the ones a real engine never
# produces: a proxy error page on the right port, a JSON body that is not a
# Frostlake answer, a server that accepts and then says nothing. Each needs a
# listener that misbehaves in one specific way.

module FakeServer

using Sockets

"""
    with_server(f, body; content_type, status)

Runs `f(port)` against a listener that answers every request with `body`, or —
when `body === nothing` — accepts the connection and never answers at all. The
listener is closed on the way out.
"""
function with_server(f, body; content_type::String="text/html", status::String="200 OK")
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    @async begin
        while true
            sock = try
                accept(server)
            catch
                break
            end
            @async _serve(sock, body, content_type, status)
        end
    end
    try
        return f(port)
    finally
        close(server)
    end
end

"""
    with_recorder(f)

Runs `f(port, requests)` against a listener that answers `GET /api/health` and
`POST /api/execute` the way an engine does, appending the body of every
`/api/execute` request it was sent to `requests`. What the driver PUT ON THE WIRE
is what these cases are about, so the answers are the least an engine could send.
"""
function with_recorder(f)
    requests = String[]
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    @async begin
        while true
            sock = try
                accept(server)
            catch
                break
            end
            @async _record(sock, requests)
        end
    end
    try
        return f(port, requests)
    finally
        close(server)
    end
end

function _record(sock, requests)
    try
        request_line = readline(sock)
        isempty(strip(request_line)) && return
        fields = split(request_line)
        path = length(fields) >= 2 ? fields[2] : ""
        sent = 0
        while true
            line = readline(sock)
            isempty(strip(line)) && break
            m = match(r"^Content-Length:\s*(\d+)"i, line)
            m === nothing || (sent = parse(Int, m[1]))
        end
        body = sent > 0 ? String(read(sock, sent)) : ""
        answer = if path == "/api/health"
            "{\"status\":\"healthy\"}"
        else
            push!(requests, body)
            "{\"success\":true,\"sessionId\":\"s-1\",\"resultSets\":[]}"
        end
        write(sock, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" *
                    "Content-Length: $(ncodeunits(answer))\r\n" *
                    "Connection: close\r\n\r\n" * answer)
    catch
        # The client hung up, or the listener went away.
    finally
        try
            close(sock)
        catch
        end
    end
end

function _serve(sock, body, content_type, status)
    try
        # Consume the request, body included: a client whose write is never read
        # can fail for that reason instead of the one under test.
        length = 0
        while true
            line = readline(sock)
            isempty(strip(line)) && break
            m = match(r"^Content-Length:\s*(\d+)"i, line)
            m === nothing || (length = parse(Int, m[1]))
        end
        length > 0 && read(sock, length)

        if body === nothing
            # Accept and never answer: the caller's own deadline is the point.
            sleep(10)
        else
            write(sock, "HTTP/1.1 $(status)\r\nContent-Type: $(content_type)\r\n" *
                        "Content-Length: $(ncodeunits(body))\r\n" *
                        "Connection: close\r\n\r\n" * body)
        end
    catch
        # The client hung up, or the listener went away. Either way there is
        # nothing left to serve.
    finally
        try
            close(sock)
        catch
        end
    end
end

end # module FakeServer
