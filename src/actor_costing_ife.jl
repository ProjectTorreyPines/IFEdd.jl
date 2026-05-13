# ActorCostingIFE — IFE plant costing (PROCESS methodology + ARIES accounts).
#
# Ported from joey_fork/FUSE.jl/src/actors/costing/ife_costing_actor.jl.
# Single-container signature: `dd::dd_ife`. Helpers (DollarAdjust, future_dollars,
# bop_powers, cost_*_ARIES) are accessed via FUSE namespace and rely on the
# Phase 3 signature relaxations on FUSE side.

FUSE.@actor_parameters_struct ActorCostingIFE{T} begin
    # NOTE: joey uses `Measurement{Float64}` here to propagate cost uncertainty.
    # First-pass IFEdd port uses plain `T` so the type matches `dd_ife{Float64}.costing`
    # (a plain Float64 IDS). Restoring uncertainty propagation requires either
    # promoting dd_ife to Measurement{Float64} (joey's `IMAS.get_timeslice` pattern)
    # or wrapping all cost writes to extract nominal values.
    land_space::FUSE.Entry{T} = FUSE.Entry{T}("acres", "Plant site space required"; default=1000.0)
    building_volume::FUSE.Entry{T} = FUSE.Entry{T}("m^3", "Volume of the IFE building"; default=140e3)
    interest_rate::FUSE.Entry{T} = FUSE.Entry{T}("-", "Annual interest rate fraction of direct capital cost"; default=0.05)
    indirect_cost_rate::FUSE.Entry{T} = FUSE.Entry{T}("-",
        "Indirect cost associated with construction, equipment, services, engineering construction management and owners cost";
        default=0.4)
    escalation_fraction::FUSE.Entry{T} = FUSE.Entry{T}("-", "Yearly escalation fraction based on risk assessment"; default=0.05)
    blanket_lifetime::FUSE.Entry{T} = FUSE.Entry{T}("year", "Lifetime of the blanket"; default=7.0)
    driver_cost_fixed::FUSE.Entry{T} =
        FUSE.Entry{T}("M\$", "Fixed capital cost of IFE driver system at zero drive energy (1990 US\$)"; default=154.3)
    driver_cost_per_MJ::FUSE.Entry{T} =
        FUSE.Entry{T}("M\$/MJ", "Variable capital cost of IFE driver per MJ of drive energy (1990 US\$)"; default=111.4)
    cost_per_pellet::FUSE.Entry{T} =
        FUSE.Entry{T}("\$", "Target fabrication cost per pellet"; default=0.0)
end

mutable struct ActorCostingIFE{D,P} <: FUSE.SingleAbstractActor{D,P}
    dd::dd_ife{D}
    par::FUSE.OverrideParameters{P,FUSEparameters__ActorCostingIFE{P}}
    function ActorCostingIFE(dd::dd_ife{D}, par::FUSEparameters__ActorCostingIFE{P}; kw...) where {D<:Real,P<:Real}
        FUSE.logging_actor_init(ActorCostingIFE)
        par = FUSE.OverrideParameters(par; kw...)
        return new{D,P}(dd, par)
    end
end

"""
    ActorCostingIFE(dd::dd_ife, act::FUSE.ParametersAllActors; kw...)

Estimates fusion power plant costs for an IFE plant using the PROCESS IFE
costing methodology adapted to the ARIES cost account structure.

Stores data in `dd.costing` with detailed breakdown by system and subsystem.
"""
function ActorCostingIFE(dd::dd_ife, act::FUSE.ParametersAllActors; kw...)
    actor = ActorCostingIFE(dd, act.ActorCostingIFE; kw...)
    FUSE.step(actor)
    FUSE.finalize(actor)
    return actor
end

function FUSE._step(actor::ActorCostingIFE)
    dd = actor.dd
    par = actor.par
    cst = dd.costing

    cost_direct = cst.cost_direct_capital
    cost_ops = cst.cost_operations
    cost_decom = cst.cost_decommissioning

    da = FUSE.DollarAdjust(dd)

    power_thermal, power_electric_generated, power_electric_net = FUSE.bop_powers(dd.balance_of_plant)

    ###### Direct Capital ######

    ### IFE reactor systems
    reactor = resize!(cost_direct.system, "name" => "reactor")

    for layer in dd.ife_build.layer
        c = cost_direct_capital_IFE(layer, da)
        if c > 0.0
            sub = resize!(reactor.subsystem, "name" => layer.name)
            sub.cost = c
        end
    end

    # Driver system
    if !isempty(dd.ife_driver.beam)
        da.year_assessed = 1990
        total_energy_MJ = sum(beam.energy for beam in dd.ife_driver.beam) / 1e6
        n_drivers = length(dd.ife_driver.beam)
        driver_cost = FUSE.future_dollars(n_drivers * (par.driver_cost_fixed + par.driver_cost_per_MJ * total_energy_MJ), da)
        sub = resize!(reactor.subsystem, "name" => "driver system")
        sub.cost = driver_cost
    end

    ### Facility
    sys = resize!(cost_direct.system, "name" => "facility")

    for item in vcat(:land, :buildings, :hot_cell, :heat_transfer_loop_materials, :balance_of_plant_equipment, :fuel_cycle_rad_handling)
        sub = resize!(sys.subsystem, "name" => replace(string(item), "_" => " "))
        if item == :land
            sub.cost = FUSE.cost_direct_capital_ARIES(item, par.land_space, power_electric_generated, da)
        elseif item == :buildings
            sub.cost = FUSE.cost_direct_capital_ARIES(item, par.building_volume,
                par.land_space, power_electric_generated,
                power_thermal, power_electric_net, da)
        elseif item == :hot_cell
            sub.cost = FUSE.cost_direct_capital_ARIES(item, par.building_volume, da)
        elseif item == :heat_transfer_loop_materials
            sub.cost = FUSE.cost_direct_capital_ARIES(item, power_thermal, da)
        elseif item == :balance_of_plant_equipment
            sub.cost = FUSE.cost_direct_capital_ARIES(item, power_thermal, power_electric_generated, da, dd)
        elseif item == :fuel_cycle_rad_handling
            sub.cost = FUSE.cost_direct_capital_ARIES(item, power_thermal, power_electric_net, da)
        end
    end

    ###### Operations ######
    sys = resize!(cost_ops.system, "name" => "tritium handling")
    sys.yearly_cost = FUSE.cost_operations_ARIES(:tritium_handling, da)

    sys = resize!(cost_ops.system, "name" => "maintenance and operators")
    sys.yearly_cost = FUSE.cost_operations_ARIES(:operation_maintenance, power_electric_generated, da)

    sys = resize!(cost_ops.system, "name" => "replacements")
    blanket_idx = findfirst(item -> item.name == "blanket", reactor.subsystem)
    blanket_cost = blanket_idx !== nothing ? reactor.subsystem[blanket_idx].cost : nothing
    sub = resize!(sys.subsystem, "name" => "blanket_replacement")
    sub.yearly_cost = FUSE.cost_operations_ARIES(:blanket_replacement, blanket_cost, par.blanket_lifetime, da)

    rep_rate = isempty(dd.pellets.time_slice) ? 0.0 : dd.pellets.time_slice[].pellet[1].frequency
    pellet_yearly_cost = par.cost_per_pellet * rep_rate * 3600.0 * 24.0 * 365.0 * cst.availability / 1e6  # M$
    da.year_assessed = 2024
    sys = resize!(cost_ops.system, "name" => "target fabrication")
    sys.yearly_cost = FUSE.future_dollars(pellet_yearly_cost, da)

    ###### Decommissioning ######
    sys = resize!(cost_decom.system, "name" => "decommissioning")
    sys.cost = FUSE.cost_decomissioning_ARIES(:decom_wild_guess, cst.plant_lifetime, da)

    ###### Total cost over lifetime ######
    capital_cost_rate = par.interest_rate / (1.0 - (1.0 + par.interest_rate)^(-1.0 * cst.plant_lifetime))
    yearly_cost = (capital_cost_rate * cost_direct.cost + cost_ops.yearly_cost + cost_decom.cost / cst.plant_lifetime)
    annual_growth_rate = (1.0 + par.escalation_fraction) * (1.0 + par.indirect_cost_rate)
    cst.cost_lifetime = annual_growth_rate * yearly_cost * cst.plant_lifetime

    ###### Levelized Cost Of Electricity ######
    cst.levelized_CoE = (cst.cost_lifetime * 1E6) / (cst.plant_lifetime * 24 * 365 * power_electric_net / 1e3 * cst.availability)

    return actor
end

"""
    _finalize(actor::ActorCostingIFE)

Sort cost systems and subsystems by magnitude (descending) for easy inspection.
"""
function FUSE._finalize(actor::ActorCostingIFE)
    sort!(actor.dd.costing.cost_direct_capital.system; by=x -> x.cost, rev=true)
    for sys in actor.dd.costing.cost_direct_capital.system
        sort!(sys.subsystem; by=x -> x.cost, rev=true)
    end
    return actor
end

#= ========================= =#
#  IFE direct capital costs   #
#= ========================= =#
function cost_direct_capital_IFE(layer::ife_build__layer, da::FUSE.DollarAdjust{T}) where {T<:Real}
    da.year_assessed = 2016
    ltype = layer.type
    if ltype == Int(IMAS._plasma_)
        return zero(T)
    elseif ltype == Int(IMAS._blanket_)
        cost = layer.volume * 0.75
    elseif ltype == Int(IMAS._shield_)
        cost = layer.volume * 0.29
    elseif ltype ∈ (Int(IMAS._wall_), Int(IMAS._vessel_))
        cost = layer.volume * 0.36
    else
        return zero(T)
    end
    return FUSE.future_dollars(cost, da)
end
