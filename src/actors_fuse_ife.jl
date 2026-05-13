# IFE-specific FUSE actors and method extensions.
#
# This file lives inside the IFEdd module (not a package extension), so
# `function FUSE.<name>(...)` directly adds methods to FUSE's generic
# functions. Not a type-piracy concern: every dispatch involves at least one
# IFEdd-owned type (e.g. `dd_ife`, `ife_driver`).

# Actor parameters
Base.@kwdef mutable struct FUSEparameters__ActorIFEAblation{T<:Real} <: FUSE.ParametersActor{T}
    _parent::WeakRef = WeakRef(nothing)
    _name::Symbol = :ActorIFEAblation
    # TODO: real IFE model parameters, e.g.
    # laser_energy::FUSE.Entry{T} = FUSE.Entry{T}("J", "Laser drive energy"; default=1e6)
end

# Actor struct
struct ActorIFEAblation{D,P} <: FUSE.AbstractActor{D,P}
    dd::D
    par::P
    act::FUSE.ParametersAllActors
end

# Public constructor following the FUSE convention. Standard FUSE actors take
# `dd::IMAS.dd`; this one dispatches on our IFE-specific container instead.
function ActorIFEAblation(
    dd::dd_ife,
    par::FUSEparameters__ActorIFEAblation,
    act::FUSE.ParametersAllActors;
    kw...,
)
    par = FUSE.par_from_kw(par, kw)
    actor = ActorIFEAblation(dd, par, act)
    FUSE._step(actor)
    FUSE._finalize(actor)
    return actor
end

function FUSE._step(actor::ActorIFEAblation)
    # TODO: actual IFE ablation calculation, e.g.
    # dd, par = actor.dd, actor.par
    # dd.ife_summary.target.gain = compute_gain(dd.ife_driver, par.laser_energy)
    return actor
end

function FUSE._finalize(actor::ActorIFEAblation)
    # TODO: post-processing
    return actor
end
