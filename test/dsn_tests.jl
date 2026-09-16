using Test
using Dates
using Frostlake: parse_dsn, base_url, use_statements, quote_identifier, UsageError, _seconds

@testset "dsn" begin
    @testset "host and port" begin
        config = parse_dsn("frostlake://localhost")
        @test config.host == "localhost"
        @test config.port == 18082      # the engine's own default
        @test !config.secure
        @test base_url(config) == "http://localhost:18082"

        @test parse_dsn("frostlake://db.example:1234").port == 1234
        # http and https have defaults of their own; reading the engine's into
        # them would quietly move the DSN to another port.
        @test parse_dsn("http://h").port == 80
        @test parse_dsn("https://h").port == 443
        @test parse_dsn("https://h").secure
        @test parse_dsn("http://h:8080").port == 8080
        @test base_url(parse_dsn("https://h:8443")) == "https://h:8443"
        # IPv6 literals keep their brackets out of the host.
        @test parse_dsn("frostlake://[::1]:9000").host == "::1"
        @test parse_dsn("frostlake://[::1]").port == 18082
    end

    @testset "scope" begin
        config = parse_dsn("frostlake://h/MY_DB?schema=PUBLIC&role=R&warehouse=W")
        @test config.database == "MY_DB"
        @test config.schema == "PUBLIC"
        @test config.role == "R"
        @test config.warehouse == "W"
        # Dependency order: a role and warehouse before the database they scope.
        @test use_statements(config) == ["USE ROLE \"R\"", "USE WAREHOUSE \"W\"",
                                         "USE DATABASE \"MY_DB\"", "USE SCHEMA \"PUBLIC\""]
        @test use_statements(parse_dsn("frostlake://h")) == String[]
        @test parse_dsn("frostlake://h/").database === nothing
        @test parse_dsn("frostlake://h/My%20Db").database == "My Db"
    end

    @testset "durations" begin
        @test parse_dsn("frostlake://h").timeout == 300.0
        @test parse_dsn("frostlake://h?timeout=30").timeout == 30.0
        @test parse_dsn("frostlake://h?timeout=30s").timeout == 30.0
        @test parse_dsn("frostlake://h?timeout=500ms").timeout == 0.5
        @test parse_dsn("frostlake://h?timeout=5m").timeout == 300.0
        @test parse_dsn("frostlake://h?timeout=1h").timeout == 3600.0
        @test parse_dsn("frostlake://h?timeout=1.5s").timeout == 1.5
        # Zero is meaningful: it removes the bound.
        @test parse_dsn("frostlake://h?timeout=0").timeout == 0.0
        @test parse_dsn("frostlake://h?connectTimeout=2s").connect_timeout == 2.0
        @test parse_dsn("frostlake://h?idleLimit=10m").idle_limit == 600.0
        @test_throws UsageError parse_dsn("frostlake://h?timeout=soon")
        @test_throws UsageError parse_dsn("frostlake://h?timeout=-1")
    end

    @testset "tls" begin
        @test parse_dsn("frostlake://h?tls=true").secure
        @test parse_dsn("frostlake://h?tls=1").secure
        @test !parse_dsn("frostlake://h?tls=false").secure
        # An https DSN stays secure whatever the parameter says.
        @test parse_dsn("https://h?tls=false").secure
        @test_throws UsageError parse_dsn("frostlake://h?tls=maybe")
    end

    @testset "refusals" begin
        @test_throws UsageError parse_dsn("mysql://h")
        @test_throws UsageError parse_dsn("localhost:18082")
        @test_throws UsageError parse_dsn("frostlake://")
        # Silently dropping a password is worse than saying so.
        @test_throws UsageError parse_dsn("frostlake://user:pass@h")
        # A typo in `schema` or `timeout` would change behaviour without saying.
        @test_throws UsageError parse_dsn("frostlake://h?schemas=S")
        @test_throws UsageError parse_dsn("frostlake://h?Schema=S")
        @test_throws UsageError parse_dsn("frostlake://h/db/extra")
        @test_throws UsageError parse_dsn("frostlake://h:0")
        @test_throws UsageError parse_dsn("frostlake://h:99999")
        @test_throws UsageError parse_dsn("frostlake://h:port")
        @test_throws UsageError parse_dsn("frostlake://h?schema=")
    end

    @testset "text outside ASCII" begin
        @test parse_dsn("frostlake://h/żółw").database == "żółw"
        @test parse_dsn("frostlake://h/%C5%BC").database == "ż"
        @test parse_dsn("frostlake://h?schema=żółw").schema == "żółw"
        @test parse_dsn("frostlake://żółw.example:1234").host == "żółw.example"
        # An unknown parameter is still reported, not a StringIndexError.
        @test_throws UsageError parse_dsn("frostlake://h?żkey=v")
    end

    @testset "identifiers are always quoted" begin
        @test quote_identifier("db") == "\"db\""
        @test quote_identifier("MY DB") == "\"MY DB\""
        # A name arriving from a DSN cannot break out of its quotes.
        @test quote_identifier("a\"b") == "\"a\"\"b\""
        @test use_statements(parse_dsn("frostlake://h/\"; DROP DATABASE x --")) ==
              ["USE DATABASE \"\"\"; DROP DATABASE x --\""]
        @test_throws UsageError quote_identifier("")
    end

    @testset "DSN names fold like unquoted identifiers" begin
        # A plain name selects the upper-case object it folds to, as it does
        # unquoted in SQL; anything else keeps its case. Every name is quoted.
        @test use_statements(parse_dsn("frostlake://h/scoped_db?schema=scoped_schema")) ==
              ["USE DATABASE \"SCOPED_DB\"", "USE SCHEMA \"SCOPED_SCHEMA\""]
        @test use_statements(parse_dsn("frostlake://h/select")) == ["USE DATABASE \"SELECT\""]
        @test use_statements(parse_dsn("frostlake://h/My%20Db")) == ["USE DATABASE \"My Db\""]
        @test use_statements(parse_dsn("frostlake://h/żółw")) == ["USE DATABASE \"żółw\""]
    end

    @testset "a parameter without a value" begin
        @test_throws UsageError parse_dsn("frostlake://h?tls")
        @test_throws UsageError parse_dsn("frostlake://h?schema")
    end

    @testset "timeouts given as periods" begin
        @test _seconds(30) == 30.0
        @test _seconds(Minute(10)) == 600.0
        @test _seconds(Millisecond(1500)) == 1.5
        @test _seconds(nothing) === nothing
        # A month or a year has no fixed length, so it names no timeout.
        @test_throws UsageError _seconds(Month(1))
        @test_throws UsageError _seconds(Year(1))
    end
end
