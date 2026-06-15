"""
    IFEdd

IFE (Inertial Fusion Energy) data dictionary — satellite of `IMASdd`.

Defines IFE-specific IDS types (`ife_summary`, `ife_build`, `ife_driver`)
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

include("dd_idstypes.jl")
include("dd.jl")

export ife_summary, ife_build, ife_driver

end # module
