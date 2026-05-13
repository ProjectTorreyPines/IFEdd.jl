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

File layout (include order matters):
1. `dd_ife_idstypes.jl`        — AUTO-GENERATED leaf IDS struct definitions.
2. `dd_ife.jl`                 — AUTO-GENERATED top-level container.
3. `parameters_ife.jl`         — IFE init parameter structs (ife_pellet, ife_driver).
4. `parameters_inits_ife.jl`   — IFEParametersInits container.
5. IFE actor files             — every `FUSE.ParametersActor` subtype must be
                                 defined BEFORE `parameters_actors_ife.jl` so
                                 `@insert_subtype_members` picks them up.
6. `parameters_actors_ife.jl`  — IFEParametersActors container (after IFE actors).
7. `extract_ife.jl`            — IFE scalar extract functions.
8. `imas_ife.jl`               — placeholder.

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

# IFE-specific init parameter groups (must precede IFE actor files so any
# init reference is resolvable, and precede parameters_inits_ife.jl).
include("parameters_ife.jl")

# IFEdd container for FUSE.ParametersAllInits — mirrors FUSE.ParametersInits
# field set plus the two IFE init groups defined above.
include("parameters_inits_ife.jl")

# IFE actors (each defines a FUSE.ParametersActor subtype).
include("actors_fuse_ife.jl")
include("actor_ife_blanket.jl")

# IFEdd container for FUSE.ParametersAllActors — must follow all IFE actor
# files so `@insert_subtype_members FUSE.ParametersActor` enumerates them.
include("parameters_actors_ife.jl")

# Extract + IMAS placeholder.
include("extract_ife.jl")
include("imas_ife.jl")

export dd_ife, ife_summary, ife_build, ife_driver
export FUSEparameters__ife_pellet, FUSEparameters__ife_driver
export IFEParametersInits, IFEParametersActors
export ActorIFEAblation, FUSEparameters__ActorIFEAblation
export ActorIFEBlanket, FUSEparameters__ActorIFEBlanket
export ife_duty_cycle, extract_ife

end # module
