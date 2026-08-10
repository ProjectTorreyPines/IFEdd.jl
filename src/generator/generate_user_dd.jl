# Public API: `IFEdd.generate_user_dd(...)`.
#
# Wraps GenerateDD rather than re-implementing emission: we reuse
# `GenerateDD.imas_julia_struct` and bolt on:
#   - `_supertype` substitution so user concretes subtype the right
#     (module-qualified) `IFEdd.AbstractIFE*{T}`
#   - a hand-emitted `<target_module>.dd{T}` container that embeds each
#     slot with the correct module-prefix (user / `IFEdd.` / `IMASdd.`)
#   - cross-package `_all_info` registration inside the user module's
#     `__init__`, with a content-hash version-skew warning.

import GenerateDD

const _DEFAULT_SLOTS = ["balance_of_plant", "blanket", "build", "core_profiles",
                       "core_sources", "costing", "driver", "neutronics",
                       "pellets", "requirements", "summary"]

# Which slots are owned by IFEdd vs IMASdd in the default container. Used
# to emit the right `IFEdd.X{T}` / `IMASdd.X{T}` prefix for slots that
# the user did not override.
const _SLOT_OWNERS = Dict(
    "balance_of_plant" => :IMASdd, "blanket" => :IMASdd,
    "build"           => :IFEdd,  "core_profiles" => :IMASdd,
    "core_sources"    => :IMASdd, "costing"       => :IMASdd,
    "driver"          => :IFEdd,  "neutronics"    => :IMASdd,
    "pellets"         => :IMASdd, "requirements"  => :IMASdd,
    "summary"         => :IFEdd,
)

"""
    IFEdd.generate_user_dd(; output_dir, target_module, schema_extra_dir,
                            slot_bindings=Dict{Symbol,Symbol}(),
                            ifedd_default_schema_dir=nothing,
                            ifedd_abstracts_file=nothing,
                            verbose=false)
        -> @NamedTuple{idstypes_file, dd_file, manifest_file, manifest, concretes}

Generate a customized `<target_module>.dd{T}` struct and supporting IDS
types into `output_dir`. The downstream user package is expected to
`include` the generated files from its own `src/<target_module>.jl`.

# Example

```julia
IFEdd.generate_user_dd(
    output_dir = joinpath(@__DIR__, "..", "src"),
    target_module = :MyIFEProject,
    schema_extra_dir = joinpath(@__DIR__, "..", "data_dictionary",
                                "data_structures_extra"),
    slot_bindings = Dict(:summary => :my_summary),
)
```

This emits three files into `output_dir`:

- `MyIFEProject_idstypes.jl` — user concrete IDS struct definitions
  (e.g. `my_summary{T} <: IFEdd.AbstractIFESummary{T}`).
- `MyIFEProject_dd.jl` — `MyIFEProject.dd{T} <: IFEdd.AbstractIFEDD{T}` container,
  embedding user concretes for overridden slots and `IFEdd.X{T}` /
  `IMASdd.X{T}` for the rest, plus an `__init__()` that registers user
  concretes' `_all_info` entries.
- `MyIFEProject_dd_manifest.json` — provenance/hashes for freshness CI.

Errors are raised as `IFEdd.GeneratorError(reason::Symbol, detail)`:
`:ifedd_not_locatable`, `:schema_dir_missing`, `:subdir_in_schema_dir`,
`:malformed_json`, `:bad_supertype`, `:supertype_mismatch`,
`:concrete_not_in_schemas`, `:ambiguous_binding`,
`:user_name_shadows_ifedd_default`, `:output_dir_readonly`,
`:pidlock_timeout`.

The online documentation carries a worked, copy-pastable recipe, plus the
`slot_bindings` forms for substituting IDS below the top level.
"""
function generate_user_dd(; output_dir::AbstractString,
                            target_module::Symbol,
                            schema_extra_dir::AbstractString,
                            slot_bindings::AbstractDict = Dict{Symbol,Symbol}(),
                            ifedd_default_schema_dir::Union{AbstractString,Nothing} = nothing,
                            ifedd_abstracts_file::Union{AbstractString,Nothing} = nothing,
                            verbose::Bool = false)
    # 1. Resolve IFEdd-side defaults
    ifedd_root = _force_pkgdir_ifedd()
    if ifedd_abstracts_file === nothing || ifedd_default_schema_dir === nothing
        ifedd_root === nothing && throw(GeneratorError(:ifedd_not_locatable,
            "pkgdir(IFEdd) returned `nothing`; pass `ifedd_default_schema_dir` and `ifedd_abstracts_file` explicitly."))
    end
    abstracts_file = something(ifedd_abstracts_file,
        joinpath(ifedd_root, "data_dictionary", "abstracts.json"))
    defaults_dir = something(ifedd_default_schema_dir,
        joinpath(ifedd_root, "data_dictionary", "data_structures_extra"))

    # 2. Load the abstract lattice. `abstracts.json` lists abstracts at every
    # depth, but only the TOP-LEVEL ones (parent ends in `IDStop{T}`)
    # correspond to slots on the `dd` container, so slot resolution filters
    # for those. The full set is kept as `valid_abstracts` to validate
    # user-side `_supertype` markers on nested paths.
    abstracts_blob = JSON.parsefile(abstracts_file)
    # In-memory promoter so older lockfiles still load. The on-disk file is
    # schema 3 for anything IFEdd ships.
    if String(get(abstracts_blob, "version", "0")) < "3.0.0"
        abstracts_blob = _promote_schema_2_to_3(abstracts_blob)
    end
    abstracts_content_hash = hash_file(abstracts_file)
    ifedd_version = String(abstracts_blob["version"])
    valid_abstracts = Set(keys(abstracts_blob["abstracts"]))
    top_level_abstracts = Set(
        a for (a, spec) in abstracts_blob["abstracts"]
        if get(spec, "parent", "") == "IMASdd.IDStop{T}"
    )
    # `default_concretes` is nested — `abs → path → concrete`. Slot resolution
    # wants a flat `abs → concrete` map; each top-level abstract has exactly
    # one default (parent_path = concrete name).
    default_concretes_map = Dict{String,String}()
    for a in top_level_abstracts
        default_concretes_map[a] = default_concrete(abstracts_blob, a)
    end
    # Sorted (abs_name, default_concrete) pairs for deterministic emission.
    abs_default_pairs = sort!(collect(default_concretes_map); by=first)

    # 3. Read user schemas
    isdir(schema_extra_dir) || throw(GeneratorError(:schema_dir_missing, schema_extra_dir))
    user_schemas = _read_user_schemas(schema_extra_dir)
    _check_user_no_shadow(user_schemas, default_concretes_map)

    # 4. Resolve slot bindings — top-level slot keys only. Abstract-name keys
    # are ignored here (`_resolve_slot_bindings` looks up only
    # `slot_sym ∈ top_level_slots`); they are validated and consumed by
    # `_build_substitution_graph` below.
    bindings = _resolve_slot_bindings(user_schemas, slot_bindings,
                                      abs_default_pairs, valid_abstracts)

    # 4.5. Substitution graph — validates abstract-name keys, detects
    # :slot_key_collision / :unknown_binding_key / etc., and produces the
    # (default_concrete → user_concrete) map that drives the regex pass and
    # the parent-IDS regeneration.
    substitution_graph = _build_substitution_graph(slot_bindings,
                                                    abstracts_blob,
                                                    user_schemas,
                                                    target_module)

    # 5. Output dir writable check
    _check_output_writable(output_dir)

    # 6. Collect distinct user concretes to emit
    #    - top-level user concretes (from `bindings`)
    #    - nested user concretes (from `substitution_graph`,
    #      parent_kind != "IDStop")
    user_concrete_names = String[b.concrete for b in values(bindings) if b.source === :user]
    for (_, e) in substitution_graph
        e.parent_kind == "IDStop" && continue
        push!(user_concrete_names, e.user_concrete)
    end
    sort!(unique!(user_concrete_names))

    # 7. Acquire lock and emit
    return with_generator_lock(output_dir) do
        _emit_all(output_dir, target_module, schema_extra_dir,
                  user_schemas, user_concrete_names, bindings,
                  substitution_graph, abstracts_blob,
                  defaults_dir, abstracts_file, abstracts_content_hash,
                  ifedd_version, verbose)
    end
end

"""
    _force_pkgdir_ifedd(; _force_nil=false) -> Union{String,Nothing}

Internal indirection so a test can force the `pkgdir(IFEdd) === nothing`
branch (sysimage / relocated package scenario) without `Mocking.jl`. Set
the global `_FORCE_PKGDIR_NIL[]` from a test to flip the result.
"""
const _FORCE_PKGDIR_NIL = Ref(false)
function _force_pkgdir_ifedd()
    _FORCE_PKGDIR_NIL[] && return nothing
    return pkgdir(@__MODULE__)
end

function _read_user_schemas(dir::AbstractString)
    # Reject subdirs
    for entry in readdir(dir)
        path = joinpath(dir, entry)
        if isdir(path)
            throw(GeneratorError(:subdir_in_schema_dir,
                                 "subdirectory not allowed: $(entry)"))
        end
    end
    user_schemas = Dict{String,Any}()
    for f in readdir(dir)
        endswith(f, ".json") || continue
        name = replace(f, r"\.json$" => "")
        raw = try
            JSON.parsefile(joinpath(dir, f))
        catch e
            throw(GeneratorError(:malformed_json,
                                 (path=joinpath(dir, f), error=string(e))))
        end
        user_schemas[name] = raw
    end
    return user_schemas
end

function _check_user_no_shadow(user_schemas, default_concretes_map)
    defaults = Set(values(default_concretes_map))
    for name in keys(user_schemas)
        if name in defaults
            throw(GeneratorError(:user_name_shadows_ifedd_default,
                                 "user schema `$(name)` shadows an IFEdd default concrete name"))
        end
    end
end

function _resolve_slot_bindings(user_schemas, slot_bindings,
                                abs_default_pairs, valid_abstracts)
    # First pass: validate any user schemas that declare a _supertype
    # (catches typos / unknown abstracts early).
    for (uname, uschema) in user_schemas
        root = get(uschema, uname, nothing)
        root isa AbstractDict || continue
        super = get(root, "_supertype", nothing)
        super === nothing && continue
        if !(super in valid_abstracts)
            throw(GeneratorError(:bad_supertype,
                                 (concrete=uname, supertype=super,
                                  known=collect(valid_abstracts))))
        end
    end

    bindings = Dict{Symbol,NamedTuple}()
    for (abs_name, default_concrete) in abs_default_pairs
        slot_sym = Symbol(default_concrete)
        # Find user concretes declaring this _supertype
        matches = String[]
        for (uname, uschema) in user_schemas
            root = get(uschema, uname, nothing)
            root isa AbstractDict || continue
            get(root, "_supertype", "") == abs_name && push!(matches, uname)
        end
        sort!(matches)

        kwarg = get(slot_bindings, slot_sym, nothing)
        if kwarg !== nothing
            kwname = string(kwarg)
            haskey(user_schemas, kwname) ||
                throw(GeneratorError(:concrete_not_in_schemas,
                                     "slot_bindings[:$(slot_sym)] = :$(kwname) — concrete not in user schemas"))
            root = get(user_schemas[kwname], kwname, nothing)
            root isa AbstractDict ||
                throw(GeneratorError(:concrete_not_in_schemas,
                                     "user schema $(kwname).json has no top-level `$(kwname)` entry"))
            decl_super = get(root, "_supertype", nothing)
            if decl_super != abs_name
                throw(GeneratorError(:supertype_mismatch,
                                     (slot=slot_sym, want=abs_name, got=decl_super,
                                      concrete=kwname)))
            end
            bindings[slot_sym] = (concrete=kwname, source=:user, abstract=abs_name)
        elseif length(matches) == 1
            bindings[slot_sym] = (concrete=matches[1], source=:user, abstract=abs_name)
        elseif length(matches) > 1
            throw(GeneratorError(:ambiguous_binding,
                                 (slot=slot_sym, candidates=matches,
                                  hint="pass `slot_bindings=Dict(:$(slot_sym) => :<one_of_$(matches)>)`")))
        else
            bindings[slot_sym] = (concrete=default_concrete,
                                  source=Symbol("ifedd-default"), abstract=abs_name)
        end
    end
    return bindings
end

function _check_output_writable(output_dir::AbstractString)
    try
        mkpath(output_dir)
    catch e
        throw(GeneratorError(:output_dir_readonly,
                             (path=output_dir, error=string(e))))
    end
    testfile = joinpath(output_dir, ".ifedd_gen_write_test")
    try
        write(testfile, UInt8[])
        rm(testfile)
    catch e
        throw(GeneratorError(:output_dir_readonly,
                             (path=output_dir, error=string(e))))
    end
end

function _emit_all(output_dir, target_module, schema_extra_dir,
                   user_schemas, user_concrete_names, bindings,
                   substitution_graph, abstracts_blob,
                   defaults_dir, abstracts_file, abstracts_content_hash,
                   ifedd_version, verbose)
    target_str = string(target_module)
    idstypes_path = joinpath(output_dir, "$(target_str)_idstypes.jl")
    dd_path       = joinpath(output_dir, "$(target_str)_dd.jl")
    manifest_path = joinpath(output_dir, "$(target_str)_dd_manifest.json")

    # Generate raw struct emission for user concretes via GenerateDD.
    # `substitution_graph` drives _expand_workdir_for_substitution! +
    # _apply_substitution_graph + _apply_parent_supertype_recovery, and
    # `all_info_entries` carries user-emitted `(Type, Symbol) => Info(...)`
    # tuples for re-registration in the dd file's __init__.
    idstypes_body, all_info_entries = _emit_user_idstypes(
        schema_extra_dir, user_schemas,
        user_concrete_names, target_module,
        substitution_graph, abstracts_blob,
        defaults_dir)
    atomic_write(idstypes_path, _idstypes_header(target_module) * idstypes_body)

    # Hand-emit container dd + __init__. `_emit_user_dd` reads the
    # substituted-parent set so substituted top-level slots emit a BARE
    # `build{T}` (resolving to the user module's local variant) instead of
    # `IFEdd.build{T}`, and `all_info_entries` lets __init__ register the
    # user concretes in `IMASdd._all_info`.
    dd_body = _emit_user_dd(target_module, bindings,
                            abstracts_content_hash, ifedd_version,
                            idstypes_body, substitution_graph,
                            all_info_entries)
    atomic_write(dd_path, dd_body)

    # Manifest
    inputs_hashes = _collect_input_hashes(abstracts_file, schema_extra_dir,
                                          user_concrete_names)
    output_hashes = Dict(
        "$(target_str)_idstypes.jl" => hash_file(idstypes_path),
        "$(target_str)_dd.jl"       => hash_file(dd_path),
    )
    manifest = _build_manifest(ifedd_version, abstracts_content_hash,
                               inputs_hashes, output_hashes, bindings,
                               target_module)
    manifest_text = _format_manifest_json(manifest)
    atomic_write(manifest_path, manifest_text)

    concretes_summary = [
        (slot=slot, concrete=b.concrete, source=b.source, abstract=b.abstract)
        for (slot, b) in sort!(collect(bindings); by=first)
    ]

    verbose && @info "generate_user_dd wrote" idstypes_path dd_path manifest_path
    return (idstypes_file=idstypes_path,
            dd_file=dd_path,
            manifest_file=manifest_path,
            manifest=manifest,
            concretes=concretes_summary)
end

function _idstypes_header(target_module::Symbol)
    return """
    # ============================================================================
    # AUTO-GENERATED by IFEdd.generate_user_dd — DO NOT EDIT
    # Container module: $(target_module)
    # See `$(target_module)_dd_manifest.json` for input/output hashes.
    # ============================================================================

    """
end

function _emit_user_idstypes(schema_extra_dir, user_schemas,
                              user_concrete_names, target_module,
                              substitution_graph=Dict{String,NamedTuple}(),
                              abstracts_blob=nothing,
                              defaults_dir=nothing)
    isempty(user_concrete_names) && return ("# (no user concrete IDS to emit)\n", String[])

    workdir = mktempdir(prefix="ifedd_user_gen_")
    try
        imasdd_root = pkgdir(IMASdd)
        cocos_src = joinpath(imasdd_root, "data_dictionary", "cocos_signals.jl")
        symlink(cocos_src, joinpath(workdir, "cocos_signals.jl"))
        mkdir(joinpath(workdir, "data_structures"))
        extra_dir = joinpath(workdir, "data_structures_extra")
        mkdir(extra_dir)
        for name in user_concrete_names
            src = joinpath(schema_extra_dir, "$(name).json")
            isfile(src) || continue
            symlink(src, joinpath(extra_dir, "$(name).json"))
        end

        # Expand the workdir so substituted parents can be regenerated:
        # symlinks IFEdd-default `build.json` etc. in, and appends the parent
        # names to `user_concrete_names` so the loop below pulls in their
        # field sets.
        if !isempty(substitution_graph) && defaults_dir !== nothing
            _expand_workdir_for_substitution!(workdir, substitution_graph,
                                               user_concrete_names,
                                               defaults_dir, user_schemas)
        end

        desired = String[]
        for name in user_concrete_names
            append!(desired, keys(GenerateDD.imas_dd_ids(workdir, name)))
        end
        sort!(unique!(desired))

        raw = join(GenerateDD.imas_julia_struct(workdir, desired), "\n")
        content, all_info_entries = _postprocess_user_idstypes(raw, user_concrete_names)

        # GenerateDD emits a spurious empty-fields root struct for each user
        # concrete whose schema uses element-type paths (`<name>[:].field`).
        # Strip those duplicates BEFORE the supertype-override regex runs,
        # otherwise it would match the wrong block.
        content = _strip_duplicate_element_struct(content, user_schemas)

        # Walk EVERY entry in the user schemas (top-level and nested) and
        # apply supertype overrides at all depths, validating each marker
        # against IFEdd's published lattice (abstracts.json).
        overrides, parents = _collect_all_user_supertypes(user_schemas)
        content = _apply_user_supertype_overrides(content, overrides, parents)

        # Regex pass over the postprocessed content: rewrites field-type and
        # ctor-call references in parent IDSs to point at user concretes.
        # Count-asserted per entry (raises :substitution_missed /
        # :substitution_over_match on drift).
        if !isempty(substitution_graph)
            # Augment the graph with auto-recursive entries — user concretes
            # whose nested `_supertype` markers reference an abstract the user
            # bound at the top level. The regex pass treats them like base
            # entries.
            auto_graph = _build_auto_recursive_graph(user_schemas,
                                                      substitution_graph)
            full_graph = merge(substitution_graph, auto_graph)
            content = _apply_substitution_graph(content, full_graph)
            # Regenerated parent IDSs come back as `<: IMASdd.IDStop{T}`,
            # since they lack `_supertype` markers in the user schemas (the
            # user never wrote the parent schema).
            # Rewrite to `<: IFEdd.AbstractIFE…{T}` so the parent still
            # subtypes the IFEdd lattice.
            if abstracts_blob !== nothing
                content = _apply_parent_supertype_recovery(content,
                                                            substitution_graph,
                                                            abstracts_blob)
            end
        end

        # Strip the GenerateDD-emitted top-level `dd` container (we emit our own)
        content = _strip_generated_dd(content)

        return (content, all_info_entries)
    finally
        rm(workdir; recursive=true, force=true)
    end
end

function _postprocess_user_idstypes(content::AbstractString, user_concrete_names)
    # Qualify IMASdd abstract types and runtime helpers (same regex set
    # as scripts/generate.jl's postprocess). Then:
    #   1. extract `_all_info` entries so the caller can
    #      thread them into the dd file's `__init__` block,
    #   2. strip the `const _all_info = Dict{…}(…)` literal from the
    #      idstypes body (it would otherwise SHADOW `IMASdd._all_info`).
    # Returns `(content_without_all_info, entries::Vector{String})`.
    abstract_types = [
        "FilledFields", "IDS", "DD", "IDStop", "IDSraw",
        "IDSvectorElement", "IDSvectorRawElement", "IDSvectorIonElement",
        "IDSvectorStaticElement", "IDSvectorTimeElement",
    ]
    out = String(content)
    for t in abstract_types
        out = replace(out, Regex("(<:\\s*)$t\\{") => SubstitutionString("\\1IMASdd.$t{"))
        out = replace(out, Regex("(<:\\s*)$t\\b(?!\\.)") => SubstitutionString("\\1IMASdd.$t"))
    end
    out = replace(out, r"(::|\b)IDSvector\{" => s"\1IMASdd.IDSvector{")
    out = replace(out, r"\bThreadSafeDicts\." => "IMASdd.ThreadSafeDicts.")
    out = replace(out, r"(?<![A-Za-z_\.])Info\(" => "IMASdd.Info(")

    # Capture entries BEFORE the strip so they can be carried into the dd
    # file's `__init__`. The block has already been
    # qualified above (`Info(` → `IMASdd.Info(`), so the captured entries
    # are runtime-ready.
    all_info_entries = _extract_all_info_entries(out)

    open_marker = "const _all_info = Dict{Tuple{<:Type,Symbol},Info}("
    if occursin(open_marker, out)
        idx = findfirst(open_marker, out)
        if idx !== nothing
            cut_start = first(idx)
            # The `const _all_info` block runs from here to EOF.
            out = out[1:prevind(out, cut_start)]
        end
    end
    return (out, all_info_entries)
end

function _extract_all_info_entries(raw_qualified::AbstractString)
    # Pull the `(Type, :field) => IMASdd.Info(...)` lines out of the
    # already-postprocessed (qualified) content.
    entries = String[]
    open_marker = "const _all_info = Dict{Tuple{<:Type,Symbol},Info}("
    idx = findfirst(open_marker, raw_qualified)
    idx === nothing && return entries
    block = raw_qualified[first(idx)+length(open_marker):end]
    # Drop the trailing ')'
    block = rstrip(block)
    if endswith(block, ")")
        block = block[1:prevind(block, lastindex(block))]
    end
    for line in split(block, '\n')
        s = strip(line)
        isempty(s) && continue
        # Each entry ends in `,`. Trim trailing comma for safety.
        s_stripped = endswith(s, ",") ? s[1:end-1] : s
        push!(entries, String(s_stripped))
    end
    return entries
end

"""
    _collect_all_user_supertypes(user_schemas) -> (overrides::Dict, parents::Dict)

Visits **every** entry in **every** user schema (not
just the top-level concrete root), harvests `_supertype` markers at all
depths, validates each abstract name against IFEdd's published lattice
(`abstracts.json`), and returns:

- `overrides[struct_name] = abstract_name` (bare; qualified to
  `IFEdd.<abstract_name>{T}` at substitution time)
- `parents[struct_name] = qualified_parent_string` (matches the
  IMASdd parent that the GenerateDD-emitted user struct currently
  carries; produced by `classify_parent`)

Raises `GeneratorError(:unknown_abstract, …)` if a user marker names
an abstract not present in `IFEdd.dd_abstracts`. The valid set is
read from `abstracts.json` at call time so the validator stays in
sync with the live lattice.

Mirrors `scripts/generate.jl::read_all_supertypes` but for user-side
emission: result is keyed on user concrete struct names (e.g.
`my_summary__beam`), and replacement substitutes to qualified
`IFEdd.AbstractIFE…{T}`.
"""
function _collect_all_user_supertypes(user_schemas)
    # Read valid abstracts from IFEdd's own lockfile so user markers
    # must reference a real abstract before generation proceeds.
    ifedd_root = pkgdir(@__MODULE__)
    valid = if ifedd_root !== nothing
        absp = joinpath(ifedd_root, "data_dictionary", "abstracts.json")
        isfile(absp) ? Set(keys(JSON.parsefile(absp)["abstracts"])) : Set{String}()
    else
        Set{String}()
    end

    overrides = Dict{String,String}()
    parents   = Dict{String,String}()
    for (uname, schema) in user_schemas
        for (path, entry) in schema
            entry isa AbstractDict || continue
            haskey(entry, "_supertype") || continue
            abs_name = String(entry["_supertype"])
            if !isempty(valid) && !(abs_name in valid)
                throw(GeneratorError(:unknown_abstract,
                    "User schema marker `_supertype: \"$(abs_name)\"` on path " *
                    "`$(path)` references an abstract not in IFEdd's lattice. " *
                    "Supported abstracts: $(sort!(collect(valid))). " *
                    "(See `IFEdd/data_dictionary/abstracts.json`.)"))
            end
            validate_marker_placement(path, entry)
            struct_name = path_to_struct_name(path)
            overrides[struct_name] = abs_name
            parents[struct_name]   = classify_parent(path, entry) * "{T}"
        end
    end
    return overrides, parents
end

function _apply_user_supertype_overrides(content::AbstractString,
                                         overrides::Dict{String,String},
                                         parents::Dict{String,String})
    out = String(content)
    missed = String[]
    for (name, abs_name) in overrides
        parent_qualified = get(parents, name, "IMASdd.IDS{T}")
        escaped_parent = replace(parent_qualified, "{" => "\\{", "}" => "\\}")
        # `\Q…\E` literalizes the struct name; trailing `\{T\}` keeps
        # `my_summary` from partial-matching `my_summary__beam`. No `\b`
        # at the end — fails at line-end since `}` and `\n` are both
        # non-word characters (matches scripts/generate.jl invariant).
        pattern = Regex("(mutable struct \\Q$(name)\\E\\{T\\}\\s*<:\\s*)" *
                        escaped_parent)
        replacement = SubstitutionString("\\1IFEdd.$(abs_name){T}")
        new_out = replace(out, pattern => replacement)
        new_out == out && push!(missed, "$(name) <: $(parent_qualified) -> IFEdd.$(abs_name){T}")
        out = new_out
    end
    if !isempty(missed)
        throw(GeneratorError(:override_missed,
            "User-side apply_supertype_overrides found no match for:\n  " *
            join(missed, "\n  ") *
            "\n(path_to_struct_name / classify_parent may mis-derive, OR " *
            "the GenerateDD emission shape changed.)"))
    end
    return out
end

function _strip_generated_dd(content::AbstractString)
    # GenerateDD always emits, for the user concretes' first path segments
    # (e.g. "my_summary"), a top-level `dd{T} <: IFEdd.AbstractIFEDD{T}` plus its
    # `FilledFields____dd` companion + positional constructor + short-form
    # constructor. We replace these with our hand-emitted dd container,
    # so strip them out here.
    lines = split(content, '\n')
    out = String[]
    skipping = false
    for line in lines
        if skipping
            line == "end" && (skipping = false)
            continue
        end
        # `mutable struct dd{...}` or `mutable struct FilledFields____dd <: ...`
        # or `function dd{T}(...)` — all open a block we discard.
        m1 = match(r"^mutable struct\s+(FilledFields____dd|dd)\b", line)
        m2 = match(r"^function\s+(FilledFields____dd|dd)(\{|\()", line)
        if m1 !== nothing || m2 !== nothing
            skipping = true
            continue
        end
        # short-form constructor: `dd(; ...) = dd{Float64}(...)`
        if occursin(r"^dd\([^)]*\)\s*=", line)
            continue
        end
        push!(out, line)
    end
    return join(out, '\n')
end

function _emit_user_dd(target_module::Symbol, bindings, abstracts_hash,
                       ifedd_version, idstypes_body,
                       substitution_graph=Dict{String,NamedTuple}(),
                       all_info_entries::Vector{String}=String[])
    target_str = string(target_module)
    # A top-level slot whose parent IDS got regenerated via
    # _expand_workdir_for_substitution! must reference the LOCAL custom
    # variant (bare `build{T}`), not the IFEdd default (`IFEdd.build{T}`).
    # The custom variant is emitted into MyPkg_idstypes.jl and resolves
    # to the user module's local scope.
    substituted_parents = _substituted_parent_idss(substitution_graph)
    # Emit all 11 default container slots (mixed IFEdd / IMASdd / user
    # owners), alphabetically ordered for deterministic emission.
    slots_sorted = sort!(copy(_DEFAULT_SLOTS))
    fields = String[]
    inits = String[]
    setfield_lines = String[]
    filled_fields = String[]
    binding_table = collect(bindings)

    for slot in slots_sorted
        slot_sym = Symbol(slot)
        if haskey(bindings, slot_sym)
            b = bindings[slot_sym]
            type_str = if b.source === :user
                "$(b.concrete){T}"             # bare — concrete lives in user module
            elseif slot in substituted_parents
                # parent IDS got regenerated → the user module's local
                # `build{T}` etc. supersedes `IFEdd.build{T}`.
                "$(b.concrete){T}"
            else  # :ifedd-default
                "IFEdd.$(b.concrete){T}"
            end
        else
            # Slot has no abstract / no binding → IMASdd-owned default
            type_str = "IMASdd.$(slot){T}"
        end
        push!(fields, "    var\"$(slot)\"::$(type_str)")
        push!(inits, "$(type_str)(; frozen)")
        # _name on each slot MUST equal the slot key — IMASdd.add_filled
        # uses `getfield(child, :_name)` to look up the corresponding
        # `_filled` Bool on the parent (dd). For user concretes whose
        # default `_name` is the IDS type name (e.g. `:my_summary`), we
        # rewrite here. For IFEdd defaults this is a no-op rewrite.
        push!(setfield_lines, "    setfield!(getfield(ids, :$(slot)), :_parent, WeakRef(ids))")
        push!(setfield_lines, "    setfield!(getfield(ids, :$(slot)), :_name, Symbol(\"$(slot)\"))")
        push!(filled_fields, "    var\"$(slot)\"::Bool")
    end

    # Doc summary of bindings (only the slots that have abstracts)
    binding_lines = ["    * $(slot_sym) ← $(b.concrete) ($(b.source))"
                     for (slot_sym, b) in sort!(collect(bindings); by=first)]

    filled_struct = """
    mutable struct FilledFields____dd <: IMASdd.FilledFields
    $(join(filled_fields, "\n"))
    end
    """

    container = """
    \"\"\"
        $(target_str).dd{T} <: IFEdd.AbstractIFEDD{T}

    Customized IFE data dictionary baked from IFEdd v$(ifedd_version) with
    bindings:
    $(join(binding_lines, "\n"))

    Generated by `IFEdd.generate_user_dd`; do not edit.
    \"\"\"
    mutable struct dd{T} <: IFEdd.AbstractIFEDD{T}
    $(join(fields, "\n"))
        global_time::Float64
        _aux::IMASdd.ThreadSafeDicts.ThreadSafeDict{Symbol,Any}
        _name::Symbol
        _filled::FilledFields____dd
        _frozen::Bool
        _threads_lock::ReentrantLock
        _in_expression::IMASdd.ThreadSafeDicts.ThreadSafeDict{Int,Vector{Symbol}}
        _parent::WeakRef

        # Required so the keyword constructor below doesn't suppress Julia's
        # auto-generated inner constructor.
        dd{T}(args...) where T = new{T}(args...)
    end
    """

    ctor = """
    function dd{T}(; frozen::Bool=false) where T
        ids = dd{T}(
    $(join(["        " * i * "," for i in inits], "\n"))
            0.0,
            IMASdd.ThreadSafeDicts.ThreadSafeDict{Symbol,Any}(),
            Symbol(""),
            FilledFields____dd($(join(fill("false", length(slots_sorted)), ", "))),
            frozen,
            ReentrantLock(),
            IMASdd.ThreadSafeDicts.ThreadSafeDict{Int,Vector{Symbol}}(),
            WeakRef(nothing),
        )
    $(join(setfield_lines, "\n"))
        return ids
    end

    dd(; frozen::Bool=false) = dd{Float64}(; frozen)
    """

    init_block = _emit_init_block(target_module, bindings,
                                  abstracts_hash, ifedd_version, idstypes_body,
                                  all_info_entries)

    return """
    # ============================================================================
    # AUTO-GENERATED by IFEdd.generate_user_dd — DO NOT EDIT
    # IFEdd v$(ifedd_version), abstracts sha256: $(abstracts_hash)
    # ============================================================================

    const _IFEDD_VERSION_AT_BAKE        = $(repr(ifedd_version))
    const _IFEDD_ABSTRACTS_HASH_AT_BAKE = $(repr(abstracts_hash))

    $(filled_struct)

    $(container)

    $(ctor)

    $(init_block)
    """
end

function _emit_init_block(target_module::Symbol, bindings, abstracts_hash,
                           ifedd_version, idstypes_body,
                           all_info_entries::Vector{String}=String[])
    # Build the `merge!(IMASdd._all_info, Dict(...))` block from user-emitted
    # entries. An empty entry list emits no merge call at all, so bakes with no
    # user concretes at depth stay unchanged.
    merge_block = if isempty(all_info_entries)
        "        # (no user concrete _all_info entries to register)"
    else
        body = join(["            $(e)," for e in all_info_entries], "\n")
        """
                merge!(IMASdd._all_info, Dict{Tuple{<:Type,Symbol},IMASdd.Info}(
        $(body)
                ))"""
    end

    return """
    function __init__()
        # Version-skew assertion. Compares the abstracts.json content hash
        # baked into this file with the hash of the currently loaded
        # IFEdd's abstracts.json. Mismatch raises a one-shot @warn —
        # graceful, not fatal.
        ifedd_root = pkgdir(IFEdd)
        if ifedd_root !== nothing
            abs_path = joinpath(ifedd_root, "data_dictionary", "abstracts.json")
            if isfile(abs_path)
                current_hash = IFEdd.hash_file(abs_path)
                if current_hash != _IFEDD_ABSTRACTS_HASH_AT_BAKE
                    @warn \"\"\"
                    \$(@__MODULE__) was generated against IFEdd abstracts.json
                    with sha256 \$(_IFEDD_ABSTRACTS_HASH_AT_BAKE), but the loaded
                    IFEdd has sha256 \$(current_hash). The dd shape or _all_info
                    entries may have drifted. Run:

                        using Pkg; Pkg.build(\$(string(@__MODULE__)))

                    and restart Julia.

                    (IFEdd version at bake: \$(_IFEDD_VERSION_AT_BAKE);
                     loaded: \$(pkgversion(IFEdd)).)
                    \"\"\" maxlog=1
                end
            end
        else
            @debug \"\$(@__MODULE__): cannot locate IFEdd on disk; \" *
                   \"abstracts.json drift detection skipped.\" maxlog=1
        end
        # Register user-emitted `(Type, Symbol) => Info(...)`
        # entries in `IMASdd._all_info` so IMASdd path-printing / introspection
        # finds user concretes and the regenerated parent IDSs.
$(merge_block)
        return nothing
    end
    """
end

function _collect_input_hashes(abstracts_file, schema_extra_dir,
                                user_concrete_names)
    out = Dict{String,String}()
    out["abstracts_json"] = hash_file(abstracts_file)
    # Per-user-concrete schema file
    for name in user_concrete_names
        p = joinpath(schema_extra_dir, "$(name).json")
        isfile(p) && (out["user_schema:$(name)"] = hash_file(p))
    end
    return out
end

function _build_manifest(ifedd_version, abstracts_hash, inputs_hashes,
                          output_hashes, bindings, target_module)
    slot_pairs = sort!(collect(bindings); by=first)
    return Dict{String,Any}(
        "ifedd_version" => ifedd_version,
        "ifedd_abstracts_sha256" => abstracts_hash,
        "generator_version" => "1.0.0",
        "target_module" => string(target_module),
        "inputs" => Dict{String,Any}(k => v for (k, v) in inputs_hashes),
        "outputs" => Dict{String,Any}(k => v for (k, v) in output_hashes),
        "slot_bindings" => Dict{String,Any}(
            string(slot) => Dict{String,Any}(
                "concrete" => b.concrete,
                "abstract" => b.abstract,
                "source" => string(b.source),
            )
            for (slot, b) in slot_pairs
        ),
    )
end

function _format_manifest_json(m)
    io = IOBuffer()
    # canonicalize for byte-stable manifest
    c = canonicalize_json(m)
    JSON.print(io, c, 2)
    s = String(take!(io))
    endswith(s, "\n") || (s *= "\n")
    return s
end

# ============================================================================
# Convenience macro: IFEdd.@bake_dd <NAME> = (kwargs...)
# ----------------------------------------------------------------------------
# Thin wrapper around `generate_user_dd` that emits into a hidden sub-module
# (created on the fly inside IFEdd) and binds the resulting `dd{T}` type at
# the caller's module under the assignment-LHS name. Trades the `module …
# include … end` boilerplate for one line.
# ============================================================================

"""
Within-session cache: `manifest_hash => hidden_module`. Reruns of
`@bake_dd` with identical inputs return the same hidden module — and
therefore the same concrete `dd{T}` type — so downstream specializations
(FUSE actors etc.) aren't invalidated by a no-op rebake. Only ephemeral
bakes (no `output_dir`) are cached; persistent bakes always re-create.
"""
const __BAKED_DDS__ = Dict{String,Module}()

"""
    IFEdd._bake_into_hidden_module(parent::Module, name::Symbol; ...) -> Module

Implementation helper for [`@bake_dd`](@ref). `parent` is captured at
call site via `@__MODULE__` in the macro; it is used only for
provenance/debug (the hidden module lives under IFEdd, not under
`parent`).
"""
function _bake_into_hidden_module(parent::Module, name::Symbol;
                                   schema_dir::AbstractString,
                                   slot_bindings = Dict{Symbol,Symbol}(),
                                   output_dir::Union{AbstractString,Nothing} = nothing,
                                   ifedd_default_schema_dir::Union{AbstractString,Nothing} = nothing,
                                   ifedd_abstracts_file::Union{AbstractString,Nothing} = nothing,
                                   verbose::Bool = false)
    persistent = output_dir !== nothing
    actual_output_dir = something(output_dir, mktempdir(prefix="ifedd_bake_"))

    result = generate_user_dd(
        output_dir = actual_output_dir,
        target_module = name,
        schema_extra_dir = schema_dir,
        slot_bindings = slot_bindings,
        ifedd_default_schema_dir = ifedd_default_schema_dir,
        ifedd_abstracts_file = ifedd_abstracts_file,
        verbose = verbose,
    )

    # Cache key includes everything the manifest covers (input hashes,
    # slot_bindings, target_module, ifedd_version). target_module being
    # part of the key is intentional: re-baking under a different binding
    # name yields a fresh type (so cross-binding code can compare types).
    cache_key = persistent ? nothing : hash_canonical_json(result.manifest)
    if cache_key !== nothing && haskey(__BAKED_DDS__, cache_key)
        return __BAKED_DDS__[cache_key]
    end

    # Hidden module name — unique enough that repeated bakes don't collide
    # before cache check inserts them.
    suffix = string(hash((name, actual_output_dir, length(__BAKED_DDS__))) % UInt32; base=16)
    mod_name = Symbol("__bake_", name, "_", suffix)
    hidden = Module(mod_name)
    # Bind the two modules directly instead of `using` them. The hidden module
    # belongs to no package, so `using IMASdd` would resolve against the
    # caller's active project — which only needs IFEdd, not its dependencies.
    Core.eval(hidden, Expr(:const, Expr(:(=), :IMASdd, IMASdd)))
    Core.eval(hidden, Expr(:const, Expr(:(=), :IFEdd, IFEdd)))
    Base.include(hidden, result.idstypes_file)
    Base.include(hidden, result.dd_file)

    provenance = (
        manifest      = result.manifest,
        idstypes_file = result.idstypes_file,
        dd_file       = result.dd_file,
        manifest_file = result.manifest_file,
        persistent    = persistent,
        baked_in      = parent,
        target_module = name,
    )
    Core.eval(hidden,
              Expr(:const, Expr(:(=), :__IFEDD_BAKE_PROVENANCE__, provenance)))

    cache_key !== nothing && (__BAKED_DDS__[cache_key] = hidden)
    return hidden
end

"""
    IFEdd.@bake_dd <NAME> = (kwarg = val, ...)

Bake a customized `dd{T}` and bind its type to `<NAME>` in the caller's
current module. RHS is a `NamedTuple` of keyword arguments forwarded to
[`IFEdd.generate_user_dd`](@ref), with two relaxations:

- `output_dir` is optional (defaults to a fresh tempdir → ephemeral).
- `target_module` is set automatically to `<NAME>`.

# Examples

REPL / script — ephemeral:
```julia
julia> using IFEdd

julia> IFEdd.@bake_dd dd_mine = (
           schema_dir    = "/path/to/data_structures_extra",
           slot_bindings = Dict(:summary => :my_summary),
       )

julia> d = dd_mine();
julia> d isa IFEdd.AbstractIFESummary{Float64}
true
```

Inside a package module — persistent (source emitted into `output_dir`):
```julia
module MyPkg
    using IFEdd
    IFEdd.@bake_dd Custom = (
        schema_dir    = joinpath(@__DIR__, "schemas"),
        output_dir    = joinpath(@__DIR__, "gen"),
        slot_bindings = Dict(:summary => :my_summary),
    )
end
# MyPkg.Custom() now constructs a customized dd
```

# Caching

Ephemeral bakes are cached by manifest hash within the session, so
re-running an identical `@bake_dd` returns the **same** concrete type
(downstream method specializations stay valid). Different `<NAME>` →
different cache key (so types are non-interchangeable).

# World-age

`<NAME>` is assigned via `global` from inside a `let` block. Constructing
`<NAME>()` in the *same* top-level expression hits a world-age error —
use a separate statement, or `Base.invokelatest(<NAME>)`. At REPL each
prompt is its own world, so `dd_mine()` on the next line works.

# Provenance accessors

[`IFEdd.bake_manifest(T)`](@ref) and [`IFEdd.bake_source(T)`](@ref) return
the manifest dict and generated source paths for a baked type.
"""
macro bake_dd(ex)
    if !(Meta.isexpr(ex, :(=), 2) && ex.args[1] isa Symbol)
        error("@bake_dd expects `<NAME> = (kwarg = val, ...)`")
    end
    name = ex.args[1]
    opts_expr = ex.args[2]
    return quote
        let _opts = $(esc(opts_expr))
            _mod = _bake_into_hidden_module(
                $(esc(:(@__MODULE__))),
                $(QuoteNode(name));
                _opts...,
            )
            global $(esc(name)) = _mod.dd
        end
    end
end

"""
    IFEdd.bake_manifest(T::Type) -> Dict{String,Any}

Provenance manifest for a type produced by [`@bake_dd`](@ref).
Throws `ArgumentError` if `T` did not come from `@bake_dd`.
"""
function bake_manifest(T::Type)
    mod = parentmodule(Base.unwrap_unionall(T))
    isdefined(mod, :__IFEDD_BAKE_PROVENANCE__) ||
        throw(ArgumentError("type $(T) was not produced by IFEdd.@bake_dd"))
    return getfield(mod, :__IFEDD_BAKE_PROVENANCE__).manifest
end

"""
    IFEdd.bake_source(T::Type) -> @NamedTuple{idstypes, dd, manifest}

Filesystem paths of the three generator outputs that back a
[`@bake_dd`](@ref) type. Files persist for the session (ephemeral
bakes drop them in a tempdir; persistent bakes leave them in
`output_dir`).
"""
function bake_source(T::Type)
    mod = parentmodule(Base.unwrap_unionall(T))
    isdefined(mod, :__IFEDD_BAKE_PROVENANCE__) ||
        throw(ArgumentError("type $(T) was not produced by IFEdd.@bake_dd"))
    p = getfield(mod, :__IFEDD_BAKE_PROVENANCE__)
    return (idstypes = p.idstypes_file,
            dd       = p.dd_file,
            manifest = p.manifest_file)
end
