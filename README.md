# IFEdd

IFE (Inertial Fusion Energy) data dictionary — satellite of [IMASdd](https://github.com/ProjectTorreyPines/IMASdd.jl).

Defines IFE-specific IDS types (`summary`, `build`, `driver`) as
subtypes of IMASdd's abstract hierarchy and a container `dd{T} <: IMASdd.DD{T}`
that embeds the IDS used by IFE workflows. New schema metadata is registered
into `IMASdd._all_info` at package load via `__init__()`. No IMASdd source is
modified or duplicated.

Higher-level orchestration (actors, init, study cases) lives in the companion
package [IFE.jl](https://github.com/ProjectTorreyPines/IFE.jl).

## Layout

```
src/
  IFEdd.jl         # main module
  dd_idstypes.jl   # AUTO-GENERATED leaf IDS structs
  dd.jl            # AUTO-GENERATED top-level container + __init__()
ext/
  IFEddPlotsExt.jl # Plots recipes (package extension, weakdep on Plots)
data_dictionary/
  data_structures_extra/   # IFE IDS JSON schemas (source of truth)
scripts/
  generate.jl              # codegen runner
```

IMASdd's own `data_structures/` and `cocos_signals.jl` are reached via
`pkgdir(IMASdd)` at codegen time, so they are intentionally absent here.

## Quick start

```julia
using IFEdd, IMASdd

d = IFEdd.dd()                       # `dd` is NOT exported — always qualify
d isa IMASdd.DD                      # true

IMASdd._all_info[(IFEdd.dd, :summary)]
IMASdd.isfrozen(d)                   # false
```

Run tests:

```bash
cc-julia-test-runner /Users/yoo/.julia/dev/IFEdd
```

## Regenerating the data dictionary

After editing any JSON in `data_dictionary/data_structures_extra/`:

```bash
julia --project=. scripts/generate.jl
```

The script symlinks IMASdd's `data_structures/` + IFEdd's `*.json` into a
temp workdir, calls `GenerateDD.imas_julia_struct(...)`, qualifies emitted
identifiers (`Info` → `IMASdd.Info`, etc.), and writes
`src/dd_idstypes.jl` + `src/dd.jl`. The temp workdir is removed on exit.

## Type piracy safety

Every method dispatches on at least one IFEdd-owned type:

| Definition | Safe? |
|---|---|
| `dd{T} <: IMASdd.DD{T}` (lives inside `IFEdd`, not exported) | yes |
| `IMASdd._all_info[(IFEdd.dd, :summary)] = ...` | yes |
| `ext: plot recipe(::build)` | yes |
