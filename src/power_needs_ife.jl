# IFE-specific FUSE.ActorPowerNeeds integration.
#
# Two extensions on FUSE generic functions; both involve at least one
# IFEdd-owned type, so neither is type piracy:
#
#   1. `FUSE.electricity(::ife_driver)` — wall-plug power for the IFE driver.
#
#   2. `FUSE.ActorPowerNeeds(dd::dd_ife, act, ...)` — outer constructor that
#      overrides the standard `ActorPowerNeeds` pipeline for IFE scenarios.
#      Method specificity dispatches IFEdd's version when `dd` is a `dd_ife`;
#      standard FUSE method handles all other `IMAS.DD` subtypes.
#
# This pattern keeps FUSE proper completely free of IFE references — no
# `:IFE` Switch option, no hook function, no IFE-specific branch in
# `FUSE._step(::ActorPowerNeeds)`. All IFE knowledge lives here.

"""
    FUSE.electricity(drv::ife_driver)

Wall-plug electric power of the IFE driver (W).
`P_wallplug = (Σ_beam energy) / T_rep / η_conversion`.
"""
function FUSE.electricity(drv::ife_driver)
    isempty(drv.beam) && return 0.0
    isempty(drv.time) && return 0.0
    E_total = sum(b.energy for b in drv.beam)   # J per shot
    rep_rate = 1.0 / drv.time[end]              # Hz
    eta = drv.beam[1].efficiency.conversion     # wall-plug → laser
    return E_total * rep_rate / eta             # W
end

"""
    FUSE.ActorPowerNeeds(dd::dd_ife, act::FUSE.ParametersAllActors; kw...)

IFE-flavored outer constructor for `FUSE.ActorPowerNeeds`. Bypasses the
standard magnetic-confinement HCD enumeration and model-branch logic in
`FUSE._step(::FUSE.ActorPowerNeeds)` and populates BOP entries appropriate
for inertial fusion scenarios: driver wall-plug power and tritium handling.

`par.model` is ignored (the standard Switch options don't apply to IFE).

Stores results in `dd.balance_of_plant.power_electric_plant_operation`.
"""
function FUSE.ActorPowerNeeds(dd::dd_ife, act::FUSE.ParametersAllActors; kw...)
    actor = FUSE.ActorPowerNeeds(dd, act.ActorPowerNeeds; kw...)
    _step_ife_power_needs!(actor)
    FUSE.finalize(actor)
    return actor
end

"""
    _step_ife_power_needs!(actor::FUSE.ActorPowerNeeds)

IFE replacement for `FUSE._step(::ActorPowerNeeds)`. Internal to IFEdd.
"""
function _step_ife_power_needs!(actor::FUSE.ActorPowerNeeds)
    dd = actor.dd
    bop = dd.balance_of_plant
    bop_electric = bop.power_electric_plant_operation
    empty!(bop_electric)
    if IMASdd.ismissing(bop, :time)
        bop.time = [dd.global_time]
    end

    # IFE driver wall-plug power (HCD subsystem entry)
    if !isempty(dd.ife_driver.beam)
        idx = IMAS.name_2_index(bop_electric.system)[:HCD]
        hcd_sys = resize!(bop_electric.system, "name" => "HCD", "index" => idx)
        sub = resize!(hcd_sys.subsystem, "name" => "ife_driver", "index" => 1)
        P_driver = FUSE.electricity(dd.ife_driver)
        IMAS.@ddtime(sub.power = P_driver)
        IMAS.@ddtime(hcd_sys.power = P_driver)
    end

    # Tritium handling (constant power from FUSE.electricity Symbol dispatch)
    idx = IMAS.name_2_index(bop_electric.system)[:tritium_handling]
    sys = resize!(bop_electric.system, "name" => "tritium_handling", "index" => idx)
    IMAS.@ddtime(sys.power = FUSE.electricity(:tritium_handling))

    return actor
end
