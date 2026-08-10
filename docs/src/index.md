# IFEdd.jl

`IFEdd.jl` is the Inertial Fusion Energy (IFE) data dictionary, a satellite of
[`IMASdd.jl`](https://github.com/ProjectTorreyPines/IMASdd.jl). It contributes the
Interface Data Structures (IDSs) that IFE workflows need — without modifying or
duplicating any IMASdd source.

Higher-level orchestration for IFE — actors, initialization, study cases — lives in
the companion package [`IFE.jl`](https://github.com/ProjectTorreyPines/IFE.jl).

## Installation

`IFEdd` is distributed through the ProjectTorreyPines registry, not the General
registry, so the registry has to be added once before `Pkg.add` can resolve it:

```julia
using Pkg
Pkg.Registry.add(RegistrySpec(url="https://github.com/ProjectTorreyPines/FuseRegistry.jl.git"))
Pkg.Registry.add("General")
Pkg.add("IFEdd")
```

## Getting started

`IFEdd` exports nothing. Every name is written qualified, because `dd`, `summary`,
`build` and `driver` all collide with IMASdd names by design:

```@example quickstart
using IFEdd

dd = IFEdd.dd()

dd.summary.target.gain = 85.0
dd.summary.target.implosion_velocity = 3.7e5

dd.summary.target
```

`dd` is an `IMASdd.DD{Float64}`, so the whole IMASdd API — `ismissing`, `freeze`,
`imas2json`, `imas2hdf`, time-dependent access, expressions — applies unchanged:

```@example quickstart
import IMASdd

(dd isa IMASdd.DD{Float64}, IMASdd.ismissing(dd.summary.target, :ifar))
```

In practice the IFE slots are filled by [`IFE.jl`](https://github.com/ProjectTorreyPines/IFE.jl)
actors rather than field by field. [Data schema](concepts/schema.md) lists what they
populate.

## Where to go next

| If you want to … | Read |
|---|---|
| Know what quantities IFEdd defines | [Data schema](concepts/schema.md) |
| Understand how `IFEdd.dd` relates to `IMASdd.dd` | [A sibling data dictionary](concepts/sibling.md) |
| Write functions that dispatch on IFE structures | [Abstract type lattice](concepts/abstracts.md) |
| Replace an IFEdd IDS with your own | [Customizing the container](customizing/overview.md) |
| Look up a function signature | [API Reference](api.md) |
