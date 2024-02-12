using StaticLint: StaticLint, run_lint_on_text, comp, convert_offset_to_line,
    convert_offset_to_line_from_lines, should_be_filtered
import CSTParser
using Test

function lint_test(source::String, expected_substring::String, verbose=true)
    io = IOBuffer()
    run_lint_on_text(source; io=io)
    output = String(take!(io))
    result = contains(output, expected_substring)
    verbose && !result && @warn "Not matching " output expected_substring
    return result
end

function lint_has_error_test(source::String, verbose=false)
    io = IOBuffer()
    run_lint_on_text(source; io=io)
    result = String(take!(io))
    all_lines = split(result, "\n")

    verbose && @info result
    # We remove decorations
    return any(l->startswith(l, "Line "), all_lines)
end

@testset "interface" begin
    source = "1 + 2 \n 1 + 10 \n true || true\n10"
    @test lint_has_error_test(source)
    @test lint_test(source,
        "Line 3, column 2: The first argument of a `||` call is a boolean literal. at offset 17 of")
end

@testset "forbidden macros" begin
    @testset "@async" begin
        source = """
            function f()
                @async 1 + 2
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 2, column 5: Macro @spawn should be used instead of @async.")
    end

    @testset "Locally disabling lint" begin
        @testset "lint-disable-lint" begin
            @test !lint_has_error_test("""
                function f()
                    @async 1 + 2 # lint-disable-line
                end
                """)
            @test !lint_has_error_test("""
                function f()
                    @async 1 + 2 #lint-disable-line
                end
                """)

            @test !lint_has_error_test("""
                function f()
                    @async 1 + 2 #  lint-disable-line
                end
                """)

            @test lint_has_error_test("""
                function f()
                    @async 1 + 2 #  lint-disable-line
                    @async 1 + 3
                end
                """)
        end
        @testset "lint-disable-next-line" begin
            @test !lint_has_error_test("""
                function f()
                    # lint-disable-next-line
                    @async 1 + 2
                end
                """)
            @test !lint_has_error_test("""
                function f()
                    # lint-disable-next-line
                    @async 1 + 2
                end
                """)

            @test !lint_has_error_test("""
                function f()
                    # lint-disable-next-line
                    @async 1 + 2
                end
                """)

            @test lint_has_error_test("""
                function f()
                    # lint-disable-next-line
                    @async 1 + 2

                    @async 1 + 3
                end
                """)
            @test lint_has_error_test("""
                function f()
                    @async 1 + 2
                    # lint-disable-next-line

                    @async 1 + 3
                end
                """)
            @test lint_has_error_test("""
                function f()
                    @async 1 + 2
                    # lint-disable-next-line
                    @async 1 + 3
                end
                """)

            source = """
                function f()
                    # lint-disable-next-line
                    @async 1 + 2

                    @async 1 + 3
                end
                """
            source_lines = split(source, "\n")
            @test convert_offset_to_line_from_lines(46, source_lines) == (3, 4, Symbol("lint-disable-line"))
            @test convert_offset_to_line_from_lines(64, source_lines) == (5, 4, nothing)
        end
    end
end

@testset "forbidden functions" begin
    @testset "nthreads() as a const" begin
        source = """
            const x = Threads.nthreads()
            function f()
                return x
            end
            """
        @test lint_has_error_test(source)
        @test lint_test(source,
            "Line 1, column 11: Threads.nthreads() should not be used in a constant variable.")
    end

    @testset "nthreads() not as a const" begin
        source = """
            function f()
                return Threads.nthreads()
            end
            """
        @test !lint_has_error_test(source)
    end
end

@testset "Comparison" begin
    t(s1, s2) = comp(CSTParser.parse(s1), CSTParser.parse(s2))
    @test t("Threads.nthreads()", "Threads.nthreads()")
    @test !t("QWEThreads.nthreads()", "Threads.nthreads()")
    @test !t("Threads.nthreads()", "QWEThreads.nthreads()")
    @test !t("Threads.nthreads()", "Threads.qwenthreads()")

    @test t("1 + 2", "1+2")
    @test t("1 + 2", "1+hole_variable")
    @test t("hole_variable + hole_variable", "1 + hole_variable")
    @test t("hole_variable + 1", "1 + hole_variable")

    @test t("@async hole_variable", "@async begin 1 + 2 end")
end

@testset "offset to line" begin
    source = """
        function f()
            return Threads.nthreads()
        end
        """
    @test_throws BoundsError convert_offset_to_line(-1, source)
    @test_throws BoundsError convert_offset_to_line(length(source) + 2, source)

    @test convert_offset_to_line(10, source) == (1, 10, nothing)
    @test convert_offset_to_line(20, source) == (2, 7, nothing)
    @test convert_offset_to_line(43, source) == (2, 30, nothing)
    @test convert_offset_to_line(47, source) == (3, 4, nothing)
end

@testset "Should be filtered" begin
    filters = StaticLint.LintCodes[StaticLint.MissingReference, StaticLint.IncorrectCallArgs]
    hint_as_string1 = "Missing reference at offset 24104 of /Users/alexandrebergel/Documents/RAI/raicode11/src/DataExporter/export_csv.jl"
    hint_as_string2 = "Line 254, column 19: Possible method call error. at offset 8430 of /Users/alexandrebergel/Documents/RAI/raicode11/src/Compiler/Front/problems.jl"
    @test should_be_filtered(hint_as_string1, filters)
    @test !should_be_filtered(hint_as_string2, filters)

    @test should_be_filtered(hint_as_string1, filters)
    @test !should_be_filtered(hint_as_string2, filters)
end