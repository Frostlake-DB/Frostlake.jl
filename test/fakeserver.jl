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
