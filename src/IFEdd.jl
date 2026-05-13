"""
    IFEdd

IFE (Inertial Fusion Energy) extension package built on top of IMASdd, IMAS,
and FUSE.

Provides:
- New IDS types (`ife_summary`, `ife_build`, `ife_driver`) subtyped under
  IMASdd's abstract hierarchy (`<: IMASdd.IDStop{T}`).
- A subset container `dd_ife <: IMASdd.DD{T}` holding only the IDS relevant
  to IFE workflows.
- Dynamic registration of schema metadata into `IMASdd._all_info` from
  `__init__()`.
- IFE-specific actors and method extensions on `FUSE.*` and `IMAS.*` generic
  functions, dispatching on IFEdd-owned types (`dd_ife`, `ife_driver`, …).
  These additions are not type piracy: every method involves at least one
  IFEdd-owned type.

Schema source of truth: `data_dictionary/data_structures_extra/*.json`.

File layout:
1. `dd_ife_idstypes.jl`     — AUTO-GENERATED leaf IDS struct definitions.
2. `dd_ife.jl`              — AUTO-GENERATED top-level container + `__init__()`
                              registering every `_all_info` entry.
3. `actors_fuse_ife.jl`     — IFE actor `ActorIFEAblation` (extends `FUSE._step`).
4. `actor_ife_blanket.jl`   — IFE blanket actor (two-container: IMAS.dd + dd_ife).
5. `extract_ife.jl`         — IFE scalar extract functions (`ife_duty_cycle`, …).
6. `imas_ife.jl`            — placeholder for IMAS extension cross-references.

Optional Plots integration lives in `ext/IFEddPlotsExt.jl` and activates
automatically when both IFEdd and Plots are loaded (weakdep extension).

(1) and (2) are produced by `scripts/generate.jl`; do not edit them by hand.

Full design rationale:
`~/.julia/dev/joey_fork/IMASdd/claudedocs/IMASdd_extension_design.md`
"""
module IFEdd

using IMASdd
using IMAS
using FUSE

# Order matters: dd_ife (container) references leaf types as field types.
include("dd_ife_idstypes.jl")
include("dd_ife.jl")

# IFE-specific methods on FUSE / IMAS generic functions.
include("actors_fuse_ife.jl")
include("actor_ife_blanket.jl")
include("extract_ife.jl")
include("imas_ife.jl")

export dd_ife, ife_summary, ife_build, ife_driver
export ActorIFEAblation, FUSEparameters__ActorIFEAblation
export ActorIFEBlanket, FUSEparameters__ActorIFEBlanket
export ife_duty_cycle, extract_ife

end # module
