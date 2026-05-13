# ActorIFETransport — 0-D IFE transport (Trickey et al. 2024 gain model).
#
# Ported from joey_fork/FUSE.jl/src/actors/transport/ife_transport_actor.jl.
# Sole adaptation: signature dispatches on `dd_ife` instead of `IMAS.dd`.
# The `dd_ife` container embeds `core_profiles`, `core_sources`, `pellets`,
# and the IFE-specific `ife_driver` — all that this actor reads/writes.

FUSE.@actor_parameters_struct ActorIFETransport{T} begin
    adiabat::FUSE.Entry{T} = FUSE.Entry{T}("-", "Adiabat of the compressed shell"; default=2.5)
    verbose::FUSE.Entry{Bool} = FUSE.act_common_parameters(; verbose=false)
end

mutable struct ActorIFETransport{D,P} <: FUSE.SingleAbstractActor{D,P}
    dd::dd_ife{D}
    par::FUSE.OverrideParameters{P,FUSEparameters__ActorIFETransport{P}}
    function ActorIFETransport(dd::dd_ife{D}, par::FUSEparameters__ActorIFETransport{P}; kw...) where {D<:Real,P<:Real}
        FUSE.logging_actor_init(ActorIFETransport)
        par = FUSE.OverrideParameters(par; kw...)
        return new{D,P}(dd, par)
    end
end

"""
    ActorIFETransport(dd::dd_ife, act::FUSE.ParametersAllActors; kw...)

Fills `dd.core_profiles` with a time history that mirrors the `dd.ife_driver`
pulse trace. Hot temperature scale found via bisection so the profile-integrated
fusion power matches the 0-D gain model (Trickey et al. 2024).

Stores data in `dd.core_profiles` and `dd.core_sources`.
"""
function ActorIFETransport(dd::dd_ife, act::FUSE.ParametersAllActors; kw...)
    actor = ActorIFETransport(dd, act.ActorIFETransport; kw...)
    FUSE.step(actor)
    FUSE.finalize(actor)
    return actor
end

function FUSE._step(actor::ActorIFETransport)
    dd = actor.dd
    par = actor.par

    # --- read driver inputs ---
    isempty(dd.ife_driver.beam) && return actor
    beam = dd.ife_driver.beam[1]
    (IMASdd.ismissing(beam, :energy) || IMASdd.ismissing(beam, :pulse_length)) && return actor
    E_laser = sum(b.energy for b in dd.ife_driver.beam)  # total J per shot (all beams)
    tau = beam.pulse_length                               # s (same for all beams)

    # --- read target radius ---
    isempty(dd.pellets.launcher) && return actor
    launcher = dd.pellets.launcher[1]
    (IMASdd.ismissing(launcher.shape, :size) || isempty(launcher.shape.size)) && return actor
    R = launcher.shape.size[1]  # m

    # --- 0-D gain model (Trickey et al. 2024) ---
    I_SI  = E_laser / (tau * π * R^2)       # W/m²
    I_15  = I_SI / 1e19                      # 10^15 W/cm²  (paper units)
    E_MJ  = E_laser / 1e6                    # MJ            (paper units)
    α     = par.adiabat

    # ablation pressure, Eq. 14: pa(Mbar) = 238 * I_15^0.72
    P_abl = 238 * I_15^0.72 * 1e11          # Pa
    pa    = P_abl / 1e13                     # 100 Mbar      (paper units)

    # implosion velocity
    v_imp = 350e3 * sqrt(P_abl / (200e11)) / sqrt(α)   # m/s
    v     = v_imp / 3e5                      # 300 km/s      (paper units)

    # areal density, Eq. 21
    rhoR_val = 1.85 * E_MJ^0.33 * pa^0.41 * I_15^(-0.33) * v^0.16 * α^(-0.55)  # g/cm²

    # burn fraction
    fb = rhoR_val / (rhoR_val + 6.67)

    # gain, Eq. 36
    G = 340 * E_MJ^0.33 * pa^0.83 * I_15^(-1.33) * α^(-0.36) / ((rhoR_val + 6.67) * v^1.07)

    # Instantaneous fusion power during the laser pulse
    P_fus_target = G * E_laser / tau    # W

    # --- ensure core_profiles has a slice for every ife_driver time point ---
    driver_times = dd.ife_driver.time
    for t in driver_times
        if !(t in dd.core_profiles.time)
            IMAS.new_timeslice!(dd.core_profiles, t)
            IMAS.new_timeslice!(dd.core_sources, t)
        end
    end

    # --- cold base profiles from the first (initial) time slice ---
    cp1d_init  = dd.core_profiles.profiles_1d[dd.core_profiles.time[1]]
    Te_cold    = copy(cp1d_init.electrons.temperature)
    Ti_cold    = [copy(ion.temperature) for ion in cp1d_init.ion]
    ne_cold    = copy(cp1d_init.electrons.density_thermal)
    ni_cold    = [copy(ion.density_thermal) for ion in cp1d_init.ion]
    V_cold     = copy(cp1d_init.grid.volume)
    A_cold     = copy(cp1d_init.grid.area)

    # --- compressed fuel sphere radius from areal density + mass conservation ---
    R_c = R  # fallback
    pellet_obj = dd.pellets.time_slice[].pellet[1]
    if length(pellet_obj.layer) >= 3 &&
            !IMASdd.ismissing(pellet_obj.layer[1], :thickness) &&
            !IMASdd.ismissing(pellet_obj.layer[2], :thickness) &&
            !IMASdd.ismissing(pellet_obj.layer[3], :thickness)
        R_hotspot    = pellet_obj.layer[1].thickness
        t_fuel       = pellet_obj.layer[2].thickness
        R_fuel_inner = R_hotspot
        R_fuel_outer = R_hotspot + t_fuel
        rho_DT   = 213.0
        m_fuel   = rho_DT * (4π / 3) * (R_fuel_outer^3 - R_fuel_inner^3)
        rhoR_SI  = rhoR_val * 10.0
        R_c = sqrt(3.0 * m_fuel / (4π * rhoR_SI))
    end
    rho_tor = cp1d_init.grid.rho_tor_norm
    V_hot = @. (4π / 3) * (rho_tor * R_c)^3
    A_hot = @. 4π * (rho_tor * R_c)^2

    density_scale = V_cold[end] / V_hot[end]
    ne_hot = ne_cold .* density_scale
    ni_hot = [ni_cold[k] .* density_scale for k in eachindex(ni_cold)]

    # --- bisect on the first laser-on slice to find the hot temperature scale ---
    i_on = findfirst(i -> sum(b.power_launched[i] for b in dd.ife_driver.beam) > 0,
                     eachindex(driver_times))
    isnothing(i_on) && return actor

    t_on = driver_times[i_on]
    dd.global_time = t_on
    cp1d_work = dd.core_profiles.profiles_1d[t_on]

    cp1d_work.electrons.density_thermal = ne_hot
    cp1d_work.grid.volume = V_hot
    cp1d_work.grid.area   = A_hot
    for (k, ion) in enumerate(cp1d_work.ion)
        ion.density_thermal = ni_hot[k]
    end

    function set_scale!(α)
        cp1d_work.electrons.temperature = Te_cold .* α
        for (k, ion) in enumerate(cp1d_work.ion)
            ion.temperature = Ti_cold[k] .* α
        end
    end

    function P_fus_at_scale(α)
        set_scale!(α)
        IMAS.fusion_source!(dd.core_sources, dd.core_profiles)
        return IMAS.fusion_power(dd)
    end

    α_lo, α_hi = 0.0, 1.0
    P_hi = P_fus_at_scale(α_hi)
    P_hi_prev = P_hi
    for _ in 1:200
        P_hi >= P_fus_target && break
        α_hi *= 2.0
        P_hi = P_fus_at_scale(α_hi)
        (isnan(P_hi) || P_hi < P_hi_prev) && (α_hi /= 2.0; P_hi = P_hi_prev; break)
        P_hi_prev = P_hi
    end
    if P_hi < P_fus_target
        @warn "ActorIFETransport: target fusion power $(round(P_fus_target/1e6; digits=1)) MW unreachable via temperature scaling alone (max: $(round(P_hi/1e6; digits=3)) MW). Profiles set to maximum achievable."
        α_hi /= 2.0
    else
        for _ in 1:60
            α_mid = (α_lo + α_hi) / 2
            (α_hi - α_lo) / α_hi < 1e-6 && break
            P_fus_at_scale(α_mid) < P_fus_target ? (α_lo = α_mid) : (α_hi = α_mid)
        end
    end
    α_final = (α_lo + α_hi) / 2
    Te_hot = Te_cold .* α_final
    Ti_hot = [Ti_cold[k] .* α_final for k in eachindex(Ti_cold)]

    # --- fill every time slice: hot when laser is on, cold otherwise ---
    t_last_on = t_on
    for (i, t) in enumerate(driver_times)
        P_laser = sum(b.power_launched[i] for b in dd.ife_driver.beam)
        dd.global_time = t
        cp1d = dd.core_profiles.profiles_1d[t]
        if P_laser > 0
            cp1d.electrons.temperature    = Te_hot
            cp1d.electrons.density_thermal = ne_hot
            for (k, ion) in enumerate(cp1d.ion)
                ion.temperature    = Ti_hot[k]
                ion.density_thermal = ni_hot[k]
            end
            cp1d.grid.volume = V_hot
            cp1d.grid.area   = A_hot
            t_last_on = t
        else
            cp1d.electrons.temperature    = Te_cold
            cp1d.electrons.density_thermal = ne_cold
            for (k, ion) in enumerate(cp1d.ion)
                ion.temperature    = Ti_cold[k]
                ion.density_thermal = ni_cold[k]
            end
            cp1d.grid.volume = V_cold
            cp1d.grid.area   = A_cold
        end
        IMAS.fusion_source!(dd.core_sources, dd.core_profiles)
    end

    dd.global_time = t_last_on

    if par.verbose
        P_fus_final = IMAS.fusion_power(dd)
        @info "ActorIFETransport: I=$(round(I_15; digits=2))×10¹⁵ W/cm², pa=$(round(P_abl/1e11; digits=1)) Mbar, v=$(round(v_imp/1e3; digits=0)) km/s, ρR=$(round(rhoR_val; digits=2)) g/cm², fb=$(round(fb; digits=3)), G=$(round(G; digits=1)), P_fus_target=$(round(P_fus_target/1e6; digits=1)) MW, T_scale=$(round(α_final; digits=4)), P_fus=$(round(P_fus_final/1e6; digits=1)) MW"
    end

    return actor
end
