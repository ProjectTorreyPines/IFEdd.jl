# Troubleshooting

The generator reports every failure as [`IFEdd.GeneratorError`](@ref), carrying a
`reason::Symbol` and a detail string. Catching by reason is stable API; the detail
text is for humans.

```julia
try
    IFEdd.generate_user_dd(; …)
catch e
    e isa IFEdd.GeneratorError && e.reason === :bad_supertype && …
end
```

## Schema errors

| Reason | Cause | Fix |
|---|---|---|
| `:schema_dir_missing` | `schema_extra_dir` does not exist | Check the path |
| `:subdir_in_schema_dir` | The schema directory contains a subdirectory | Flatten it — one JSON file per IDS, no nesting |
| `:malformed_json` | A file under the schema directory will not parse | `JSON.parsefile` it locally to find the bad line |
| `:bad_supertype` | `_supertype` names an abstract outside the lattice | Use a name from [the lattice](../concepts/abstracts.md) |
| `:bad_marker_placement` | `_supertype` on a leaf scalar or on `time` | Markers belong on `STRUCTURE` / `STRUCT_ARRAY` only |
| `:user_name_shadows_ifedd_default` | Concrete named `summary`, `build` or `driver` | Pick a distinct name |

## Binding errors

| Reason | Cause | Fix |
|---|---|---|
| `:ambiguous_binding` | Two concretes declare the same `_supertype` and nothing disambiguates | Pass an explicit `slot_bindings` entry |
| `:supertype_mismatch` | A `slot_bindings` slot disagrees with the concrete's `_supertype` | Align the two |
| `:unknown_binding_key` | Key is neither a top-level slot nor an abstract name | Check spelling against `abstracts.json` |
| `:unknown_abstract_binding` | Key looks like an abstract name but is not in the lattice | As above |
| `:slot_key_collision` | Both `:summary` and `:AbstractIFESummary` passed | Use one form |
| `:shared_abstract_needs_path` | Bare key for a shared abstract, which has several hosts | Name the host — see [Substituting sub-IDSs](substitution.md#Abstract-name-plus-host) |
| `:binding_marker_mismatch` | The concrete's `_supertype` disagrees with the bound abstract | Align the two |
| `:concrete_not_in_schemas` | `slot_bindings` names a concrete with no schema file | Add the JSON, or fix the name |
| `:abstract_no_default` | The abstract has no default concrete recorded | Report as a bug |

## Emission and environment errors

| Reason | Cause | Fix |
|---|---|---|
| `:ifedd_not_locatable` | `pkgdir(IFEdd)` returned `nothing` — a sysimage or relocated install | Pass `ifedd_default_schema_dir` and `ifedd_abstracts_file` explicitly |
| `:parent_schema_missing` | A substituted parent IDS schema is missing from the IFEdd install | As above |
| `:output_dir_readonly` | `output_dir` is not writable | Fix permissions, or choose another directory |
| `:pidlock_timeout` | A concurrent generator run held the lock for over 60 s | Only one build per `output_dir` at a time; wait and retry |
| `:substitution_missed` | The rewriter found no site to substitute | Report as a bug — an IFEdd / GenerateDD version skew |
| `:substitution_over_match` | The rewriter found more than one candidate site | Report as a bug, with your schema attached |

## Runtime warnings

**`@warn "… was generated against IFEdd abstracts.json with sha256 …"`** at load time
means IFEdd was upgraded since your container was baked. Rebuild and restart:

```julia
using Pkg; Pkg.build("MyPkg")
```

The warning fires once per session and is deliberately not an error, so a partially
upgraded environment still loads.

**`MethodError: no method matching f(::MyPkg.dd, …)`** means the callee constrains its
argument to a concrete type — `::IFEdd.dd` or `::IMASdd.dd` — where it should accept
`::IFEdd.AbstractIFEDD` (or `::IMASdd.DD`). Report it against the package that owns
the method; see
[A sibling data dictionary](../concepts/sibling.md).

**World-age error right after `@bake_dd`** — the baked type is not visible inside the
same top-level expression. See [Quick bake](bake.md#World-age-caveat).
