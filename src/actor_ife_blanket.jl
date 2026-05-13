# ActorIFEBlanket: IFE blanket TBR and neutron flux distribution.
#
# Ported from joey_fork/FUSE.jl/src/actors/nuclear/ife_blanket_actor.jl. Two
# notable adaptations vs joey:
#   1. Two-container signature: reads IFE build from `ife.ife_build`, writes
#      results to `dd.blanket` and `dd.neutronics` (joey's monolithic dd had
#      both; we split them).
#   2. ParametersActor is currently empty — the full parameter set
#      (`blanket_multiplier`, `thermal_power_extraction_efficiency`,
#      `max_Li6_enrichment_fraction`, `verbose`) is left in the docstring as
#      a porting reference until FUSE.@actor_parameters_struct integration
#      is decided.
#
# `FUSE._step` is a stub; see the docstring for the joey calculation outline.

Base.@kwdef mutable struct FUSEparameters__ActorIFEBlanket{T<:Real} <: FUSE.ParametersActor{T}
    _parent::WeakRef = WeakRef(nothing)
    _name::Symbol = :ActorIFEBlanket
    # TODO: port joey parameters
    # blanket_multiplier::FUSE.Entry{T} = FUSE.Entry{T}("-", "Neutron thermal power multiplier in blanket"; default=1.2)
    # thermal_power_extraction_efficiency::FUSE.Entry{T} = FUSE.Entry{T}("-", "Fraction of thermal power carried out by coolant"; default=1.0)
    # max_Li6_enrichment_fraction::FUSE.Entry{T} = FUSE.Entry{T}("-", "Maximum allowed Li6 enrichment fraction"; default=0.9)
    # verbose::FUSE.Entry{Bool} = FUSE.Entry{Bool}("-", "verbose"; default=false)
end

struct ActorIFEBlanket{D,P} <: FUSE.AbstractActor{D,P}
    dd::D
    ife::dd_ife
    par::P
    act::FUSE.ParametersAllActors
end

"""
    ActorIFEBlanket(dd::IMAS.dd, ife::dd_ife, par, act; kw...)

Calculate IFE blanket performance: tritium breeding ratio (TBR), thermal
power, and neutron wall loading using 1D neutronics with spherical geometry.

Assumes isotropic neutron emission from the target into concentric spherical
layers defined in `ife.ife_build`. Optimizes Li-6 enrichment to meet the
target TBR in `dd.requirements.tritium_breeding_ratio`.

Writes to `dd.blanket` and `dd.neutronics`. Reads from `ife.ife_build` and
`dd.core_profiles` (for `IMAS.fusion_neutron_power` time integration).

# Joey calculation outline (to port into `_step`)
1. Identify wall/blanket/shield layers in `ife.ife_build.layer` by
   `_wall_`, `_blanket_`, `_shield_` (fallback `_vessel_`) enum values.
2. Compute cycle-averaged neutron power: trapezoidal integration of
   `IMAS.fusion_neutron_power` over `dd.core_profiles.time`, divided by
   the cycle period.
3. Compute peak wall flux from inner blanket-layer surface area.
4. Set up `dd.blanket.module[1]` with three layers (wall, blanket, shield)
   and run `Optim.NelderMead` minimization of TBR residual against
   `NNeutronics.TBR(...)` to find the Li-6 enrichment.
5. Populate `dd.neutronics.first_wall` and `dd.neutronics.time_slice[].wall_loading`
   with radial flux pattern (`flux_r = peak_wall_flux * r̂`, etc.).

See `joey_fork/FUSE.jl/src/actors/nuclear/ife_blanket_actor.jl` for the
full implementation.
"""
function ActorIFEBlanket(
    dd::IMAS.dd,
    ife::dd_ife,
    par::FUSEparameters__ActorIFEBlanket,
    act::FUSE.ParametersAllActors;
    kw...,
)
    par = FUSE.par_from_kw(par, kw)
    actor = ActorIFEBlanket(dd, ife, par, act)
    FUSE._step(actor)
    FUSE._finalize(actor)
    return actor
end

function FUSE._step(actor::ActorIFEBlanket)
    # TODO: port joey ife_blanket_actor.jl `_step` body. Will pull in
    # NNeutronics, Optim, IMAS.fusion_neutron_power, IMASutils.trapz/mirror_bound,
    # and `_wall_`/`_blanket_`/`_shield_` enums from IMAS.
    return actor
end

function FUSE._finalize(actor::ActorIFEBlanket)
    return actor
end
