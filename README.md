# IFEdd

IFE (Inertial Fusion Energy) extension package for IMASdd.

This package extends the IMASdd data dictionary with IFE-specific IDS types
**without modifying IMASdd itself**. New IDS structures are defined as subtypes
of IMASdd's abstract type hierarchy and registered into `IMASdd._all_info` at
package load time.

## Design highlights

- **`<: IMASdd.IDStop{T}`**: new IDS types join IMASdd's abstract tree, so the
  generic IMASdd / IMAS machinery (`getproperty`, `isfrozen`, expression
  evaluation, etc.) works on them without any wrapper or method override.
- **Dynamic `_all_info` registration**: `__init__()` (emitted by the
  code generator) merges schema metadata into `IMASdd._all_info`.
- **Package extensions**: heavy downstream dependencies such as FUSE and IMAS
  are declared as `[weakdeps]`. Actor definitions live in `ext/` and are loaded
  only when those packages are imported by the user.
- **Build-time codegen**: `scripts/generate.jl` reads the IFE schema JSON files
  in `data_dictionary/data_structures_extra/` and produces
  `src/dd_idstypes.jl` + `src/dd.jl`. Reuses IMASdd's installed `data_structures/` and
  `cocos_signals.jl` via `pkgdir(IMASdd)`, so nothing from IMASdd is duplicated
  in this repo.

For the full architectural rationale see
[`~/.julia/dev/IMASdd_joey/claudedocs/IMASdd_extension_design.md`](../IMASdd_joey/claudedocs/IMASdd_extension_design.md).

## Directory layout

```
IFEdd/
├── src/
│   ├── IFEdd.jl                       # main module
│   ├── dd_idstypes.jl                 # AUTO-GENERATED leaf IDS types
│   └── dd.jl                          # AUTO-GENERATED top-level container
├── ext/
│   ├── IFEddFUSEExt.jl                # FUSE Actors, loaded when FUSE is used
│   └── IFEddIMASExt.jl                # IMAS overloads, loaded when IMAS is used
├── data_dictionary/
│   └── data_structures_extra/
│       ├── ife_summary.json           # IFE schemas (source of truth)
│       ├── ife_build.json
│       └── ife_driver.json
├── scripts/
│   └── generate.jl                    # codegen runner
├── test/
│   └── runtests.jl
├── Project.toml
└── README.md
```

Note: `data_dictionary/data_structures/` and `cocos_signals.jl` are
intentionally absent. They come from IMASdd's own install at build time.

## Quick start

```julia
using Pkg
Pkg.develop(path="/Users/yoo/.julia/dev/IFEdd")
using IFEdd, IMASdd

d = IFEdd.dd()                                 # top-level container (always qualified — `dd` is NOT exported)
d isa IMASdd.DD                                # → true (abstract tree)

# Children are IMASdd's machinery sees them via _all_info
IMASdd._all_info[(IFEdd.dd, :ife_summary)]
# → IMASdd.Info(String[], "-", "STRUCTURE", "...", true, String[])

IMASdd.isfrozen(d)                             # → false (abstract dispatch)
```

Run the test suite:

```bash
cc-julia-test-runner /Users/yoo/.julia/dev/IFEdd
```

## Regenerating the data dictionary

After editing any JSON in `data_dictionary/data_structures_extra/`:

```bash
julia --project=. scripts/generate.jl
```

The script:
1. Resolves IMASdd's source root with `pkgdir(IMASdd)`.
2. Builds a temporary working directory symlinking IMASdd's
   `data_structures/`, `cocos_signals.jl`, and IFEdd's own
   `data_structures_extra/*.json`.
3. Filters the IDS list to entries starting with `ife_`.
4. Calls `GenerateDD.imas_julia_struct(...)` to emit raw struct code.
5. Post-processes the output to qualify identifiers
   (`Info` → `IMASdd.Info`, etc.). The container name `dd` is kept
   verbatim; consumers always reach it via `IFEdd.dd(...)`.
6. Writes `src/dd_idstypes.jl` (leaves) + `src/dd.jl` (container).

The temp workdir is removed on exit, so IFEdd's checkout stays clean.

## Type piracy safety

This package does not commit type piracy. Every new method dispatches on at
least one type owned by IFEdd:

| Definition                                                | Safe? |
|-----------------------------------------------------------|-------|
| `dd{T} <: IMASdd.DD{T}` (lives inside `IFEdd`, not exported) | yes   |
| `IMASdd._all_info[(IFEdd.dd, :ife_summary)] = ...`        | yes   |
| `ext: ActorIFEAblation(dd::IFEdd.dd, ...)`                | yes   |

## Roadmap

### Near term
- [ ] Flesh out `ife_summary`, `ife_build`, `ife_driver` JSON schemas
- [ ] Implement real Actor logic in `ext/IFEddFUSEExt.jl`

### Mid term
- [ ] Upstream a `GenerateDD.generate_dd_flavor` API and remove the in-tree
      post-processing pipeline
- [ ] CI workflow that re-runs `scripts/generate.jl` on every PR

### Long term
- [ ] Move to a private GitHub repo and private registry once the schema needs
      to stay restricted
