using StaticLint: run_lint_on_text
using Test

function lint_test(source::String, expected_substring::String)
    io = IOBuffer()
    run_lint_on_text(source; io=io)
    result = String(take!(io))
    return contains(result, expected_substring)
end

function lint_check_test(source::String)
    io = IOBuffer()
    run_lint_on_text(source; io=io)
    result = String(take!(io))
    all_lines = split(result, "\n")

    # We remove decorations
    return any(l->startswith(l, "Line "), all_lines)
end

@testset "interface" begin
    source = "1 + 2 \n 1 + 10 \n true || true\n10"
    @test lint_check_test(source)
    @test lint_test(source,
            "Line 3, column 3: The first argument of a `||` call is a boolean literal. at offset 17 of")
end

@testset "forbidden macros" begin
    source = """
        function f()
            @async 1 + 2
        end
        """
    @test lint_check_test(source)
end