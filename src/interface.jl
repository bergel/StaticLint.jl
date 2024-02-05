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
        return f.cst, [(x, string(haserror(x) ? LintCodeDescriptions[x.meta.error] : "Missing reference", " at offset ", offset)) for (offset, x) in collect_hints(f.cst, env)]
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
            append!(hints, [(x, string(haserror(x) ? LintCodeDescriptions[x.meta.error] : "Missing reference", " at offset ", offset, " of ", p)) for (offset, x) in collect_hints(f.cst, getenv(f, server))])
        end
        return root, hints
    else
        return root
    end
end

global global_server = setup_server()
const essential_options = LintOptions() #false, false, false, false, false, false, false, false, false, false)

# Return (line, column) for a given offset in a source
function convert_offset_to_line(offset::Int64, source::String)
    all_lines = split(source, "\n")

    current_index = 0
    for (index_line,line) in enumerate(all_lines)
        offset in current_index:(current_index + length(line)) && return index_line, (offset - current_index)
        current_index += length(line)
    end
    @error "offset $offset is outside source code (max offset = $(length(source))"
end

function print_hint(hint, source::String, io::IO=stdout)
    hint_as_string = hint[2]

    ss = split(hint_as_string)
    offset_as_string = ss[length(ss) - 2]
    offset = Base.parse(Int64, offset_as_string)
    line_number, column = convert_offset_to_line(offset, source)

    printstyled(io, "Line $(line_number), column $(column): ", color=:green)
    println(io, hint_as_string)
end

function run_lint(rootpath::String; server = global_server, io::IO=stdout, lint_options=essential_options)
    file,hints = StaticLint.lint_file(rootpath, server; gethints = true, lint_options=lint_options)

    source = file.source
    printstyled(io, "-" ^ 10 * "\n", color=:red)
    for h in hints
        print_hint(h, source, io)
    end
    printstyled(io, "-" ^ 10 * "\n", color=:red)
end

function run_lint_on_text(source::String; server = global_server, io::IO=stdout, lint_options=essential_options)
    tmp_file_name = tempname()
    open(tmp_file_name, "w") do file
        write(file, source)
        flush(file)
        run_lint(tmp_file_name; server, io, lint_options)
    end
end