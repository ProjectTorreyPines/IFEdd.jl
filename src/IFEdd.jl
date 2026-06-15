"""
    IFEdd

IFE (Inertial Fusion Energy) data dictionary — satellite of `IMASdd`.

Provides:
- New IDS types (`ife_summary`, `ife_build`, `ife_driver`) subtyped under
  IMASdd's abstract hierarchy (`<: IMASdd.IDStop{T}`).
- A subset container `dd <: IMASdd.DD{T}` (always referenced as `IFEdd.dd`
  from outside, not exported) holding the IDS relevant to IFE workflows.
- Dynamic registration of schema metadata into `IMASdd._all_info` from
  `__init__()`.

Schema source of truth: `data_dictionary/data_structures_extra/*.json`.

File layout (include order matters):
1. `dd_idstypes.jl`            — AUTO-GENERATED leaf IDS struct definitions.
2. `dd.jl`                     — AUTO-GENERATED top-level container.

(1) and (2) are produced by `scripts/generate.jl`; do not edit them by hand.

Optional Plots integration lives in `ext/IFEddPlotsExt.jl` and activates
automatically when both IFEdd and Plots are loaded (weakdep extension).

Higher-level IFE functionality (actors, init, cases, extract) lives in the
companion package `IFE.jl`, which depends on `IFEdd` + `FUSE`.

Full design rationale:
`~/.julia/dev/joey_fork/IMASdd/claudedocs/IMASdd_extension_design.md`
"""
module IFEdd

using IMASdd

# Order matters: dd (container) references leaf types as field types.
include("dd_idstypes.jl")
include("dd.jl")

# NOTE: `dd` is intentionally NOT exported. Outside callers should always
# write `IFEdd.dd(...)` so the IFE-flavored container is distinguishable
# from `IMASdd.dd` at every call site.
export ife_summary, ife_build, ife_driver

end # module
