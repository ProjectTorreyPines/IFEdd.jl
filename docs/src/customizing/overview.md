# Customizing the container

A project with its own IFE variant rarely wants IFEdd's defaults verbatim. Perhaps
your chamber layers carry a cost rate, or your summary tracks figures of merit that
are specific to your design point.

[`IFEdd.generate_user_dd`](@ref) bakes a customized container for your package. You
supply a JSON schema for the structure you want; the generator emits a concrete Julia
type for it, splices that type into the right slot of a fresh `dd{T}`, and regenerates
whichever parent IDSs needed to change to accommodate it.

Substituted types keep their place in the [abstract lattice](../concepts/abstracts.md),
so code written against `IFEdd.AbstractIFE*` continues to dispatch correctly on them.

!!! note "IFEdd's own container never changes"
    Substitution is per-bake. `IFEdd.dd()` always embeds IFEdd's defaults, and several
    packages with different customizations coexist in one session without interfering.

## Two routes

| | [Quick bake](bake.md) | [Package recipe](package.md) |
|---|---|---|
| Invocation | `IFEdd.@bake_dd` — one expression | `deps/build.jl` + `Pkg.build` |
| Generated source | temporary directory, or `output_dir` | committed under your `src/` |
| Best for | REPL exploration, one-file scripts, tests | a real package with contributors |
| Review-ability | none — the source is a build artifact | the emitted types are in your diffs |

Both call the same generator and produce the same types. Start with the quick bake;
move to the package recipe when the customization becomes something other people
depend on.

## Source of truth vs. generated artifacts

| File | Status |
|---|---|
| `data_dictionary/data_structures_extra/*.json` | hand-written — **commit** |
| `deps/build.jl` | hand-written — **commit** |
| `src/<YourPkg>.jl` | hand-written — **commit** |
| `src/<YourPkg>_idstypes.jl` | generated — commit as an artifact |
| `src/<YourPkg>_dd.jl` | generated — commit as an artifact |
| `src/<YourPkg>_dd_manifest.json` | generated — commit as an artifact |

Commit the generated files rather than regenerating them in CI. That way the types
your users load are the types you reviewed, and a schema change shows up as a diff
instead of as a silent behaviour change.

A good CI check is the inverse: regenerate into a scratch directory and assert the
output is byte-identical to what is committed. IFEdd's own test suite does exactly
this for its in-tree example packages.

## Provenance and drift detection

Each bake writes a manifest recording the IFEdd version, the SHA-256 of every input
schema and of `abstracts.json`, the SHA-256 of every emitted file, and the resolved
slot bindings:

```json
{
  "generator_version": "1.0.0",
  "ifedd_version": "3.0.0",
  "ifedd_abstracts_sha256": "7d14d43c…",
  "inputs":  { "abstracts_json": "7d14d43c…", "user_schema:my_summary": "50c58019…" },
  "outputs": { "MyPkg_dd.jl": "b90dd509…", "MyPkg_idstypes.jl": "9ff61b4f…" },
  "slot_bindings": { "summary": { "abstract": "AbstractIFESummary",
                                  "concrete": "my_summary", "source": "user" } },
  "target_module": "MyPkg"
}
```

The generated `__init__` re-hashes IFEdd's current `abstracts.json` at load time and
`@warn`s once if it differs from the hash baked in — the signal that IFEdd was
upgraded under you and the container should be rebuilt. It warns rather than errors,
so a partial upgrade degrades gracefully instead of breaking the session.

The manifest of a baked type is available at runtime through
[`IFEdd.bake_manifest`](@ref).

## Registration in the shared registry

The generated `__init__` also registers your concrete types' schema metadata into
`IMASdd._all_info`, so `IMASdd.info`, units lookup and path printing work on your
fields exactly as they do on IFEdd's own.
