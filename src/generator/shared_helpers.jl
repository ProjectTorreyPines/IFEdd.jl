# Shared helpers for `IFEdd.generate_user_dd`.
#
# `generate_user_dd` wraps `GenerateDD` instead of running a parallel emission
# pipeline, so this file carries only the edge utilities: atomic write, pidlock,
# hashing, the error type, and small introspection wrappers. Field-path
# flattening and `Info(...)` emission are not needed —
# `GenerateDD.imas_julia_struct` already emits the right shape, and
# `_supertype` is post-substituted the same way `scripts/generate.jl` does it.
#
# Tests in `test/test_shared_helpers.jl`.

"""
    GeneratorError <: Exception

Raised by `IFEdd.generate_user_dd` and its helpers for any of the
documented `reason::Symbol`s. The `detail` field carries reason-specific context for the
`Base.showerror` rendering.
"""
struct GeneratorError <: Exception
    reason::Symbol
    detail::Any
end

function Base.showerror(io::IO, e::GeneratorError)
    print(io, "IFEdd.GeneratorError(:", e.reason, ")")
    if e.detail !== nothing && e.detail != ""
        print(io, " — ", e.detail)
    end
end

"""
    atomic_write(path::AbstractString, content::AbstractString)

Write `content` to `path` atomically: writes to a sibling temp file then
`mv(...; force=true)` into place. Always emits LF line endings (any CRLF in
`content` is normalized to LF first). Cross-platform `mv` semantics on
Windows are not covered by CI.
"""
function atomic_write(path::AbstractString, content::AbstractString)
    normalized = replace(content, "\r\n" => "\n")
    dir = dirname(path)
    isdir(dir) || mkpath(dir)
    tmp = tempname(dir; cleanup=false)
    try
        open(tmp, "w") do io
            write(io, normalized)
        end
        mv(tmp, path; force=true)
    catch
        isfile(tmp) && rm(tmp; force=true)
        rethrow()
    end
    return nothing
end

"""
    with_generator_lock(f, output_dir::AbstractString; stale_age::Int=600, wait_timeout::Int=60)

Acquire `joinpath(output_dir, ".ifedd_gen.lock")` (FileWatching.mkpidlock)
and run `f()` while holding it. Releases on success or exception.
Raises `GeneratorError(:pidlock_timeout, output_dir)` if the lock cannot be
obtained within `wait_timeout` seconds.

`output_dir` is created if missing (the lock file lives next to the
generator's outputs).
"""
function with_generator_lock(f, output_dir::AbstractString;
                             stale_age::Integer=600,
                             wait_timeout::Integer=60)
    isdir(output_dir) || mkpath(output_dir)
    lock_path = joinpath(output_dir, ".ifedd_gen.lock")
    pl = false
    deadline = time() + wait_timeout
    while pl === false && time() < deadline
        pl = FileWatching.trymkpidlock(lock_path; stale_age=stale_age)
        pl === false && sleep(0.1)
    end
    if pl === false
        throw(GeneratorError(:pidlock_timeout, output_dir))
    end
    try
        return f()
    finally
        close(pl)
    end
end

"""
    hash_file(path::AbstractString) -> String

SHA-256 hex digest of file contents.
"""
function hash_file(path::AbstractString)
    return bytes2hex(open(SHA.sha256, path))
end

"""
    canonicalize_json(x) -> Any

Recursively convert nested `AbstractDict`s into sorted-key `Dict`s with
deterministic iteration order. Arrays / scalars pass through unchanged.
Used by `hash_canonical_json`.
"""
function canonicalize_json(x)
    if x isa AbstractDict
        # OrderedDict so iteration order is exactly the sorted order.
        # Used for `JSON.print`-stable output on a JSON.jl version without
        # `sort_keys` kwarg.
        pairs = sort!(Pair{String,Any}[string(k) => canonicalize_json(v) for (k, v) in x];
                      by=first)
        return OrderedCollections.OrderedDict{String,Any}(pairs)
    elseif x isa AbstractVector
        return Any[canonicalize_json(v) for v in x]
    else
        return x
    end
end

"""
    hash_canonical_json(d) -> String

SHA-256 hex digest of `d` serialized as canonical JSON (recursively
sorted keys). Stable across calls regardless of insertion order — used
for manifest determinism.
"""
function hash_canonical_json(d)
    # `canonicalize_json` produces a `Dict{String,Any}` whose iteration
    # order is sorted (we sorted the keys explicitly when building it),
    # so plain `JSON.print` emits a stable serialization. JSON 0.21 does
    # not support a `sort_keys` keyword, so do the sorting up front.
    c = canonicalize_json(d)
    io = IOBuffer()
    JSON.print(io, c)
    return bytes2hex(SHA.sha256(take!(io)))
end

"""
    key_owner(k) -> Module

For a `(Type, Symbol)` key from `IMASdd._all_info`, returns the module
that owns the type. Handles `UnionAll` keys via `Base.unwrap_unionall`.
"""
function key_owner(k)
    T = k[1]
    return T isa UnionAll ? parentmodule(Base.unwrap_unionall(T)) :
                            parentmodule(T)
end

"""
    info_field_names() -> NTuple

Wrapper around `fieldnames(IMASdd.Info)` so callers (tests and the
generator) share a single source-of-truth for the positional-arg count
that the emitted `IMASdd.Info(...)` calls must satisfy. Pre-flight 3.3
recorded 6 fields:
`(:coordinates, :units, :data_type, :documentation, :extra, :cocos_transform)`.
"""
info_field_names() = fieldnames(IMASdd.Info)

"""
    housekeeping_field_set(::Type) -> Set{Symbol}

Returns the trailing "housekeeping" fields IMASdd / IFEdd attach to every
generated struct: `_aux, _name, _filled, _frozen, _threads_lock,
_in_expression, _parent` (and historically variants). Computed by
introspecting `fieldnames(T)` for fields whose name starts with `_`.

User concretes baked by `generate_user_dd` MUST carry this same set in
the same order.
"""
function housekeeping_field_set(::Type{T}) where T
    return Set{Symbol}(name for name in fieldnames(T) if startswith(string(name), "_"))
end

"""
    housekeeping_field_order(::Type) -> Vector{Symbol}

Same set as `housekeeping_field_set` but order-preserving (returns the
fields in `fieldnames(T)` order). The generator uses this order when
emitting user concretes so positional constructors line up.
"""
function housekeeping_field_order(::Type{T}) where T
    return Symbol[name for name in fieldnames(T) if startswith(string(name), "_")]
end

"""
    read_supertypes_from_schemas(dir::AbstractString, names) -> Dict{String,String}

Read each `<name>.json` file under `dir` and extract the `_supertype`
marker from the top-level entry whose key matches the file's basename.
Mirrors `scripts/generate.jl`'s `read_local_supertypes`. Skips files
without the marker; raises `GeneratorError(:malformed_json, path)` on
parse error.
"""
function read_supertypes_from_schemas(dir::AbstractString, names)
    out = Dict{String,String}()
    isdir(dir) || throw(GeneratorError(:schema_dir_missing, dir))
    for name in names
        path = joinpath(dir, "$name.json")
        isfile(path) || continue
        raw = try
            JSON.parsefile(path)
        catch e
            throw(GeneratorError(:malformed_json, (path=path, error=e)))
        end
        haskey(raw, name) || continue
        root = raw[name]
        root isa AbstractDict || continue
        haskey(root, "_supertype") || continue
        out[name] = String(root["_supertype"])
    end
    return out
end

# ============================================================================
# Lattice derivation helpers
# ----------------------------------------------------------------------------
# Used by `scripts/derive_abstracts.jl`, which produces `abstracts.json`, and by
# `scripts/generate.jl::apply_supertype_overrides`, which applies the markers at
# every depth. Note that `classify_parent` dispatches on `data_type`, not on
# path syntax.
# ============================================================================

"""
    path_to_struct_name(path::AbstractString) -> String

Map an IMAS DD path (e.g. `"build.layer[:].outline"`) to the struct
name GenerateDD emits (e.g. `"build__layer___outline"`). One-liner
mirroring GenerateDD's emission rule: dots → `__`, `[:]` → `_`,
trailing `_`s stripped.
"""
function path_to_struct_name(path::AbstractString)::String
    s = replace(path, "." => "__")
    s = replace(s, "[:]" => "_")
    s = replace(s, r"_+$" => "")
    return s
end

"""
    classify_parent(path::AbstractString, entry::AbstractDict) -> String

Returns the unqualified IMASdd parent class for a struct emitted at
`path`. Three branches:

- `STRUCT_ARRAY` `data_type` → `"IMASdd.IDSvectorStaticElement"` (the
  element type's parent). Detection must consult `data_type`, not a
  path-suffix `[:]` — IMAS schemas use `[:]` as a segment connector,
  not a terminal.
- nested STRUCTURE (path contains `.`) → `"IMASdd.IDS"`.
- top-level STRUCTURE (no dot in path) → `"IMASdd.IDStop"`.

GGD / ion / time-dependent variants (`IDSvectorRawElement`,
`IDSvectorIonElement`, `IDSvectorTimeElement`, `IDSraw`) are not
needed by IFEdd's three schemas; if they ever are, this function
will need extending.
"""
function classify_parent(path::AbstractString, entry::AbstractDict)::String
    get(entry, "data_type", "STRUCTURE") == "STRUCT_ARRAY" &&
        return "IMASdd.IDSvectorStaticElement"
    occursin(".", path) && return "IMASdd.IDS"
    return "IMASdd.IDStop"
end

"""
    validate_marker_placement(path, entry)

Confirms `_supertype` was placed on a STRUCTURE or STRUCT_ARRAY node,
not on a leaf scalar or on the `time` root. Raises
`GeneratorError(:bad_marker_placement, …)` otherwise.
"""
function validate_marker_placement(path::AbstractString, entry::AbstractDict)
    dt = get(entry, "data_type", "STRUCTURE")
    if dt ∉ ("STRUCTURE", "STRUCT_ARRAY")
        throw(GeneratorError(:bad_marker_placement,
            "_supertype on `$path` whose data_type is `$dt` (markers only valid on STRUCTURE / STRUCT_ARRAY)"))
    end
    endswith(path, ".time") &&
        throw(GeneratorError(:bad_marker_placement,
            "_supertype on `$path` — `time` is a leaf time-base, not a structure"))
    return nothing
end

"""
    validate_abstract_naming(abs_name)

Confirms an abstract type name is a valid Julia identifier. Warns
(does not error) if the name does not start with `AbstractIFE` —
that prefix is the IFEdd convention; downstream packages may use
their own prefix.
"""
function validate_abstract_naming(abs_name::AbstractString)
    isempty(abs_name) && throw(GeneratorError(:bad_marker_value,
        "abstract type name is empty"))
    is_valid_id = (isletter(first(abs_name)) || first(abs_name) == '_') &&
                  all(c -> isletter(c) || isdigit(c) || c == '_', abs_name)
    is_valid_id || throw(GeneratorError(:bad_marker_value,
        "abstract type name `$abs_name` is not a valid Julia identifier"))
    if !startswith(abs_name, "AbstractIFE")
        @warn "Abstract name `$abs_name` does not start with `AbstractIFE` — IFEdd convention is the AbstractIFE* prefix"
    end
    return nothing
end

"""
    derive_abstracts(schemas_dir::AbstractString) ->
        @NamedTuple{abstracts::OrderedDict, default_concretes::OrderedDict}

Walks every `.json` in `schemas_dir` (alpha-sorted), reads each
`_supertype` marker, validates placement + naming, computes the
parent class via `classify_parent`, and returns the lattice as two
alpha-sorted OrderedDicts. Used by `scripts/derive_abstracts.jl` and
by `IFEdd.generate_user_dd` (for the user-side walker).

Raises any of: `:malformed_json`, `:bad_marker_placement`,
`:bad_marker_value`, `:conflicting_marker`, `:parent_mismatch`,
`:duplicate_default`, `:schema_dir_missing`.
"""
function derive_abstracts(schemas_dir::AbstractString)
    isdir(schemas_dir) || throw(GeneratorError(:schema_dir_missing, schemas_dir))

    # path → (abstract_name, entry, source_filename)
    markers = OrderedCollections.OrderedDict{String,Tuple{String,Any,String}}()
    for fn in sort(readdir(schemas_dir))
        endswith(fn, ".json") || continue
        full = joinpath(schemas_dir, fn)
        raw = try
            JSON.parsefile(full)
        catch e
            throw(GeneratorError(:malformed_json, (path=full, error=e)))
        end
        for (path, entry) in raw
            entry isa AbstractDict || continue
            haskey(entry, "_supertype") || continue
            validate_marker_placement(path, entry)
            abs_name = String(entry["_supertype"])
            if haskey(markers, path) && markers[path][1] != abs_name
                prev = markers[path]
                throw(GeneratorError(:conflicting_marker,
                    "Path `$path` declared with `$(prev[1])` in `$(prev[3])` " *
                    "and `$abs_name` in `$fn`"))
            end
            markers[path] = (abs_name, entry, fn)
        end
    end

    abstracts         = OrderedCollections.OrderedDict{String,Any}()
    # default_concretes is nested — abs_name → parent_path → concrete.
    # For single-default (non-shared)
    # abstracts, the inner dict has exactly one entry; for shared abstracts
    # abstracts, the inner dict has multiple entries — one per host path.
    default_concretes = OrderedCollections.OrderedDict{String,OrderedCollections.OrderedDict{String,String}}()
    for path in sort(collect(keys(markers)))
        (abs_name, entry, _) = markers[path]
        validate_abstract_naming(abs_name)
        parent_str = classify_parent(path, entry) * "{T}"
        struct_name = path_to_struct_name(path)
        # parent_kind consistency invariant — all hosts of a
        # shared abstract must produce the same parent_kind.
        if haskey(abstracts, abs_name) && abstracts[abs_name]["parent"] != parent_str
            throw(GeneratorError(:parent_mismatch,
                "Abstract `$abs_name` has conflicting parents across paths " *
                "(was `$(abstracts[abs_name]["parent"])`, now `$parent_str` at `$path`)"))
        end
        abstracts[abs_name] = OrderedCollections.OrderedDict{String,Any}(
            "param" => ["T"],
            "parent" => parent_str,
        )
        # Derive parent_path: first `__`-segment of the struct name (the IDS
        # root). For top-level IDSs (no `__`), the whole name. Documented
        # convention.
        parent_path = first(split(struct_name, "__"))
        inner = get!(default_concretes, abs_name,
                     OrderedCollections.OrderedDict{String,String}())
        if haskey(inner, parent_path) && inner[parent_path] != struct_name
            throw(GeneratorError(:duplicate_default,
                "Abstract `$abs_name` at parent_path `$parent_path` has two " *
                "candidate default concretes: `$(inner[parent_path])` and `$struct_name`"))
        end
        inner[parent_path] = struct_name
    end

    # Sort outputs alphabetically for byte-stable diffs (independent of
    # schema file traversal order). Re-build sorted OrderedDicts.
    abstracts_sorted = OrderedCollections.OrderedDict{String,Any}(
        k => abstracts[k] for k in sort(collect(keys(abstracts))))
    # Sort inner dicts too — parent_path keys alphabetically.
    defaults_sorted = OrderedCollections.OrderedDict{String,OrderedCollections.OrderedDict{String,String}}()
    for k in sort(collect(keys(default_concretes)))
        inner = default_concretes[k]
        sorted_inner = OrderedCollections.OrderedDict{String,String}(
            p => inner[p] for p in sort(collect(keys(inner))))
        defaults_sorted[k] = sorted_inner
    end

    return (abstracts=abstracts_sorted, default_concretes=defaults_sorted)
end

# ============================================================================
# Accessors for the nested `default_concretes` layout
# ============================================================================

"""
    default_concrete(abstracts_blob, abs_name) -> String

Single-default lookup. Returns the unique default concrete for `abs_name`.
Raises `:shared_abstract_needs_path` if the abstract has > 1 default
(forces the caller to use the path-qualified form).

Used by code paths that assume a single default
per abstract.
"""
function default_concrete(abstracts_blob::AbstractDict,
                          abs_name::AbstractString)::String
    inner = abstracts_blob["default_concretes"][abs_name]
    length(inner) == 1 && return only(values(inner))
    throw(GeneratorError(:shared_abstract_needs_path,
        "abstract `$abs_name` has $(length(inner)) default concretes " *
        "across paths $(sort!(collect(string.(keys(inner))))); call with parent_path."))
end

"""
    default_concrete(abstracts_blob, abs_name, parent_path) -> String

Path-qualified lookup. Returns the default concrete for
`(abs_name, parent_path)`. Raises `:shared_abstract_path_not_found`
if `parent_path` is not a known host of `abs_name`.
"""
function default_concrete(abstracts_blob::AbstractDict,
                          abs_name::AbstractString,
                          parent_path::AbstractString)::String
    inner = abstracts_blob["default_concretes"][abs_name]
    haskey(inner, parent_path) && return inner[parent_path]
    throw(GeneratorError(:shared_abstract_path_not_found,
        "abstract `$abs_name` is not declared at path `$parent_path`; " *
        "available paths: $(sort!(collect(string.(keys(inner)))))"))
end

"""
    default_paths(abstracts_blob, abs_name) -> Vector{String}

Sorted parent_paths for an abstract.
"""
function default_paths(abstracts_blob::AbstractDict,
                       abs_name::AbstractString)::Vector{String}
    return sort!(collect(string.(keys(abstracts_blob["default_concretes"][abs_name]))))
end

"""
    _promote_schema_2_to_3(blob) -> AbstractDict

Read a schema-2 abstracts.json (flat `default_concretes :: Dict{str,str}`)
and produce an in-memory nested view. The parent_path
is inferred from the default concrete's first `__`-segment per design
is the abstract's own default concrete name. Used to read older lockfiles;
the on-disk file always comes from `derive_abstracts`.
"""
function _promote_schema_2_to_3(blob::AbstractDict)
    out = Dict{String,Any}(blob)
    raw_defaults = blob["default_concretes"]
    promoted = OrderedCollections.OrderedDict{String,OrderedCollections.OrderedDict{String,String}}()
    for (abs_name, val) in raw_defaults
        # Already nested (schema 3) → pass through; otherwise wrap.
        if val isa AbstractDict
            promoted[abs_name] = OrderedCollections.OrderedDict{String,String}(
                String(k) => String(v) for (k, v) in val)
        else
            concrete = String(val)
            parent_path = first(split(concrete, "__"))
            promoted[abs_name] = OrderedCollections.OrderedDict{String,String}(
                parent_path => concrete)
        end
    end
    out["default_concretes"] = promoted
    out["version"] = "3.0.0"
    return out
end

"""
    format_abstracts_json(abstracts, default_concretes) -> String

Custom serializer that pins line shape so byte-equality holds across
Julia / `JSON.jl` versions. Keys are emitted in the iteration order
of the input dicts (caller must pre-sort).
"""
function format_abstracts_json(abstracts::AbstractDict, default_concretes::AbstractDict)::String
    io = IOBuffer()
    println(io, "{")
    println(io, "  \"_derived_from\": \"scripts/derive_abstracts.jl\",")
    println(io, "  \"version\": \"3.0.0\",")
    println(io, "  \"abstracts\": {")
    abs_keys = collect(keys(abstracts))
    for (i, k) in enumerate(abs_keys)
        e = abstracts[k]
        comma = i < length(abs_keys) ? "," : ""
        println(io, "    \"$k\": { \"param\": [\"T\"], \"parent\": \"$(e["parent"])\" }$comma")
    end
    println(io, "  },")
    # default_concretes is nested — abs_name → parent_path
    # → concrete. Single-default abstracts emit a one-line inner dict; shared
    # abstracts emit a multi-line inner dict.
    println(io, "  \"default_concretes\": {")
    def_keys = collect(keys(default_concretes))
    for (i, k) in enumerate(def_keys)
        inner = default_concretes[k]
        comma_outer = i < length(def_keys) ? "," : ""
        inner_keys = sort(collect(string.(keys(inner))))
        if length(inner_keys) == 1
            ik = only(inner_keys)
            println(io, "    \"$k\": { \"$ik\": \"$(inner[ik])\" }$comma_outer")
        else
            println(io, "    \"$k\": {")
            for (j, ik) in enumerate(inner_keys)
                comma_inner = j < length(inner_keys) ? "," : ""
                println(io, "      \"$ik\": \"$(inner[ik])\"$comma_inner")
            end
            println(io, "    }$comma_outer")
        end
    end
    println(io, "  }")
    println(io, "}")
    return String(take!(io))
end
