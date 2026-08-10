# MyIFEProject — top-level slot substitution fixture

In-tree synthetic package exercising the `IFEdd.generate_user_dd` public API.
Used by `test/test_user_dd_fixture.jl` for byte-equal freshness regression and
an end-to-end load smoke test. Not registered; not intended to be `Pkg.add`-ed.

## Files

- `Project.toml` — fixture metadata. No `[compat]` block by design
  (fixture is dev-only).
- `data_dictionary/data_structures_extra/my_summary.json` — single user
  schema declaring `_supertype: "AbstractIFESummary"`. Contains depth-1
  scalars (`yield`, `gain`) plus a depth-2 nested field
  (`beam.energy`) so the GenerateDD nested-struct path is exercised.
- `deps/build.jl` — template `Pkg.build` script that re-runs
  `IFEdd.generate_user_dd` and overwrites the three generated files in
  `src/`.
- `src/MyIFEProject.jl` — module entry that `include`s the generated files.
- `src/MyIFEProject_idstypes.jl` — **GENERATED**, committed. Contains
  `my_summary{T}` and supporting sub-structs.
- `src/MyIFEProject_dd.jl` — **GENERATED**, committed. Contains
  `dd{T} <: IMASdd.DD{T}` + version-skew `__init__`.
- `src/MyIFEProject_dd_manifest.json` — **GENERATED**, committed.
  Provenance and hashes; `generated_at` excluded from freshness
  comparison.
- `test/runtests.jl` — fixture's own smoke test (invoked by the parent
  IFEdd suite via `run_in_subproject`-style isolation; do NOT
  `Pkg.test` it in-place).

## Regenerating

After changing `my_summary.json` or pulling an IFEdd update that mutates
`abstracts.json`, regenerate from the IFEdd repo root:

```bash
julia --project test/fixtures/regen_fixture.jl
git add test/fixtures/MyIFEProject/src/
git commit
```

The freshness check in `test_user_dd_fixture.jl` enforces this.
