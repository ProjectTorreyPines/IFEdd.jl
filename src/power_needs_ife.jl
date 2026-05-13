# IFE-specific FUSE.ActorPowerNeeds integration.
#
# Two methods extend FUSE's generic functions; both involve an IFEdd-owned
# type (`ife_driver` or `dd_ife`), so neither is type piracy.
#
# Ported from joey_fork/FUSE.jl/src/actors/balance_plant/power_needs_actor.jl
# L86-98 (IFE branch) and L136-143 (electricity dispatch).

"""
    FUSE.electricity(ife_driver::ife_driver)

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
    FUSE._step_power_needs_ife!(dd::dd_ife)

IFE branch of `FUSE.ActorPowerNeeds._step` (model = :IFE). Activated only
when the embedded container is a `dd_ife`.
"""
function FUSE._step_power_needs_ife!(dd::dd_ife)
    bop_electric = dd.balance_of_plant.power_electric_plant_operation
    if !isempty(dd.ife_driver.beam)
        idx = IMAS.name_2_index(bop_electric.system)[:HCD]
        hcd_sys = resize!(bop_electric.system, "name" => "HCD", "index" => idx)
        sub = resize!(hcd_sys.subsystem, "name" => "ife_driver", "index" => 1)
        P_driver = FUSE.electricity(dd.ife_driver)
        IMAS.@ddtime(sub.power = P_driver)
        IMAS.@ddtime(hcd_sys.power = P_driver)
    end
    idx = IMAS.name_2_index(bop_electric.system)[:tritium_handling]
    sys = resize!(bop_electric.system, "name" => "tritium_handling", "index" => idx)
    IMAS.@ddtime(sys.power = FUSE.electricity(:tritium_handling))
    return nothing
end
