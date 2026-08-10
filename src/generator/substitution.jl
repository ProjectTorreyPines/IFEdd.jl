# Sub-IDS substitution helpers.
#
# Builds the substitution graph that drives two passes in `generate_user_dd`:
# the regex rewrite over emitted code, and the parent-schema regeneration that
# recovers a parent IDS whose child slot was substituted.
#
# Counterpart to `_collect_all_user_supertypes` in `generate_user_dd.jl`: that
# one harvests user-declared `_supertype` markers for parallel typing, this one
# turns `slot_bindings` into a substitution map keyed on default-concrete name.
#
# Supports GenerateDD ^1.

"""
    _derived_top_level_slots(abstracts_blob) -> Set{Symbol}

Derive the set of top-level slot names from `abstracts.json`: abstracts
whose `parent` is `IMASdd.IDStop{T}` and that have a `default_concretes`
entry. Returns the concrete names (e.g. `:summary, :build, :driver`).

Used by `_classify_binding_key` to recognize slot-name binding keys.
"""
function _derived_top_level_slots(abstracts_blob::AbstractDict)
    out = Set{Symbol}()
    abstracts = abstracts_blob["abstracts"]
    defaults  = abstracts_blob["default_concretes"]
    for (abs_name, info) in abstracts
        info["parent"] == "IMASdd.IDStop{T}" || continue
        haskey(defaults, abs_name) || continue
        # A top-level abstract has exactly one default, at the same parent_path
        # as its concrete name (e.g. `build → build`); `default_concrete`
        # unwraps the nested dict.
        push!(out, Symbol(default_concrete(abstracts_blob, abs_name)))
    end
    return out
end

"""
    _classify_binding_key(key, top_level_slots, valid_abstracts) -> Symbol

Priority lookup:

1. If `key ∈ top_level_slots` → `:top_level_slot`
2. Else if `key ∈ valid_abstracts` → `:abstract_name`
3. Else if name starts with `AbstractIFE` → raise
   `:unknown_abstract_binding` (more specific diagnostic)
4. Else → raise `:unknown_binding_key`
"""
function _classify_binding_key(key::Symbol, top_level_slots::Set{Symbol},
                                valid_abstracts::Set{Symbol})
    if key in top_level_slots
        return :top_level_slot
    elseif key in valid_abstracts
        return :abstract_name
    elseif startswith(string(key), "AbstractIFE")
        throw(GeneratorError(:unknown_abstract_binding,
            "slot_bindings key `:$(key)` looks like an abstract name " *
            "but is not in data_dictionary/abstracts.json. " *
            "Available abstracts: $(sort!(string.(collect(valid_abstracts))))"))
    else
        throw(GeneratorError(:unknown_binding_key,
            "slot_bindings key `:$(key)` is neither a top-level IDS " *
            "name (one of $(sort!(string.(collect(top_level_slots))))) nor an IFEdd " *
            "abstract name (see data_dictionary/abstracts.json)."))
    end
end

"""
    _abstract_for_top_level_slot(slot::Symbol, abstracts_blob) -> String

Invert `default_concretes` to find the abstract name for a top-level
slot symbol. Used when mapping a slot-name key (e.g. `:summary`) onto
its corresponding abstract (`"AbstractIFESummary"`).
"""
function _abstract_for_top_level_slot(slot::Symbol, abstracts_blob::AbstractDict)
    # Walk the nested default_concretes. For a top-level abstract, the inner
    # dict's single concrete is the slot we're looking for.
    defaults = abstracts_blob["default_concretes"]
    abstracts = abstracts_blob["abstracts"]
    for (abs_name, inner) in defaults
        get(abstracts[abs_name], "parent", "") == "IMASdd.IDStop{T}" || continue
        for (_path, concrete) in inner
            Symbol(concrete) === slot || continue
            return abs_name
        end
    end
    error("internal: no abstract found for top-level slot :$(slot) " *
          "(should be unreachable — caller already validated against top_level_slots)")
end

"""
    _classify_kind_from_parent(parent_str) -> String

Map a qualified IMASdd parent string (e.g. `"IMASdd.IDStop{T}"`) to
its embedding-kind label used in the substitution graph. Three valid
values: `"IDStop"`, `"IDSvectorStaticElement"`, `"IDS"`. Errors on
unrecognized parent strings.
"""
function _classify_kind_from_parent(parent_str::AbstractString)
    parent_str == "IMASdd.IDStop{T}"                && return "IDStop"
    parent_str == "IMASdd.IDSvectorStaticElement{T}" && return "IDSvectorStaticElement"
    parent_str == "IMASdd.IDS{T}"                    && return "IDS"
    error("internal: unrecognized parent string `$(parent_str)` " *
          "(supported: IMASdd.{IDStop, IDS, IDSvectorStaticElement}{T})")
end

"""
    _declared_supertype(user_schema_root_entry) -> Union{String,Nothing}

Look up the `_supertype` marker on the root entry of a user schema
(e.g. `user_schemas["my_layer"]["my_layer"]["_supertype"]`). Returns
`nothing` if absent. Used to validate abstract-name bindings — a binding
`:AbstractIFEBuildLayer => :my_layer` expects `my_layer`'s root
marker to be `AbstractIFEBuildLayer` (raises
`:binding_marker_mismatch` if not).
"""
function _declared_supertype(user_schema::AbstractDict)
    # user_schemas[name] is the parsed JSON dict; its root key is the
    # concrete name; the root entry's _supertype is the marker.
    for (path, entry) in user_schema
        entry isa AbstractDict || continue
        contains(path, ".") && continue           # root entry has no dot
        haskey(entry, "_supertype") || continue
        return String(entry["_supertype"])
    end
    return nothing
end

"""
    _build_substitution_graph(slot_bindings, abstracts_blob,
                              user_schemas, target_module)
        -> Dict{String, NamedTuple}

Build the substitution graph. One entry per binding; keyed on the *default*
concrete name (e.g. `"build__layer"`); value carries the user concrete name,
the abstract it satisfies, the embedding kind, and the original user-supplied
key (for manifest round-trip).

Slot-name keys (e.g. `:summary`) and abstract-name keys
(e.g. `:AbstractIFEBuildLayer`) both flow through the same algorithm —
`_classify_binding_key` selects the path.

Raises any of: `:unknown_binding_key`, `:unknown_abstract_binding`,
`:slot_key_collision`, `:abstract_no_default`,
`:concrete_not_in_schemas`, `:binding_marker_mismatch`.

`target_module` is accepted for forward compatibility but not consumed:
user concretes are referenced by bare name inside the user module.
"""
function _build_substitution_graph(slot_bindings::AbstractDict,
                                    abstracts_blob::AbstractDict,
                                    user_schemas::AbstractDict,
                                    target_module::Symbol)
    graph    = Dict{String, NamedTuple}()
    abs_dict = abstracts_blob["abstracts"]
    defaults = abstracts_blob["default_concretes"]
    valid    = Set(Symbol.(keys(abs_dict)))
    top_lvl  = _derived_top_level_slots(abstracts_blob)

    # Normalize every accepted binding form into one shape: a Vector of
    # (abs_key::Symbol, user_concrete::Symbol, parent_path::Union{Symbol,Nothing},
    # source_key) tuples. Tuple keys and nested-dict values (the shared-abstract
    # forms) collapse onto the same shape as the plain scalar form. For
    # slot-name keys, abs_key IS the slot symbol and parent_path is nothing.
    normalized = Vector{NamedTuple}(undef, 0)
    for (k, v) in slot_bindings
        if k isa Tuple{Symbol,Symbol}
            # sugar form: (abs_name, parent_path) => user_concrete
            abs_sym, path_sym = k
            abs_sym in valid ||
                throw(GeneratorError(:unknown_abstract_binding,
                    "slot_bindings key `($(repr(abs_sym)), $(repr(path_sym)))` " *
                    "references an abstract `:$(abs_sym)` not in abstracts.json."))
            push!(normalized,
                  (abs_key=abs_sym, user=Symbol(v),
                   parent_path=path_sym, source_key=k))
        elseif v isa AbstractDict
            # canonical form: :abs_name => Dict(:path => :user_concrete, …)
            abs_sym = k
            abs_sym in valid ||
                throw(GeneratorError(:unknown_abstract_binding,
                    "slot_bindings key `:$(abs_sym)` references an abstract " *
                    "not in abstracts.json."))
            isempty(v) &&
                throw(GeneratorError(:shared_abstract_empty_binding,
                    "slot_bindings[:$(abs_sym)] is an empty Dict; supply " *
                    "at least one parent_path => concrete entry, or pass a " *
                    "bare Symbol for single-default abstracts."))
            for (path_sym, user_sym) in v
                push!(normalized,
                      (abs_key=abs_sym, user=Symbol(user_sym),
                       parent_path=path_sym, source_key=(k, path_sym)))
            end
        else
            # top-level slot name, or a single-default abstract name
            push!(normalized,
                  (abs_key=k, user=Symbol(v),
                   parent_path=nothing, source_key=k))
        end
    end

    # First pass — classify every key (and raise on unknown names).
    classifications = Dict{Symbol,Symbol}()
    for entry in normalized
        haskey(classifications, entry.abs_key) && continue
        classifications[entry.abs_key] = _classify_binding_key(entry.abs_key, top_lvl, valid)
    end

    # Ambiguity check: is any abstract-name key's default concrete also bound
    # directly by its slot name? (e.g. the user passed both `:summary` and
    # `:AbstractIFESummary`.) Only meaningful for top-level abstracts (IDStop
    # parent); shared abstracts can have multiple defaults, and their per-path
    # collisions are caught later by the per-default-graph check.
    for (k, c) in classifications
        c === :abstract_name || continue
        abs_name = string(k)
        haskey(defaults, abs_name) ||
            throw(GeneratorError(:abstract_no_default,
                "abstract `$(abs_name)` has no default concrete in " *
                "abstracts.json; cannot bind it."))
        # Shared abstracts (multiple defaults) skip this check — their
        # bare-symbol form already raises :shared_abstract_needs_path in the
        # per-binding pass.
        length(defaults[abs_name]) == 1 || continue
        default = default_concrete(abstracts_blob, abs_name)
        sym_default = Symbol(default)
        if sym_default in top_lvl &&
           haskey(slot_bindings, sym_default) &&
           get(classifications, sym_default, nothing) === :top_level_slot
            slot_val     = slot_bindings[sym_default]
            abstract_val = slot_bindings[k]
            throw(GeneratorError(:slot_key_collision,
                "slot `:$(sym_default)` is bound twice in slot_bindings:\n" *
                "  - slot key      `:$(sym_default)` => :$(slot_val)\n" *
                "  - abstract key  `:$(k)` => :$(abstract_val)\n" *
                "Use exactly one key per slot."))
        end
    end

    # Second pass — build the graph from the normalized form.
    for entry in normalized
        k = entry.abs_key
        v = entry.user
        explicit_path = entry.parent_path
        user_concrete = string(v)
        haskey(user_schemas, user_concrete) ||
            throw(GeneratorError(:concrete_not_in_schemas,
                  "binding `:$(k) => :$(v)` — concrete `$(user_concrete)` not in user schemas"))

        if classifications[k] === :top_level_slot
            default     = string(k)
            abs_name    = _abstract_for_top_level_slot(k, abstracts_blob)
            parent_kind = "IDStop"
        else  # :abstract_name
            abs_name    = string(k)
            if explicit_path !== nothing
                # path-qualified forms: resolve against that parent path
                default = default_concrete(abstracts_blob, abs_name, string(explicit_path))
            else
                # Bare Symbol => Symbol: single-default lookup; raises
                # :shared_abstract_needs_path if the abstract is shared.
                default = default_concrete(abstracts_blob, abs_name)
            end
            parent_kind = _classify_kind_from_parent(abs_dict[abs_name]["parent"])
        end

        # The user concrete's _supertype marker must agree with the abstract
        # it is being bound to.
        decl = _declared_supertype(user_schemas[user_concrete])
        if decl !== nothing && decl != abs_name
            throw(GeneratorError(:binding_marker_mismatch,
                "binding `:$(k) => :$(v)` expects user concrete " *
                "`$(user_concrete)` to be declared <: $(abs_name), " *
                "but its `_supertype` marker says <: $(decl)."))
        end

        # Collision check: same default already bound? Indicates two
        # bindings refer to the same emitted struct (rare but possible
        # if the user writes two different binding forms for the same
        # (abstract, parent path) pair).
        if haskey(graph, default)
            prev = graph[default]
            throw(GeneratorError(:slot_key_collision,
                "default concrete `$(default)` is bound twice:\n" *
                "  - via $(prev.source_key) => :$(prev.user_concrete)\n" *
                "  - via $(entry.source_key) => :$(user_concrete)\n" *
                "Use exactly one binding per default."))
        end
        graph[default] = (user_concrete = user_concrete,
                          abstract      = abs_name,
                          parent_kind   = parent_kind,
                          source_key    = entry.source_key)
    end
    return graph
end

"""
    _build_auto_recursive_graph(user_schemas, base_graph) -> Dict{String,NamedTuple}

Auto-recursive substitution. For each user schema marker
`<path>._supertype: X` at a NESTED path (path != root) where the user
bound `X` to some concrete in `slot_bindings` (visible via `base_graph`),
emit a substitution entry keyed on the user's default nested struct
name (e.g. `my_layer___outline`) → the user's bound concrete.

The bound concrete is harvested from `base_graph` by inverting `abstract
→ user_concrete`. For shared abstracts (multiple `base_graph` entries
sharing one abstract) that would be ambiguous, so only single-mapped
abstracts auto-recurse; ambiguous ones are skipped silently and remain
bindable per-site with a `(abstract, parent_path)` key.

Entries are skipped when:
- the marker is on the user concrete's ROOT path (already handled at the
  dd-slot level by the base graph),
- the abstract has multiple bindings in base_graph (shared-abstract
  ambiguity at user-side),
- the derived struct name already EQUALS the user concrete (no rewrite
  needed — the bound concrete IS the marked struct, e.g. when a user
  concrete is both the binding target and the parent's nested type),
- the path classifies as IDStop (markers there are validated elsewhere).

Returns an empty Dict when no auto-recursive substitutions apply, so the
caller can `merge` it into `base_graph` unconditionally.
"""
function _build_auto_recursive_graph(user_schemas::AbstractDict,
                                      base_graph::Dict{String,NamedTuple})
    # Invert base_graph: abstract → [user_concrete...]
    abs_to_user = Dict{String, Set{String}}()
    for (_default, entry) in base_graph
        push!(get!(abs_to_user, entry.abstract, Set{String}()),
              entry.user_concrete)
    end

    auto = Dict{String, NamedTuple}()
    for (uname, schema) in user_schemas
        for (path, entry) in schema
            entry isa AbstractDict || continue
            haskey(entry, "_supertype") || continue
            # Skip root markers — the base graph already substitutes at the
            # dd-slot level via its IDStop or per-abstract entry.
            path == uname && continue
            abs_name = String(entry["_supertype"])
            haskey(abs_to_user, abs_name) || continue

            candidates = abs_to_user[abs_name]
            length(candidates) == 1 || continue   # shared-abstract ambiguity

            user_concrete = first(candidates)
            struct_name = path_to_struct_name(path)
            struct_name == user_concrete && continue   # no rewrite needed

            parent_qualified = classify_parent(path, entry)
            parent_kind = if parent_qualified == "IMASdd.IDSvectorStaticElement"
                "IDSvectorStaticElement"
            elseif parent_qualified == "IMASdd.IDS"
                "IDS"
            else
                continue   # IDStop nested is not a substitution target
            end

            # Collision: two markers producing the same struct name.
            # First-write wins; second is silently dropped (user schemas
            # only ever produce one definition per struct_name anyway).
            haskey(auto, struct_name) && continue

            auto[struct_name] = (user_concrete = user_concrete,
                                  abstract = abs_name,
                                  parent_kind = parent_kind,
                                  source_key = (:auto_recursive, Symbol(path)))
        end
    end
    return auto
end

# ============================================================================
# Regex pass over postprocessed emitted code
# ----------------------------------------------------------------------------
# Two passes per graph entry:
#   (i)  field-type substitution    (rewrite struct-field type annotations)
#   (ii) constructor-call substitution (rewrite the kw-arg outer ctor body)
# Each pass distinguishes the IDS / IDSvector embedding shape. Count-
# asserted: each entry must match exactly ONE field decl AND ONE ctor
# call across the entire emitted file, OR raise `:substitution_missed` /
# `:substitution_over_match`.
# The ctor regex tolerates both `(;frozen)` and `(; frozen)` via `\s*`.
# ============================================================================

"""
    _replace_count(s::AbstractString, pat::Regex, repl) -> (new_string, n_matches)

Count-tracking wrapper around `replace`. Returns the substituted
string AND the number of matches found (used by
`_apply_substitution_graph` for miss / over-match detection).
"""
function _replace_count(s::AbstractString, pat::Regex, repl)
    n = length(collect(eachmatch(pat, s)))
    return (replace(s, pat => repl), n)
end

"""
    _apply_substitution_graph(content::AbstractString,
                              graph::Dict{String,NamedTuple})
        -> String

Per graph entry (skipping IDStop top-level entries, handled by
`_emit_user_dd`):

- pass (i): rewrite `var"X"::default_name{T}` → `var"X"::user_name{T}`
  (direct STRUCTURE) AND `var"X"::IMASdd.IDSvector{default_name{T}}` →
  `var"X"::IMASdd.IDSvector{user_name{T}}` (STRUCT_ARRAY).
- pass (ii): rewrite `default_name{T}(; frozen)` → `user_name{T}(; frozen)`
  AND `IMASdd.IDSvector{default_name{T}}(; frozen)` →
  `IMASdd.IDSvector{user_name{T}}(; frozen)` (ctor body).

Per-entry assertions:
- field-decl pass must fire exactly 1 match (per parent_kind shape)
- ctor pass must fire exactly 1 match
- > 1 match for either pass ⇒ `:substitution_over_match` (cross-IDS
  reuse signal)

Negative-lookahead anchors defend against partial-name collisions:
`build__layer` regex does NOT match inside `build__layer___outline`
because the `\\{T\\}` literal requires `{` next, not `_`.
"""
function _apply_substitution_graph(content::AbstractString,
                                    graph::Dict{String,NamedTuple})
    out = String(content)
    miss = String[]
    over = String[]

    for (default_name, entry) in graph
        entry.parent_kind == "IDStop" && continue  # top-level handled separately

        user_name = entry.user_concrete

        # --- Pass (i) — field-type substitution -------------------------
        # Pattern A: direct STRUCTURE embed (`var"X"::default_name{T}`).
        # Negative lookahead `(?![A-Za-z_0-9])` blocks partial-name match
        # against longer struct names sharing the prefix.
        pat_direct = Regex("(var\"[A-Za-z_][A-Za-z_0-9]*\"::)\\Q$(default_name)\\E\\{T\\}(?![A-Za-z_0-9])")
        out, n_field_direct = _replace_count(out, pat_direct,
            SubstitutionString("\\1$(user_name){T}"))

        # Pattern B: IDSvector{...} embed.
        pat_vec = Regex("(var\"[A-Za-z_][A-Za-z_0-9]*\"::IMASdd\\.IDSvector\\{)\\Q$(default_name)\\E\\{T\\}\\}")
        out, n_field_vec = _replace_count(out, pat_vec,
            SubstitutionString("\\1$(user_name){T}}"))

        # --- Pass (ii) — constructor-call substitution -----------------
        # Lookbehind `(?<![A-Za-z_0-9.])` prevents matching
        # `IFEdd.default_name{T}(; frozen)` (qualified) or
        # `xdefault_name{T}` (prefix-extended).
        pat_ctor_direct = Regex("(?<![A-Za-z_0-9.])\\Q$(default_name)\\E\\{T\\}\\(;\\s*frozen\\)")
        out, n_ctor_direct = _replace_count(out, pat_ctor_direct,
            "$(user_name){T}(;frozen)")

        pat_ctor_vec = Regex("(IMASdd\\.IDSvector\\{)\\Q$(default_name)\\E\\{T\\}\\}\\(;\\s*frozen\\)")
        out, n_ctor_vec = _replace_count(out, pat_ctor_vec,
            SubstitutionString("\\1$(user_name){T}}(;frozen)"))

        # --- Pass (iii) — _name rewrite for user concrete ctor ---------
        # IMASdd.add_filled looks up `parent._filled.<_name>`. For a user
        # concrete plugged into a parent's `:layer` / `:efficiency` / etc.
        # slot, `_name` must equal the slot key, not the user type name.
        # GenerateDD's default ctor emits `Symbol("user_name")` for user
        # concretes (because the type has no nested path → "user_name"
        # has no `__` to strip from). Rewrite to the slot key derived
        # from the default-concrete's last `__`-separated segment.
        # NOTE: for triple-underscore boundaries (e.g.
        # `driver__beam___efficiency`) `split(...,"__")` returns
        # `["driver","beam","_efficiency"]` — strip the leading `_` so
        # the slot_key matches the parent's actual field name.
        slot_key = lstrip(last(split(default_name, "__")), '_')
        # Pattern matches: ` Symbol("user_name") ` inside user concrete's ctor body.
        # \\Q ... \\E literalizes. The match is whole word due to literal quotes.
        pat_name = Regex("Symbol\\(\"\\Q$(user_name)\\E\"\\)")
        out, _ = _replace_count(out, pat_name, "Symbol(\"$(slot_key)\")")

        # --- Pass (iv) — IDSvector._name fix for vector substitutions ---
        # IMASdd's `IDSvector` inner ctor (data_header.jl:30) derives
        # `_name` from `rsplit(typename, "__")[end]`. For user concretes
        # without `__` in the type name (e.g. `my_layer`), the IDSvector's
        # `_name` becomes `:my_layer` instead of `:layer`. add_filled on
        # push! then looks up `parent._filled.my_layer` → FieldError.
        # Fix: inject `setfield!(ids.<slot>, :_name, :<slot>)` into the
        # parent IDS ctor right after the `setfield!(ids.<slot>, :_parent, …)`
        # line that the regenerated parent ctor already contains.
        if entry.parent_kind == "IDSvectorStaticElement"
            anchor_pat = Regex("(setfield!\\(ids\\.\\Q$(slot_key)\\E,\\s*:_parent,\\s*WeakRef\\(ids\\)\\))")
            replacement = SubstitutionString("\\1\n    setfield!(ids.$(slot_key), :_name, :$(slot_key))")
            out, _ = _replace_count(out, anchor_pat, replacement)
        end

        # --- Per-entry assertions --------------------------------------
        n_field_total = n_field_direct + n_field_vec
        n_ctor_total  = n_ctor_direct  + n_ctor_vec
        if n_field_total == 0
            push!(miss, "$(default_name): no field-decl match")
        elseif entry.parent_kind == "IDSvectorStaticElement" && n_field_vec == 0
            push!(miss, "$(default_name): expected vector field match (parent_kind=IDSvectorStaticElement)")
        elseif entry.parent_kind == "IDS" && n_field_direct == 0
            push!(miss, "$(default_name): expected direct field match (parent_kind=IDS)")
        end
        if n_ctor_total == 0
            push!(miss, "$(default_name): no ctor match")
        end
        if n_field_total > 1 || n_ctor_total > 1
            push!(over, "$(default_name): matched $(n_field_total) field decls / " *
                  "$(n_ctor_total) ctor calls (expected 1 each — suggests cross-IDS name reuse)")
        end
    end

    if !isempty(miss)
        throw(GeneratorError(:substitution_missed,
            "substitution_graph did not match for:\n  - " *
            join(miss, "\n  - ") *
            "\n(the GenerateDD emission shape may have drifted; adjust the regex " *
            "patterns in src/generator/substitution.jl.)"))
    end
    if !isempty(over)
        throw(GeneratorError(:substitution_over_match,
            "substitution_graph over-matched (suggests cross-IDS name reuse " *
            "or unintended over-substitution):\n  - " *
            join(over, "\n  - ")))
    end
    return out
end

# ============================================================================
# Workdir expansion + parent-IDS supertype recovery
# ============================================================================

"""
    _substituted_parent_idss(graph) -> Set{String}

Set of parent IDS names (e.g. `"build"`, `"driver"`) whose schemas
must be regenerated because the user bound a nested abstract beneath
them. Top-level (IDStop) bindings are excluded — those are handled by
the main emission pipeline and `_emit_user_dd`.
"""
function _substituted_parent_idss(graph::Dict{String,NamedTuple})
    out = Set{String}()
    for (default_name, entry) in graph
        entry.parent_kind == "IDStop" && continue
        push!(out, first(split(default_name, "__")))
    end
    return out
end

"""
    _expand_workdir_for_substitution!(workdir, graph,
                                      user_concrete_names,
                                      defaults_dir, user_schemas) ->
        Vector{String}  # the (possibly extended) user_concrete_names

For each substituted nested abstract, symlink IFEdd's default
parent-IDS schema (e.g. `build.json`) into the user workdir's
`data_structures_extra/` and APPEND the parent IDS name to
`user_concrete_names` so the existing GenerateDD loop pulls in its
field set. This produces an emitted `build{T}` whose field types the
regex pass then rewrites.

Skip parents the user has already supplied (those would have been
rejected as `:user_name_shadows_ifedd_default` upstream; defensive
guard here).

Raises `:parent_schema_missing` if IFEdd's parent schema file is
absent (sysimage'd / relocated IFEdd).
"""
function _expand_workdir_for_substitution!(workdir::AbstractString,
                                            graph::Dict{String,NamedTuple},
                                            user_concrete_names::Vector{String},
                                            defaults_dir::AbstractString,
                                            user_schemas::AbstractDict)
    extra_dir = joinpath(workdir, "data_structures_extra")
    parents = _substituted_parent_idss(graph)
    for parent in sort!(collect(parents))   # sort for determinism
        haskey(user_schemas, parent) && continue   # user supplied it themselves
        parent in user_concrete_names && continue  # already emitted
        src = joinpath(defaults_dir, "$(parent).json")
        isfile(src) || throw(GeneratorError(:parent_schema_missing,
            "substitution at `$(parent).*` requires IFEdd's " *
            "default `$(parent).json`, but it's missing at `$(src)`. " *
            "(Sysimage'd IFEdd? Relocated package?)"))
        dst = joinpath(extra_dir, "$(parent).json")
        if !isfile(dst)
            symlink(src, dst)
        end
        push!(user_concrete_names, parent)
    end
    return user_concrete_names
end

"""
    _strip_duplicate_element_struct(content, user_schemas) -> String

When a user concrete is intended as an IDSvector element type
(its schema has `<name>[:].field` paths), GenerateDD emits TWO
struct blocks for `<name>{T}`:

1. The element-type struct (from `<name>[:].field` paths) — carries
   all fields, gets the user's `_supertype` substitution.
2. A spurious root struct (from the bare `<name>` path) — empty
   fields, `<: IMASdd.IDStop{T}`. Causes Julia parse error
   (empty positional ctor args).

This helper detects the spurious root and strips it. Detection
heuristic: user schemas containing any key matching `"<name>[:]"`
are element types; the corresponding `mutable struct <name>{T}
<: IMASdd.IDStop{T}` block is the duplicate.
"""
function _strip_duplicate_element_struct(content::AbstractString,
                                          user_schemas::AbstractDict)
    element_names = String[]
    for (name, schema) in user_schemas
        for path in keys(schema)
            if startswith(path, "$(name)[:]") || path == "$(name)[:]"
                push!(element_names, name); break
            end
        end
    end
    isempty(element_names) && return content

    # State machine — for each element name, keep only the FIRST struct
    # block + FIRST FilledFields block + FIRST function block + FIRST
    # short-form ctor. Drop subsequent duplicates.
    seen_struct        = Set{String}()
    seen_filled        = Set{String}()
    seen_function      = Set{String}()
    seen_shortform     = Set{String}()
    lines = split(content, '\n')
    out = String[]
    skipping = false
    for line in lines
        if skipping
            line == "end" && (skipping = false)
            continue
        end
        drop_this_line = false
        for name in element_names
            # mutable struct FilledFields____<name>
            if occursin(Regex("^mutable struct FilledFields____\\Q$(name)\\E\\b"), line)
                if name in seen_filled
                    skipping = true; drop_this_line = true; break
                else
                    push!(seen_filled, name); break
                end
            end
            # mutable struct <name>{T} (any supertype)
            if occursin(Regex("^mutable struct \\Q$(name)\\E\\{T\\}"), line)
                if name in seen_struct
                    skipping = true; drop_this_line = true; break
                else
                    push!(seen_struct, name); break
                end
            end
            # function <name>{T}(; frozen
            if occursin(Regex("^function \\Q$(name)\\E\\{T\\}\\(;\\s*frozen"), line)
                if name in seen_function
                    skipping = true; drop_this_line = true; break
                else
                    push!(seen_function, name); break
                end
            end
            # <name>(;frozen::Bool=false) = <name>{Float64}(;frozen)  — one-liner
            if occursin(Regex("^\\Q$(name)\\E\\(;\\s*frozen::Bool=false\\)\\s*="), line)
                if name in seen_shortform
                    drop_this_line = true; break
                else
                    push!(seen_shortform, name); break
                end
            end
        end
        drop_this_line && continue
        push!(out, line)
    end
    return join(out, '\n')
end

"""
    _apply_parent_supertype_recovery(content, graph, abstracts_blob) -> String

For each substituted parent IDS, rewrite its emitted struct
declaration from `<: IMASdd.IDStop{T}` back to
`<: IFEdd.<AbstractIFE…>{T}`. Same rewrite the user-marker pass does,
but for parent IDSs introduced by `_expand_workdir_for_substitution!`
(which lack `_supertype` markers in the user's schemas because the
user didn't write the parent schema).

The inversion: parent IDS `"build"` → `default_concretes` lookup
gives `AbstractIFEBuild` (since `default_concretes["AbstractIFEBuild"]
= "build"`).
"""
function _apply_parent_supertype_recovery(content::AbstractString,
                                           graph::Dict{String,NamedTuple},
                                           abstracts_blob::AbstractDict)
    defaults = abstracts_blob["default_concretes"]
    parents = _substituted_parent_idss(graph)
    isempty(parents) && return content
    # `defaults` is nested. Top-level abstracts have exactly one inner entry;
    # invert (concrete → abstract) for those.
    inverted = Dict{String,String}()
    abstracts = abstracts_blob["abstracts"]
    for (abs_name, inner) in defaults
        get(abstracts[abs_name], "parent", "") == "IMASdd.IDStop{T}" || continue
        for (_path, concrete) in inner
            inverted[concrete] = abs_name
        end
    end
    out = String(content)
    for parent in parents
        abs_name = get(inverted, parent, nothing)
        abs_name === nothing && continue   # not a top-level concrete; skip
        pattern = Regex("(mutable struct \\Q$(parent)\\E\\{T\\}\\s*<:\\s*)IMASdd\\.IDStop\\{T\\}")
        replacement = SubstitutionString("\\1IFEdd.$(abs_name){T}")
        out = replace(out, pattern => replacement)
    end
    return out
end
