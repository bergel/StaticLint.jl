function setup_server(env = dirname(SymbolServer.Pkg.Types.Context().env.project_file), depot = first(SymbolServer.Pkg.depots()), cache = joinpath(dirname(pathof(SymbolServer)), "..", "store"))
    server = StaticLint.FileServer()
    ssi = SymbolServerInstance(depot, cache)
    _, symbols = SymbolServer.getstore(ssi, env)
    extended_methods = SymbolServer.collect_extended_methods(symbols)
    server.external_env = ExternalEnv(symbols, extended_methods, Symbol[])
    server
end

"""
    lint_string(s, server; gethints = false)

Parse a string and run a semantic pass over it. This will mark scopes, bindings,
references, and lint hints. An annotated `EXPR` is returned or, if `gethints = true`,
it is paired with a collected list of errors/hints.
"""
function lint_string(s::String, server = setup_server(); gethints = false, lint_options::LintOptions=LintOptions())
    empty!(server.files)
    f = File("", s, CSTParser.parse(s, true), nothing, server)
    env = getenv(f, server)
    setroot(f, f)
    setfile(server, "", f)
    semantic_pass(f)
    check_all(f.cst, lint_options, env)
    if gethints
        hints = []
        for (offset, x) in collect_hints(f.cst, env)
            if haserror(x)
                push!(hints, (x, LintCodeDescriptions[x.meta.error]))
            elseif lint_options.missingrefs
                push!(hints, (x, "Missing reference", " at offset ", offset))
            end
        end
        return f.cst, hints
    else
        return f.cst
    end
end

"""
    lint_file(rootpath, server)

Read a file from disc, parse and run a semantic pass over it. The file should be the
root of a project, e.g. for this package that file is `src/StaticLint.jl`. Other files
in the project will be loaded automatically (calls to `include` with complicated arguments
are not handled, see `followinclude` for details). A `FileServer` will be returned
containing the `File`s of the package.
"""
function lint_file(rootpath, server = setup_server(); gethints = false, lint_options::LintOptions=LintOptions())
    empty!(server.files)
    root = loadfile(server, rootpath)
    semantic_pass(root)
    for f in values(server.files)
        check_all(f.cst, lint_options, getenv(f, server))
    end
    if gethints
        hints = []
        for (p,f) in server.files
            hints_for_file = []
            for (offset, x) in collect_hints(f.cst, getenv(f, server))
                if haserror(x)
                    push!(hints_for_file, (x, string(LintCodeDescriptions[x.meta.error], " at offset ", offset, " of ", p)))
                elseif lint_options.missingrefs
                    push!(hints_for_file, (x, string("Missing reference", " at offset ", offset, " of ", p)))
                end
            end
            append!(hints, hints_for_file)
        end
        return root, hints
    else
        return root
    end
end

global global_server = setup_server()
const essential_options = LintOptions(true, false, true, true, true, true, true, true, true, false, true, false)

# Return (line, column) for a given offset in a source
function convert_offset_to_line_from_filename(offset::Int64, filename::String)
    all_lines = open(io->readlines(io), filename)
    return convert_offset_to_line_from_lines(offset, all_lines)
end

function convert_offset_to_line(offset::Int64, source::String)
    return convert_offset_to_line_from_lines(offset, split(source, "\n"))
end


function convert_offset_to_line_from_lines(offset::Int64, all_lines)
    offset < 0 && throw(BoundsError("source", offset))

    current_index = 1
    annotation_previous_line = -1
    annotation = nothing
    for (index_line,line) in enumerate(all_lines)
        # printstyled("$offset in $(current_index):$(current_index + length(line)) , $index_line\n", color=:purple)
        if endswith(line, "lint-disable-next-line")
            annotation_previous_line = index_line+1
        end

        if offset in current_index:(current_index + length(line))
            if endswith(line, "lint-disable-line") || (index_line == annotation_previous_line)
                annotation = Symbol("lint-disable-line")
            else
                annotation = nothing
            end
            # isdefined(Main, :Infiltrator) && Main.infiltrate(@__MODULE__, Base.@locals, @__FILE__, @__LINE__)
            result = index_line, (offset - current_index + 1), annotation
            annotation = nothing
            return result
        end
        current_index += length(line) + 1 #1 is for the Return line
    end

    throw(BoundsError("source", offset))
end

# Return true if the hint was printed, else it was filtered
function filter_and_print_hint(hint, io::IO=stdout)
    hint_as_string = hint[2]

    ss = split(hint_as_string)
    filename = string(last(ss))

    offset_as_string = ss[length(ss) - 2]
    offset = Base.parse(Int64, offset_as_string)

    line_number, column, annotation_line = convert_offset_to_line_from_filename(offset, filename)

    if isnothing(annotation_line)
        printstyled(io, "Line $(line_number), column $(column): ", color=:green)
        println(io, hint_as_string)
        return true
    end
    return false
end

"""
    run_lint(rootpath::String; server = global_server, io::IO=stdout, lint_options=essential_options)

Run lint rules on a file `rootpath`, which must be an existing non-folder file.
Example of use:
    import StaticLint
    StaticLint.run_lint("foo/bar/myfile.jl")

"""
function run_lint(rootpath::String; server = global_server, io::IO=stdout, lint_options=essential_options)
    file,hints = StaticLint.lint_file(rootpath, server; gethints = true, lint_options=lint_options)

    printstyled(io, "-" ^ 10 * "\n", color=:blue)
    filtered_and_printed_hints = filter(h->filter_and_print_hint(h, io), hints)

    if isempty(filtered_and_printed_hints)
        printstyled(io, "No potential threats were found.\n", color=:green)
    else
        printstyled(io, "$(length(filtered_and_printed_hints)) potential threats were found\n", color=:red)
    end
    printstyled(io, "-" ^ 10 * "\n", color=:blue)
end

function run_lint_on_text(source::String; server = global_server, io::IO=stdout, lint_options=essential_options)
    tmp_file_name = tempname()
    open(tmp_file_name, "w") do file
        write(file, source)
        flush(file)
        run_lint(tmp_file_name; server, io, lint_options)
    end
end