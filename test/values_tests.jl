using Test
using Dates
using Frostlake: ColumnInfo, ZonedTimestamp, utc, convert_cell, base_type_name,
                 temporal_kind, is_binary_type, is_integral_column, declared_scale,
                 parse_temporal, parse_date, parse_time, parse_naive, parse_zoned,
                 decode_hex, format_time, format_naive, format_zoned,
                 json_decode, JSONUndefined

column(datatype; precision=nothing, scale=nothing) =
    ColumnInfo("C", datatype, nothing, precision, scale)

cell(text, datatype; scale=nothing) =
    convert_cell(json_decode(text), column(datatype; scale=scale))

@testset "values" begin
    @testset "type names" begin
        @test base_type_name("NUMBER(38,0)") == "NUMBER"
        @test base_type_name(" varchar ") == "VARCHAR"
        @test base_type_name(nothing) == ""
        @test temporal_kind("DATE") === :date
        @test temporal_kind("TIME") === :time
        @test temporal_kind("TIMESTAMP_NTZ") === :naive
        @test temporal_kind("DATETIME") === :naive
        @test temporal_kind("TIMESTAMP_TZ") === :zoned
        @test temporal_kind("TIMESTAMP_LTZ") === :zoned
        @test temporal_kind("VARCHAR") === :none
        @test is_binary_type("BINARY")
        @test is_binary_type("varbinary")
        @test !is_binary_type("VARCHAR")
    end

    @testset "scale decides what is whole" begin
        # The wire carries scale as its own field; an inline spelling is a
        # fallback for servers that put both in the type name.
        @test is_integral_column(column("NUMBER"; scale=0))
        @test !is_integral_column(column("NUMBER"; scale=2))
        @test is_integral_column(column("INTEGER"))
        @test !is_integral_column(column("FLOAT"))
        @test is_integral_column(column("NUMBER(38,0)"))
        @test !is_integral_column(column("NUMBER(10,2)"))
        @test declared_scale(column("NUMBER(10,2)")) == 2
        @test declared_scale(column("NUMBER"; scale=4)) == 4
        @test declared_scale(column("VARCHAR")) == 0
    end

    @testset "numbers" begin
        @test cell("1", "NUMBER"; scale=0) === 1
        @test cell("-7", "INTEGER") === -7
        # A NUMBER(38,0) holds values no Int64 can name.
        big_cell = cell("12345678901234567890123456789012345678", "NUMBER"; scale=0)
        @test big_cell isa BigInt
        @test big_cell == big"12345678901234567890123456789012345678"
        @test cell("3.5", "NUMBER"; scale=1) === 3.5
        @test cell("2", "FLOAT") === 2.0
        @test cell("1.5", "FLOAT") === 1.5
        # Not a numeric column at all: an integral literal stays exact.
        @test cell("5", "VARIANT") === 5
    end

    @testset "text, booleans and NULL" begin
        @test cell("null", "VARCHAR") === nothing
        @test convert_cell(JSONUndefined(), column("VARIANT")) === nothing
        @test cell("true", "BOOLEAN") === true
        @test cell("\"text\"", "VARCHAR") == "text"
        # The engine renders semi-structured values as text.
        @test cell("\"{\\\"a\\\":1}\"", "VARIANT") == "{\"a\":1}"
        # A server that sent one structurally still reads as the same text.
        @test convert_cell(json_decode("{\"a\":1}"), column("VARIANT")) == "{\"a\":1}"
    end

    @testset "temporals" begin
        @test cell("\"2024-01-15\"", "DATE") == Date(2024, 1, 15)
        @test cell("\"10:30:45\"", "TIME") == Time(10, 30, 45)
        @test cell("\"2024-01-15 10:30:45.123\"", "TIMESTAMP_NTZ") ==
              DateTime(2024, 1, 15, 10, 30, 45, 123)

        zoned = cell("\"2024-01-15 10:30:45.123 +0100\"", "TIMESTAMP_TZ")
        @test zoned isa ZonedTimestamp
        @test zoned.datetime == DateTime(2024, 1, 15, 10, 30, 45, 123)
        @test zoned.offset == Second(3600)
        @test utc(zoned) == DateTime(2024, 1, 15, 9, 30, 45, 123)

        @test parse_zoned("2024-01-15 10:30:45 -08:00").offset == Second(-28800)
        @test parse_zoned("2024-01-15T10:30:45Z").offset == Second(0)
        @test utc(parse_zoned("2024-01-15 00:30:00 +02:00")) == DateTime(2024, 1, 14, 22, 30)
        # A zoned column without an offset still names a wall clock.
        @test parse_temporal("2024-01-15 10:30:45", :zoned) ==
              ZonedTimestamp(DateTime(2024, 1, 15, 10, 30, 45), Second(0))

        # Julia's Time holds nanoseconds, finer than anything the wire carries.
        @test parse_time("10:30:45.123456789") == Time(10, 30, 45, 123, 456, 789)
        @test parse_time("1:02:03") == Time(1, 2, 3)
        # A DateTime holds milliseconds; a finer fraction has nowhere to go.
        @test parse_naive("2024-01-15 10:30:45.123456") ==
              DateTime(2024, 1, 15, 10, 30, 45, 123)
        @test parse_naive("2024-01-15T10:30:45") == DateTime(2024, 1, 15, 10, 30, 45)

        # Text that is not a temporal after all is kept as text: a value the
        # caller can still read beats one the driver threw away.
        @test parse_date("nonsense") === nothing
        @test parse_time("25:99") === nothing
        @test cell("\"not a date\"", "DATE") == "not a date"
    end

    @testset "binary" begin
        @test cell("\"DEADBEEF\"", "BINARY") == UInt8[0xde, 0xad, 0xbe, 0xef]
        @test cell("\"\"", "BINARY") == UInt8[]
        @test decode_hex("00ff") == UInt8[0x00, 0xff]
        # Not hex after all: kept as text rather than silently mangled.
        @test decode_hex("ABC") === nothing
        @test decode_hex("ZZ") === nothing
        @test cell("\"nothex\"", "BINARY") == "nothex"
    end

    @testset "rendering" begin
        @test format_time(Time(1, 2, 3)) == "01:02:03"
        @test format_time(Time(1, 2, 3, 456)) == "01:02:03.456"
        @test format_time(Time(0, 0, 0, 0, 1)) == "00:00:00.000001"
        @test format_naive(DateTime(2024, 3, 4, 1, 2, 3)) == "2024-03-04 01:02:03.000"
        @test format_naive(DateTime(2024, 3, 4, 1, 2, 3, 456)) == "2024-03-04 01:02:03.456"
        @test format_zoned(ZonedTimestamp(DateTime(2024, 1, 15, 10, 30), Second(5400))) ==
              "2024-01-15 10:30:00.000 +01:30"
        @test format_zoned(ZonedTimestamp(DateTime(2024, 1, 15, 10, 30), Second(-28800))) ==
              "2024-01-15 10:30:00.000 -08:00"
        @test format_zoned(ZonedTimestamp(DateTime(2024, 1, 15, 10, 30))) ==
              "2024-01-15 10:30:00.000 +00:00"
        # What the engine printed reads back to the same value.
        @test format_zoned(parse_zoned("2024-01-15 10:30:45.123 +0100")) ==
              "2024-01-15 10:30:45.123 +01:00"
    end
end
