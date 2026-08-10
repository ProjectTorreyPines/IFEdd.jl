#!/usr/bin/env julia
"""
    IFEdd/scripts/generate.jl

Generate Julia struct code for IFEdd's IDS schemas from
`data_dictionary/data_structures_extra/*.json` into:

- `src/dd_idstypes.jl` — leaf IDS structs.
- `src/dd.jl` — top-level container `dd{T} <: IMASdd.DD{T}` + `__init__()`
  that merges `_all_info` entries into `IMASdd._all_info`.

`LOCAL_IDS` lists IFE-owned IDS (defined locally; their JSON files override
IMASdd's same-name files in the workdir). `EXTRA_IDS` lists IMASdd IDS to
embed as `::IMASdd.X{T}` (reused, not regenerated). The container name `dd`
matches IMASdd; disambiguation happens at call sites since `IFEdd` does
not export it (always `IFEdd.dd(...)`).

Run: `julia scripts/generate.jl`.
"""

using IMASdd
using IFEdd: path_to_struct_name, classify_parent
using JSON
using GenerateDD: imas_dd_ids_names, imas_dd_ids, imas_julia_struct

const IMASDD_ROOT = pkgdir(IMASdd)
const IMASDD_DD = joinpath(IMASDD_ROOT, "data_dictionary")

const IFEDD_ROOT = normpath(joinpath(@__DIR__, ".."))
const IFEDD_DD = joinpath(IFEDD_ROOT, "data_dictionary")
const OUT_LEAVES = joinpath(IFEDD_ROOT, "src", "dd_idstypes.jl")
const OUT_CONTAINER = joinpath(IFEDD_ROOT, "src", "dd.jl")

# IFE-owned IDS, defined locally by IFEdd. Their JSON files in
# `data_dictionary/data_structures_extra/` override any same-name file in
# IMASdd (`setup_workdir` enforces single-source so MFE fields don't leak).
const LOCAL_IDS = String["summary", "build", "driver"]

# IMASdd IDS embedded as `::IMASdd.X{T}` (reused, not regenerated). Their
# struct defs are stripped from generator output and their `_all_info`
# entries are skipped (IMASdd already registers them).
const EXTRA_IDS = String[
    "pellets",
    "core_profiles",
    "core_sources",
    "blanket",
    "neutronics",
    "balance_of_plant",
    "costing",
    "requirements",
]

const TOP_NAME = "dd"

@info "Paths" IMASDD_DD IFEDD_DD OUT_LEAVES OUT_CONTAINER

"""
Read ALL `_supertype` markers from IFEdd's three local
schemas, walking every path (not just top-level). Returns
`(overrides::Dict, parents::Dict)`:

- `overrides[struct_name] = abstract_name` — what to substitute to.
- `parents[struct_name]   = qualified_parent_str` — what the
  GenerateDD-emitted struct currently has on the right of `<:`, so
  `apply_supertype_overrides` can build a precise regex.

The two dicts are returned together so the override pass can match
against the exact qualified parent string (`"IMASdd.IDStop{T}"`,
`"IMASdd.IDS{T}"`, or `"IMASdd.IDSvectorStaticElement{T}"`) and raise
`GeneratorError(:override_missed, …)` if any planned substitution
fails to fire.
"""
function read_all_supertypes()
    extras_dir = joinpath(IFEDD_DD, "data_structures_extra")
    overrides = Dict{String,String}()
    parents   = Dict{String,String}()
    for filename in sort(readdir(extras_dir))
        endswith(filename, ".json") || continue
        raw = JSON.parsefile(joinpath(extras_dir, filename))
        for (path, entry) in raw
            entry isa AbstractDict || continue
            haskey(entry, "_supertype") || continue
            struct_name = path_to_struct_name(path)
            overrides[struct_name] = String(entry["_supertype"])
            parents[struct_name]   = classify_parent(path, entry) * "{T}"
        end
    end
    return overrides, parents
end

"""
Rewrite every `mutable struct <name>{T} <: <parent>{T}`
to `<: <abstract>{T}` per the override map. Uses `\\b` anchors so that
`build__layer` does NOT partial-match `build__layer___outline`.

Invariant (pinned): this pass MUST run AFTER `postprocess`, because
it matches against the QUALIFIED parent strings (`IMASdd.IDStop{T}`,
`IMASdd.IDS{T}`, `IMASdd.IDSvectorStaticElement{T}`).

Raises `IFEdd.GeneratorError(:override_missed, …)` if any planned
substitution failed (signal that the schema and emitted code drifted
out of sync, or `path_to_struct_name`/`classify_parent` mis-derived).
"""
function apply_supertype_overrides(content::String,
                                    overrides::Dict{String,String},
                                    parents::Dict{String,String})
    missed = String[]
    for (struct_name, abs_name) in overrides
        parent_qualified = get(parents, struct_name, "IMASdd.IDS{T}")
        escaped_parent = replace(parent_qualified, "{" => "\\{", "}" => "\\}")
        # `\Q…\E` literalizes struct_name; `\{T\}` literal after struct
        # name already disambiguates `build__layer` from
        # `build__layer___outline` (which would have `_` after the name,
        # not `{`). No trailing `\b` needed — would fail at line-end
        # since both `}` and `\n` are non-word characters.
        pattern = Regex("(mutable struct \\Q$(struct_name)\\E\\{T\\}\\s*<:\\s*)" *
                        escaped_parent)
        replacement = SubstitutionString("\\1$(abs_name){T}")
        new_content = replace(content, pattern => replacement)
        if new_content == content
            push!(missed, "$(struct_name) <: $(parent_qualified) → $(abs_name)")
        end
        content = new_content
    end
    if !isempty(missed)
        throw(IFEdd.GeneratorError(:override_missed,
            "apply_supertype_overrides found no match for:\n  " *
            join(missed, "\n  ") *
            "\n(Schema markers and emitted code may have drifted; or " *
            "path_to_struct_name / classify_parent mis-derived.)"))
    end
    return content
end

function setup_workdir()
    workdir = mktempdir(prefix="ifedd_gen_")
    @info "Created temp workdir" workdir

    # Names that IFEdd defines locally. GenerateDD merges all matching
    # `<name>.json` from `data_structures` + `data_structures_extra`, so for
    # these we must keep ONLY IFEdd's file (else MFE fields leak into the IFE
    # schema). Excludes them from IMASdd's data_structures symlink set.
    ifedd_extras_dir = joinpath(IFEDD_DD, "data_structures_extra")
    ifedd_local_names = Set{String}(
        replace(f, ".json" => "") for f in readdir(ifedd_extras_dir) if endswith(f, ".json")
    )

    # data_structures: file-level symlinks, skipping IFEdd-overridden names
    ds_dst = joinpath(workdir, "data_structures")
    mkdir(ds_dst)
    imasdd_ds = joinpath(IMASDD_DD, "data_structures")
    for f in readdir(imasdd_ds)
        name = endswith(f, ".json") ? replace(f, ".json" => "") : ""
        endswith(f, ".json") && name in ifedd_local_names && continue
        symlink(joinpath(imasdd_ds, f), joinpath(ds_dst, f))
    end

    symlink(joinpath(IMASDD_DD, "cocos_signals.jl"),
            joinpath(workdir, "cocos_signals.jl"))

    # data_structures_extra: IMASdd's first, then IFEdd's (overrides by name)
    extra_dst = joinpath(workdir, "data_structures_extra")
    mkdir(extra_dst)
    imasdd_extra = joinpath(IMASDD_DD, "data_structures_extra")
    if isdir(imasdd_extra)
        for f in readdir(imasdd_extra)
            endswith(f, ".json") || continue
            symlink(joinpath(imasdd_extra, f), joinpath(extra_dst, f))
        end
    end
    for f in readdir(ifedd_extras_dir)
        endswith(f, ".json") || continue
        dst = joinpath(extra_dst, f)
        (isfile(dst) || islink(dst)) && rm(dst)
        symlink(joinpath(ifedd_extras_dir, f), dst)
    end

    return workdir
end

function collect_target_fields(workdir::String)
    all_ids = imas_dd_ids_names(workdir; extras=true)
    selected = String[]
    for name in all_ids
        if name in LOCAL_IDS || name in EXTRA_IDS
            push!(selected, name)
        end
    end
    @info "IDS filter" total=length(all_ids) selected=selected

    desired = String[]
    for name in selected
        append!(desired, keys(imas_dd_ids(workdir, name)))
    end
    @info "Collected fields" count=length(desired)
    return desired
end

function generate_raw(workdir::String, desired::Vector{String})
    cd(workdir)
    cmds = imas_julia_struct(workdir, desired)
    return join(cmds, "\n")
end

"""
Qualify IMASdd identifiers (`IDS`, `Info`, `IDSvector`, `ThreadSafeDicts`) and
turn the `const _all_info = Dict(...)` block into an `__init__()` that
`merge!`s entries into `IMASdd._all_info`. GenerateDD assumes its output
lives inside IMASdd; this rewrites it for an external module.
"""
function postprocess(content::String)
    abstract_types = [
        "FilledFields", "IDS", "DD", "IDStop", "IDSraw",
        "IDSvectorElement", "IDSvectorRawElement", "IDSvectorIonElement",
        "IDSvectorStaticElement", "IDSvectorTimeElement",
    ]
    for t in abstract_types
        content = replace(content, Regex("(<:\\s*)$t\\{") => SubstitutionString("\\1IMASdd.$t{"))
        content = replace(content, Regex("(<:\\s*)$t\\b(?!\\.)") => SubstitutionString("\\1IMASdd.$t"))
    end
    content = replace(content, r"(::|\b)IDSvector\{" => s"\1IMASdd.IDSvector{")
    content = replace(content, r"\bThreadSafeDicts\." => "IMASdd.ThreadSafeDicts.")
    content = replace(content, r"(?<![A-Za-z_\.])Info\(" => "IMASdd.Info(")

    open_marker = "const _all_info = Dict{Tuple{<:Type,Symbol},Info}("
    replaced_open = "function __init__()\n    merge!(IMASdd._all_info, Dict("
    if occursin(open_marker, content)
        content = replace(content, open_marker => replaced_open)
        rstripped = rstrip(content)
        if endswith(rstripped, ")")
            content = rstripped[1:prevind(rstripped, lastindex(rstripped))] *
                      "))\n    return nothing\nend\n"
        else
            @warn "Output does not end with ')' — check _all_info closing manually"
        end
    else
        @warn "`const _all_info = Dict{...}(` marker not found — IMASdd/GenerateDD output format may have changed"
    end

    return content
end

"""Remove struct/FilledFields/constructor blocks for any IDS rooted in `extra_ids`."""
function strip_extra_ids_structs(content::String, extra_ids::Vector{String})
    isempty(extra_ids) && return content

    function matches_extra(name::AbstractString)
        # Strip `FilledFields____` prefix
        n = startswith(name, "FilledFields____") ? name[length("FilledFields____")+1:end] : name
        # Match the IDS root before any `__` suffix
        root = first(split(n, "__"))
        return root in extra_ids
    end

    lines = split(content, '\n')
    out = String[]
    skipping = false
    for line in lines
        if skipping
            # Top-level `end` (at column 0) marks the block end
            if line == "end"
                skipping = false
            end
            continue
        end
        # Long-form: `mutable struct X{...}` or `function X{T}(...) where {...}`
        m = match(r"^(mutable struct|function)\s+([A-Za-z_][A-Za-z_0-9]*)", line)
        if m !== nothing && matches_extra(m[2])
            skipping = true
            continue
        end
        # Short-form constructor: `X(; ...) = X{Float64}(; ...)`
        # GenerateDD emits these as one-liners alongside the parametric version.
        m = match(r"^([A-Za-z_][A-Za-z_0-9]*)\([^)]*\)\s*=", line)
        if m !== nothing && matches_extra(m[1])
            continue
        end
        push!(out, line)
    end
    return join(out, '\n')
end

"""Qualify `extra_ids` references in the container to `IMASdd.<name>{T}`."""
function qualify_extra_ids_in_container(content::String, extra_ids::Vector{String})
    for name in extra_ids
        # Field type: `::name{`
        content = replace(content, Regex("::\\Q$(name)\\E\\{") => "::IMASdd.$(name){")
        # Constructor call: `name{T}(`
        content = replace(content, Regex("(?<![A-Za-z_\\.])\\Q$(name)\\E\\{T\\}\\(") =>
                                   "IMASdd.$(name){T}(")
    end
    return content
end

"""Drop `_all_info` entries keyed on `extra_ids` types (IMASdd already registers them)."""
function filter_all_info_entries(content::String, extra_ids::Vector{String})
    isempty(extra_ids) && return content
    lines = split(content, '\n')
    out = String[]
    for line in lines
        m = match(r"^\s*\(([A-Za-z_][A-Za-z_0-9]*)\s*,", line)
        if m !== nothing
            base = m[1]
            n = startswith(base, "FilledFields____") ? base[length("FilledFields____")+1:end] : base
            root = first(split(n, "__"))
            if root in extra_ids
                continue
            end
        end
        push!(out, line)
    end
    return join(out, '\n')
end

"""
Split the post-processed content into:
- `leaves`: everything up to the container's FilledFields (leaf IDS types).
- `container`: the container's FilledFields, struct, constructor, and
  `__init__()` (which holds all `_all_info` entries — both leaf and container).

Splits at the first occurrence of `mutable struct FilledFields____<TOP_NAME>`,
which GenerateDD always emits just before the top-level struct.
"""
function split_content(content::String)
    marker = "mutable struct FilledFields____$(TOP_NAME)"
    idx = findfirst(marker, content)
    idx === nothing && error("Split marker not found: $marker")
    boundary = first(idx)
    leaves = rstrip(content[1:prevind(content, boundary)])
    container = content[boundary:end]
    return leaves, container
end

function main()
    workdir = setup_workdir()
    try
        desired = collect_target_fields(workdir)
        raw = generate_raw(workdir, desired)
        @info "Raw generation done" chars=length(raw)

        cooked = postprocess(raw)

        if !isempty(EXTRA_IDS)
            cooked = strip_extra_ids_structs(cooked, EXTRA_IDS)
            cooked = qualify_extra_ids_in_container(cooked, EXTRA_IDS)
            cooked = filter_all_info_entries(cooked, EXTRA_IDS)
        end

        overrides, parents = read_all_supertypes()
        # The container has no JSON schema, so its abstract cannot come from a
        # `_supertype` marker; declare it here and let the same count-asserted
        # rewrite apply it.
        overrides["dd"] = "AbstractIFEDD"
        parents["dd"] = "IMASdd.DD{T}"
        @info "Supertype overrides (all depths)" n=length(overrides) overrides=overrides
        cooked = apply_supertype_overrides(cooked, overrides, parents)

        leaves, container = split_content(cooked)

        auto_gen_banner = """
        # AUTO-GENERATED by scripts/generate.jl — DO NOT EDIT.
        # Re-run: `julia scripts/generate.jl`
        """

        open(OUT_LEAVES, "w") do io
            write(io, auto_gen_banner, "\n", leaves, "\n")
        end
        open(OUT_CONTAINER, "w") do io
            write(io, auto_gen_banner, "\n", container)
        end
        @info "Wrote outputs" OUT_LEAVES OUT_CONTAINER leaves_bytes=filesize(OUT_LEAVES) container_bytes=filesize(OUT_CONTAINER)
    finally
        rm(workdir; recursive=true, force=true)
        @info "Cleaned up workdir"
    end
    return nothing
end

main()
