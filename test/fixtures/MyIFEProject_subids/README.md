# MyIFEProject_subids — sub-IDS substitution fixture

In-tree synthetic package exercising `IFEdd.generate_user_dd` with
abstract-name `slot_bindings`: two sub-IDS substitutions
(`AbstractIFEBuildLayer` → `my_layer`, `AbstractIFEDriverBeamEfficiency`
→ `my_efficiency`). Used by `test/test_subids_fixture.jl` for byte-equal
freshness regression and an end-to-end load smoke test.

The sibling `MyIFEProject/` fixture covers only top-level slot substitution;
this one exercises the substitution graph and the regex rewriter end to end.

## Files

- `Project.toml` — fixture metadata (no `[compat]`, no `deps/build.jl` —
  the fixture is included from the tests, never installed).
- `data_dictionary/data_structures_extra/`:
  - `my_layer.json` — STRUCT_ARRAY element user concrete with extra
    `cost_rate` field (substitutes IFEdd's `build__layer`)
  - `my_efficiency.json` — STRUCTURE direct-embed user concrete with
    extra `cooling_correction` field (substitutes IFEdd's
    `driver__beam___efficiency`)
- `src/MyIFEProject_subids.jl` — module entry (~10 LoC).
- `src/MyIFEProject_subids_idstypes.jl` — **GENERATED**, committed.
  Contains user concretes (`my_layer{T}`, `my_efficiency{T}`) AND
  regenerated parent IDSs (`build{T}`, `driver{T}`, `driver__beam{T}`)
  with field-type + ctor-call substitution applied.
- `src/MyIFEProject_subids_dd.jl` — **GENERATED**, committed.
  Contains `dd{T} <: IMASdd.DD{T}` with substituted parents emitted
  bare (`var"build"::build{T}` not `IFEdd.build{T}`).
- `src/MyIFEProject_subids_dd_manifest.json` — **GENERATED**,
  committed. Manifest with `slot_bindings` covering both abstract-name
  keys.

## Regenerating

After changing schemas, IFEdd's `abstracts.json`, or `generate_user_dd`:

```bash
julia --project test/fixtures/regenerate_subids_fixture.jl
git add test/fixtures/MyIFEProject_subids/src/
git commit
```

The freshness check in `test_subids_fixture.jl` enforces that the committed
`src/*.jl` and `_manifest.json` match the live `generate_user_dd` output.

## What this fixture verifies (beyond unit tests)

1. The substitution graph and regex rewriter survive
   non-trivial schemas (depth-2 with extra fields).
2. The customized `build{T}` parent IDS is byte-stable across
   regenerations.
3. `IFEdd.dd().build.layer` continues to use `IFEdd.build__layer`
   (parallel-typing preservation).
4. `my_layer{Float64}` and `my_efficiency{Float64}` dispatch on
   `IFEdd.AbstractIFEBuildLayer` / `IFEdd.AbstractIFEDriverBeamEfficiency`.
5. `push!(d.build.layer, my_layer{Float64}())` works without a manual
   `_name` fixup — the rewriter preserves the IDSvector `_name` invariant.
