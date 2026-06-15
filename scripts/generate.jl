#!/usr/bin/env julia
"""
    IFEdd/scripts/generate.jl

Generate Julia struct code for IFEdd's IDS schemas from
`data_dictionary/data_structures_extra/*.json`.

Output is split across two files for navigability:
- `src/dd_idstypes.jl` — leaf IDS structs (`ife_summary`, `ife_build`,
  `ife_driver` and all their nested sub-IDS), their FilledFields structs,
  and constructors.
- `src/dd.jl` — the top-level container struct `dd{T} <: IMASdd.DD{T}`,
  its FilledFields and constructor, and a single `__init__()` that merges
  every `_all_info` entry (leaves and container alike) into `IMASdd._all_info`.

Design highlights:
- **Reuse IMASdd's installed files** via `pkgdir(IMASdd)` instead of copying
  `cocos_signals.jl` or `data_structures/` into IFEdd. Works for both
  registered installs and dev checkouts.
- **Temp workdir + symlinks**: GenerateDD expects a single DDdir, so we
  virtually merge IMASdd's read-only assets with IFEdd's `data_structures_extra`
  using symlinks under a `mktempdir`. Cleaned up on exit.
- **IDS name filter**: only structs whose IDS name starts with `IDS_PREFIX`
  (default `ife_`) are emitted. See "Mode" notes below for tailoring options.
- **Post-processing**: GenerateDD emits code assuming it lives inside the
  IMASdd module (e.g. `<: IDS{T}`, `Info(...)`, `const _all_info = Dict(...)`).
  We rewrite those references to qualified forms (`<: IMASdd.IDS{T}`,
  `IMASdd.Info(...)`) and wrap the registry block in `__init__()`.
- **Container name `dd`**: GenerateDD emits `dd`; we keep it. Disambiguation
  from `IMASdd.dd` happens at call sites because `IFEdd` does not export `dd`,
  so consumers always write the qualified `IFEdd.dd(...)`.

# Composition modes for `dd`

The user can choose what goes into the top-level `dd` container by editing
the `IDS_PREFIX` and `EXTRA_IDS` constants below.

- **Mode A — Pure IFE (current default)**: `EXTRA_IDS = String[]`.
  `dd` contains only the `ife_*` IDS as fields. Most modular and lightest
  memory footprint. New IDS types are defined locally.

- **Mode B — Tailored subset** (not yet implemented): `EXTRA_IDS = ["amns_data",
  "build", "summary"]` etc. `dd` would also contain the listed IMASdd IDS
  as fields, ideally typed as `::IMASdd.amns_data{T}` (reusing IMASdd's
  concrete types rather than regenerating them). Implementing this requires
  additional post-processing to swap field types and constructor calls; for
  now, leave `EXTRA_IDS` empty.

- **Mode C — Manual**: skip generation of the container entirely and hand-write
  `dd` in `src/dd.jl`. Useful if the container needs custom fields or
  bespoke construction logic. Not exposed by this script today; remove the
  call to `split_and_write` if pursuing this mode.

Run:
    julia scripts/generate.jl
"""

using IMASdd
using GenerateDD: imas_dd_ids_names, imas_dd_ids, imas_julia_struct

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────
const IMASDD_ROOT = pkgdir(IMASdd)
const IMASDD_DD = joinpath(IMASDD_ROOT, "data_dictionary")

const IFEDD_ROOT = normpath(joinpath(@__DIR__, ".."))
const IFEDD_DD = joinpath(IFEDD_ROOT, "data_dictionary")
const OUT_LEAVES = joinpath(IFEDD_ROOT, "src", "dd_idstypes.jl")
const OUT_CONTAINER = joinpath(IFEDD_ROOT, "src", "dd.jl")

# Mode A (Pure IFE): prefix-filter for IDS names to emit as new local types.
const IDS_PREFIX = "ife_"

# Mode B (Tailored subset): IMASdd IDS names listed here are pulled into the
# `dd` container as `::IMASdd.X{T}` (reusing IMASdd's concrete types
# instead of regenerating local copies). Post-processing strips the regenerated
# struct definitions, qualifies the container field/constructor calls, and
# omits these IDS from the local `_all_info` registration (IMASdd already has
# them). Set to `String[]` for Mode A (pure IFE).
const EXTRA_IDS = String[
    "pellets",            # target geometry (init_ife!, ActorIFETransport, ActorCostingIFE)
    "core_profiles",      # plasma profiles (init_ife!, ActorIFETransport)
    "core_sources",       # fusion source terms (init_ife!, ActorIFETransport)
    "blanket",            # TBR + blanket layer results (ActorIFEBlanket)
    "neutronics",         # first_wall + wall_loading (ActorIFEBlanket)
    "balance_of_plant",   # thermal/electric power flow (init_balance_of_plant!, ActorCostingIFE)
    "costing",            # cost structure (ActorCostingIFE)
    "requirements",       # TBR target, plant_lifetime, availability
    "summary",            # standard summary IDS
]

# Container name. GenerateDD emits `dd`; we keep that name so the satellite
# parallels IMASdd, but `IFEdd` does NOT export `dd` — outside callers must
# always write `IFEdd.dd(...)` to disambiguate from `IMASdd.dd`.
const TOP_NAME = "dd"

@info "Paths" IMASDD_DD IFEDD_DD OUT_LEAVES OUT_CONTAINER

# ──────────────────────────────────────────────────────────────────────────────
# Step 1: temp workdir that virtually merges IMASdd + IFEdd files
# ──────────────────────────────────────────────────────────────────────────────
function setup_workdir()
    workdir = mktempdir(prefix="ifedd_gen_")
    @info "Created temp workdir" workdir

    symlink(joinpath(IMASDD_DD, "data_structures"),
            joinpath(workdir, "data_structures"))
    symlink(joinpath(IMASDD_DD, "cocos_signals.jl"),
            joinpath(workdir, "cocos_signals.jl"))

    extra_dst = joinpath(workdir, "data_structures_extra")
    mkdir(extra_dst)
    # IMASdd's own extras (build/blanket/neutronics/balance_of_plant/costing/...) come first
    imasdd_extra = joinpath(IMASDD_DD, "data_structures_extra")
    if isdir(imasdd_extra)
        for f in readdir(imasdd_extra)
            endswith(f, ".json") || continue
            symlink(joinpath(imasdd_extra, f), joinpath(extra_dst, f))
        end
    end
    # IFEdd's IFE-specific extras (ife_*.json) layered on top — wins on name conflict
    extra_src = joinpath(IFEDD_DD, "data_structures_extra")
    for f in readdir(extra_src)
        endswith(f, ".json") || continue
        dst = joinpath(extra_dst, f)
        (isfile(dst) || islink(dst)) && rm(dst)
        symlink(joinpath(extra_src, f), dst)
    end

    return workdir
end

# ──────────────────────────────────────────────────────────────────────────────
# Step 2: collect field paths for selected IDS
# ──────────────────────────────────────────────────────────────────────────────
function collect_target_fields(workdir::String)
    all_ids = imas_dd_ids_names(workdir; extras=true)
    selected = String[]
    for name in all_ids
        if startswith(name, IDS_PREFIX) || name in EXTRA_IDS
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

# ──────────────────────────────────────────────────────────────────────────────
# Step 3: invoke GenerateDD's emitter
# ──────────────────────────────────────────────────────────────────────────────
function generate_raw(workdir::String, desired::Vector{String})
    cd(workdir)
    cmds = imas_julia_struct(workdir, desired)
    return join(cmds, "\n")
end

# ──────────────────────────────────────────────────────────────────────────────
# Step 4: rewrite code for use outside the IMASdd module
# ──────────────────────────────────────────────────────────────────────────────
"""
GenerateDD emits code that assumes it is being spliced into the IMASdd module
itself, so identifiers like `IDS`, `Info`, `_all_info` are unqualified. From
IFEdd we have to qualify them, rename the top-level container, and turn the
`const _all_info = Dict(...)` block into a `__init__` that merges entries into
IMASdd's existing dict.
"""
function postprocess(content::String)
    # 1) Qualify abstract type references with IMASdd.
    abstract_types = [
        "FilledFields", "IDS", "DD", "IDStop", "IDSraw",
        "IDSvectorElement", "IDSvectorRawElement", "IDSvectorIonElement",
        "IDSvectorStaticElement", "IDSvectorTimeElement",
    ]
    for t in abstract_types
        content = replace(content, Regex("(<:\\s*)$t\\{") => SubstitutionString("\\1IMASdd.$t{"))
        content = replace(content, Regex("(<:\\s*)$t\\b(?!\\.)") => SubstitutionString("\\1IMASdd.$t"))
    end

    # 2) Qualify concrete helper types
    content = replace(content, r"(::|\b)IDSvector\{" => s"\1IMASdd.IDSvector{")
    content = replace(content, r"\bThreadSafeDicts\." => "IMASdd.ThreadSafeDicts.")

    # 3) Qualify Info(...) constructor calls
    content = replace(content, r"(?<![A-Za-z_\.])Info\(" => "IMASdd.Info(")

    # 4) Container name `dd` matches GenerateDD's output verbatim — no rename
    #    needed. (`IMASdd.DD` abstract supertype is already qualified above.)

    # 5) Convert `const _all_info = Dict{...}(` and its trailing `)` into
    #    a `__init__()` that `merge!`s into `IMASdd._all_info`.
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

# ──────────────────────────────────────────────────────────────────────────────
# Step 4.5: Mode B subset post-processing
# ──────────────────────────────────────────────────────────────────────────────
"""
    strip_extra_ids_structs(content::String, extra_ids::Vector{String})

Remove `mutable struct`, `FilledFields____`, and constructor `function` blocks
for any IDS whose root name is in `extra_ids`. Block start patterns recognized:
- `mutable struct <ids_root>{T<:Real} <: ...`
- `mutable struct <ids_root>__<...>{T<:Real} <: ...`
- `mutable struct FilledFields____<ids_root>` (with or without `__<...>`)
- `function <ids_root>{T}(...)`
- `function <ids_root>__<...>{T}(...)`

Block end pattern: line that is exactly `end` (column 0). GenerateDD output
keeps all top-level definitions at indent 0, so this is unambiguous.
"""
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

"""
    qualify_extra_ids_in_container(content::String, extra_ids::Vector{String})

Within the `dd` container struct + constructor, rewrite local references
to extra IDS types so they point at IMASdd's concrete types:
- field type:      `field::pellets{T}`        → `field::IMASdd.pellets{T}`
- constructor:     `pellets{T}(; frozen=...)` → `IMASdd.pellets{T}(; frozen=...)`

Applied per `extra_ids` name to avoid accidentally rewriting IFE-owned names.
"""
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

"""
    filter_all_info_entries(content::String, extra_ids::Vector{String})

Remove `_all_info` dictionary entries whose key references any IDS rooted at
an `extra_ids` name (IMASdd already registers these). Entries have the form:
    (<TypeName>, :field) => IMASdd.Info(...),
on a single line within the `__init__()` Dict block.
"""
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

# ──────────────────────────────────────────────────────────────────────────────
# Step 5: split into two files at the container boundary
# ──────────────────────────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
function main()
    workdir = setup_workdir()
    try
        desired = collect_target_fields(workdir)
        raw = generate_raw(workdir, desired)
        @info "Raw generation done" chars=length(raw)

        cooked = postprocess(raw)

        # Mode B: strip extra IDS struct definitions (IMASdd has them), qualify
        # container references to those IDS, and skip their `_all_info` entries.
        if !isempty(EXTRA_IDS)
            @info "Mode B subset post-processing" EXTRA_IDS
            cooked = strip_extra_ids_structs(cooked, EXTRA_IDS)
            cooked = qualify_extra_ids_in_container(cooked, EXTRA_IDS)
            cooked = filter_all_info_entries(cooked, EXTRA_IDS)
        end

        leaves, container = split_content(cooked)

        leaves_header = """
        # ─────────────────────────────────────────────────────────────────────────────
        # AUTO-GENERATED by scripts/generate.jl from data_structures_extra/*.json
        # DO NOT EDIT MANUALLY. Re-run: `julia scripts/generate.jl`
        #
        # Leaf IDS types only. The top-level `$(TOP_NAME)` container lives in
        # dd.jl, which is `include`d after this file by IFEdd.jl.
        # ─────────────────────────────────────────────────────────────────────────────
        """
        container_header = """
        # ─────────────────────────────────────────────────────────────────────────────
        # AUTO-GENERATED by scripts/generate.jl from data_structures_extra/*.json
        # DO NOT EDIT MANUALLY. Re-run: `julia scripts/generate.jl`
        #
        # Top-level `$(TOP_NAME)` container, its FilledFields struct and
        # constructor, plus `__init__()` that registers every `_all_info` entry
        # (leaves and container) into IMASdd's global registry.
        # ─────────────────────────────────────────────────────────────────────────────
        """

        open(OUT_LEAVES, "w") do io
            write(io, leaves_header, "\n", leaves, "\n")
        end
        open(OUT_CONTAINER, "w") do io
            write(io, container_header, "\n", container)
        end
        @info "Wrote outputs" OUT_LEAVES OUT_CONTAINER leaves_bytes=filesize(OUT_LEAVES) container_bytes=filesize(OUT_CONTAINER)
    finally
        rm(workdir; recursive=true, force=true)
        @info "Cleaned up workdir"
    end
    return nothing
end

main()
