"""
    IFEdd

IFE (Inertial Fusion Energy) data dictionary — satellite of `IMASdd`.

Defines IFE-specific IDS types (`summary`, `build`, `driver`)
under IMASdd's abstract hierarchy and a container `dd{T} <: IMASdd.DD{T}`
embedding the IDS used by IFE workflows. `dd` is not exported; outside
callers always write `IFEdd.dd(...)` to disambiguate from `IMASdd.dd`.

Schema source: `data_dictionary/data_structures_extra/*.json`. Generated
`dd_idstypes.jl` / `dd.jl` come from `scripts/generate.jl`.

Higher-level IFE functionality (actors, init, cases) lives in the
companion package `IFE.jl`.
"""
module IFEdd

using IMASdd
using JSON
using SHA
using FileWatching
import OrderedCollections

include("dd_abstracts.jl")
include("dd_idstypes.jl")
include("dd.jl")
include("generator/shared_helpers.jl")
include("generator/substitution.jl")
include("generator/generate_user_dd.jl")

# `dd` is emitted by the generator, which has no docstring hook. Attach the
# documentation here so `?IFEdd.dd` and the API reference find it.
"""
    IFEdd.dd{T} <: IFEdd.AbstractIFEDD{T} <: IMASdd.DD{T}

Top-level IFE data dictionary container: a sibling of `IMASdd.dd` under the
shared abstract `IMASdd.DD`, not a subtype of it.

Embeds the IFE-owned IDS (`summary`, `build`, `driver`) alongside the IMASdd
IDS that carry over unchanged (`balance_of_plant`, `blanket`, `core_profiles`,
`core_sources`, `costing`, `neutronics`, `pellets`, `requirements`).

```julia
dd = IFEdd.dd()          # Float64 element type
dd = IFEdd.dd{Float32}()
```

Because it descends from `IMASdd.DD`, the whole IMASdd API applies unchanged.

Never write `::IFEdd.dd` in a signature — it locks out customized containers
built with [`IFEdd.generate_user_dd`](@ref). Use
[`IFEdd.AbstractIFEDD`](@ref) when the function touches IFE slots
(`driver`, `build`, `summary`), or `IMASdd.DD` when it touches only slots
shared with the tokamak container.
"""
dd

# Nothing is exported. `summary`, `build`, `driver` collide name-wise with
# IMASdd; `dd` collides with `IMASdd.dd`. Consumers always qualify:
# `IFEdd.dd(...)`, `IFEdd.summary{T}`, etc.

end # module
