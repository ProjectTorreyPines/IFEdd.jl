# ActorIFEBlanket — IFE blanket TBR and neutron wall loading.
#
# Ported from joey_fork/FUSE.jl/src/actors/nuclear/ife_blanket_actor.jl.
# Single-container signature: `dd::dd_ife` (Mode B subset embeds all required
# standard IDS). Dependencies (NNeutronics, Optim, mirror_bound, trapz, the
# build-layer enums) are accessed through FUSE/IMAS namespaces; IFEdd does
# not pull them in directly.

FUSE.@actor_parameters_struct ActorIFEBlanket{T} begin
    blanket_multiplier::FUSE.Entry{T} = FUSE.Entry{T}("-", "Neutron thermal power multiplier in blanket"; default=1.2)
    thermal_power_extraction_efficiency::FUSE.Entry{T} = FUSE.Entry{T}("-",
        "Fraction of thermal power that is carried out by the coolant at the blanket interface";
        default=1.0)
    max_Li6_enrichment_fraction::FUSE.Entry{T} = FUSE.Entry{T}("-", "Maximum allowed Li6 enrichment fraction"; default=0.9)
    verbose::FUSE.Entry{Bool} = FUSE.act_common_parameters(; verbose=false)
end

mutable struct ActorIFEBlanket{D,P} <: FUSE.SingleAbstractActor{D,P}
    dd::dd_ife{D}
    par::FUSE.OverrideParameters{P,FUSEparameters__ActorIFEBlanket{P}}
    function ActorIFEBlanket(dd::dd_ife{D}, par::FUSEparameters__ActorIFEBlanket{P}; kw...) where {D<:Real,P<:Real}
        FUSE.logging_actor_init(ActorIFEBlanket)
        par = FUSE.OverrideParameters(par; kw...)
        return new{D,P}(dd, par)
    end
end

"""
    ActorIFEBlanket(dd::dd_ife, act::FUSE.ParametersAllActors; kw...)

Calculates IFE blanket performance including tritium breeding ratio (TBR),
thermal power, and neutron leakage using 1D neutronics models with spherical
geometry. Optimizes Li-6 enrichment to meet the target TBR in
`dd.requirements.tritium_breeding_ratio`.

Stores data in `dd.blanket` and `dd.neutronics`.
"""
function ActorIFEBlanket(dd::dd_ife, act::FUSE.ParametersAllActors; kw...)
    actor = ActorIFEBlanket(dd, act.ActorIFEBlanket; kw...)
    FUSE.step(actor)
    FUSE.finalize(actor)
    return actor
end

function FUSE._step(actor::ActorIFEBlanket)
    dd = actor.dd
    par = actor.par
    empty!(dd.blanket)

    layers = dd.ife_build.layer

    # find d1 (wall), d2 (blanket), d3 (shield or vessel) by type
    d1_idx = findfirst(l -> !IMASdd.ismissing(l, :type) && l.type == Int(IMAS._wall_), layers)
    d2_idx = findfirst(l -> !IMASdd.ismissing(l, :type) && l.type == Int(IMAS._blanket_), layers)
    d3_idx = findfirst(l -> !IMASdd.ismissing(l, :type) && l.type == Int(IMAS._shield_), layers)
    if d3_idx === nothing
        d3_idx = findfirst(l -> !IMASdd.ismissing(l, :type) && l.type == Int(IMAS._vessel_), layers)
    end

    if d2_idx === nothing
        @warn "No blanket layer found in ife_build for ActorIFEBlanket to do anything"
        return actor
    end

    d1_thickness = (d1_idx !== nothing && !IMASdd.ismissing(layers[d1_idx], :thickness)) ? layers[d1_idx].thickness : 0.0
    d2_thickness = !IMASdd.ismissing(layers[d2_idx], :thickness) ? layers[d2_idx].thickness : 0.0
    d3_thickness = (d3_idx !== nothing && !IMASdd.ismissing(layers[d3_idx], :thickness)) ? layers[d3_idx].thickness : 0.0

    # cycle-averaged neutron power [W]: ∫P_n dt / T_rep over one rep period
    t0 = dd.global_time
    times = dd.core_profiles.time
    neutron_powers = [begin; dd.global_time = t; IMAS.fusion_neutron_power(dd); end for t in times]
    dd.global_time = t0
    total_power_neutrons = FUSE.trapz(times, neutron_powers) / (times[end] - times[1])

    # inner surface area of blanket layer for peak wall flux [W/m²]
    r_in = !IMASdd.ismissing(layers[d2_idx], :start_radius) ? layers[d2_idx].start_radius : nothing
    r_out = !IMASdd.ismissing(layers[d2_idx], :end_radius) ? layers[d2_idx].end_radius : nothing
    if !IMASdd.ismissing(layers[d2_idx], :area)
        wall_area = layers[d2_idx].area
        r_in = r_in !== nothing ? r_in : sqrt(wall_area / (4π))
    elseif r_in !== nothing
        wall_area = 4π * r_in^2
    else
        error("ife_build blanket layer is missing both area and start_radius")
    end
    peak_wall_flux = total_power_neutrons / wall_area  # W/m²

    # spherical geometric scale factor: flux falloff from inner to outer face
    r_out = (r_out !== nothing) ? r_out : r_in + d2_thickness
    flux_geometric_scale = (r_in / r_out)^2

    # single blanket module
    resize!(dd.blanket.module, 1)
    bm = dd.blanket.module[1]
    bm.name = "IFE blanket"

    resize!(bm.layer, 3)
    bm.layer[1].name = (d1_idx !== nothing && !IMASdd.ismissing(layers[d1_idx], :name)) ? layers[d1_idx].name : "wall"
    bm.layer[1].midplane_thickness = d1_thickness
    bm.layer[1].material = (d1_idx !== nothing && !IMASdd.ismissing(layers[d1_idx], :material)) ? layers[d1_idx].material : "vacuum"
    bm.layer[2].name = !IMASdd.ismissing(layers[d2_idx], :name) ? layers[d2_idx].name : "blanket"
    bm.layer[2].midplane_thickness = d2_thickness
    bm.layer[2].material = !IMASdd.ismissing(layers[d2_idx], :material) ? layers[d2_idx].material : "lithium-lead: Li6/7=7.500%"
    bm.layer[3].name = (d3_idx !== nothing && !IMASdd.ismissing(layers[d3_idx], :name)) ? layers[d3_idx].name : "shield"
    bm.layer[3].midplane_thickness = d3_thickness
    bm.layer[3].material = (d3_idx !== nothing && !IMASdd.ismissing(layers[d3_idx], :material)) ? layers[d3_idx].material : "vacuum"

    # power accounting
    bmt = resize!(bm.time_slice)
    bmt.power_incident_neutrons = total_power_neutrons
    bmt.power_incident_radiated = 0.0
    bmt.power_thermal_neutrons = total_power_neutrons * par.blanket_multiplier
    bmt.power_thermal_radiated = 0.0
    bmt.power_thermal_extracted = par.thermal_power_extraction_efficiency * bmt.power_thermal_neutrons

    blanket_model_1d = FUSE.NNeutronics.Blanket()
    energy_grid = FUSE.NNeutronics.energy_grid()

    function target_TBR_ife(Li6::Real, target::Float64=0.0)
        Li6 = FUSE.mirror_bound(abs(Li6), 0.0, 100.0 * par.max_Li6_enrichment_fraction)
        bm.layer[2].material = @sprintf("lithium-lead: Li6/7=%3.3f%%", Li6)
        tbr = FUSE.NNeutronics.TBR(blanket_model_1d, d1_thickness, d2_thickness, d3_thickness, Li6)
        if target === 0.0
            LE = FUSE.NNeutronics.leakeage_energy(blanket_model_1d, d1_thickness, d2_thickness, d3_thickness, Li6, energy_grid)::Vector{Float64}
            bmt.tritium_breeding_ratio = tbr
            bmt.peak_wall_flux = peak_wall_flux
            bmt.peak_escape_flux = sum(LE) * total_power_neutrons * flux_geometric_scale
            IMAS.@ddtime(dd.blanket.tritium_breeding_ratio = tbr)
        else
            return abs((tbr - target) / target) + exp(Li6) / exp(100.0)
        end
    end

    res = FUSE.Optim.optimize(
        x -> target_TBR_ife(x[1], dd.requirements.tritium_breeding_ratio),
        [50.0],
        FUSE.Optim.NelderMead()
    )
    target_TBR_ife(abs(res.minimizer[1]))

    # ---- dd.neutronics ----
    if d1_idx !== nothing && !IMASdd.ismissing(layers[d1_idx], :outline) &&
            !isempty(layers[d1_idx].outline.r) && !isempty(layers[d1_idx].outline.z)
        rwall = layers[d1_idx].outline.r
        zwall = layers[d1_idx].outline.z
    else
        θ = LinRange(0, 2π, 129)
        rwall = r_in .* cos.(θ)
        zwall = r_in .* sin.(θ)
    end

    n = length(rwall)
    wall_s = zeros(n)
    for i in 1:(n - 1)
        wall_s[i] = sqrt((rwall[i+1] - rwall[i])^2 + (zwall[i+1] - zwall[i])^2)
    end
    wall_s[end] = wall_s[1]

    total_arc = sum(wall_s)
    power_per_segment = total_power_neutrons .* wall_s ./ total_arc

    R_wall = sqrt.(rwall .^ 2 .+ zwall .^ 2)
    R_wall[R_wall .== 0] .= eps()
    flux_mag = peak_wall_flux
    flux_r = flux_mag .* rwall ./ R_wall
    flux_z = flux_mag .* zwall ./ R_wall

    dd.neutronics.first_wall.r = rwall
    dd.neutronics.first_wall.z = zwall
    ntt = resize!(dd.neutronics.time_slice)
    ntt.wall_loading.flux_r = flux_r
    ntt.wall_loading.flux_z = flux_z
    ntt.wall_loading.power  = power_per_segment

    if par.verbose
        println(res)
    end

    return actor
end
