# IFE case + initialization.
#
# Ported from joey_fork/FUSE.jl/src/cases/IFE.jl.
# Two entry points exposed to the workflow:
#   * `FUSE.case_parameters(::Val{:IFE}; kw...)` — returns (ini, act)
#   * `init_ife!(dd, ini, act; layers_spec=nothing)` — populates dd

"""
    FUSE.case_parameters(::Val{:IFE}; kw...)

IFE (Inertial Fusion Energy) demo case. Returns `(ini, act)` of types
`IFEParametersInits` and `IFEParametersActors` respectively. Keyword
arguments map to `ini.ife_pellet` / `ini.ife_driver` fields plus
`ini.core_profiles.ngrid`.
"""
function FUSE.case_parameters(
    ::Val{:IFE};
    fuel_radius::Float64=100e-6,
    hotspot_fraction::Float64=0.3,
    ablator_thickness::Float64=900e-6,
    ablator_material::String="HDC",
    rep_rate::Float64=10.0,
    Te_core::Float64=0.05,
    n_drivers::Int=1,
    driver_energy::Float64=1.8e6,
    driver_wavelength::Float64=351e-9,
    driver_pulse_length::Float64=10e-9,
    driver_efficiency_conversion::Float64=0.10,
    driver_efficiency_coupling::Float64=0.85,
    tritium_breeding_ratio::Float64=1.05,
    ngrid::Int=101)

    ini = IFEParametersInits()
    act = IFEParametersActors()

    ini.general.casename = "IFE_demo"
    ini.general.init_from = :scalars

    ini.ife_pellet.fuel_radius = fuel_radius
    ini.ife_pellet.hotspot_fraction = hotspot_fraction
    ini.ife_pellet.ablator_thickness = ablator_thickness
    ini.ife_pellet.ablator_material = ablator_material
    ini.ife_pellet.rep_rate = rep_rate
    ini.ife_pellet.Te_core = Te_core

    ini.ife_driver.n_drivers = n_drivers
    ini.ife_driver.energy = driver_energy
    ini.ife_driver.wavelength = driver_wavelength
    ini.ife_driver.pulse_length = driver_pulse_length
    ini.ife_driver.efficiency_conversion = driver_efficiency_conversion
    ini.ife_driver.efficiency_coupling = driver_efficiency_coupling

    ini.requirements.tritium_breeding_ratio = tritium_breeding_ratio

    ini.core_profiles.ngrid = ngrid

    act.ActorPowerNeeds.model = :IFE

    return ini, act
end

"""
    init_ife!(dd::dd_ife, ini, act; layers_spec=nothing)

Initialize `dd` for a simple spherically-symmetric IFE demo case from `ini`
parameters. Populates `dd.ife_build`, `dd.pellets`, `dd.ife_driver`,
`dd.core_profiles`, and `dd.core_sources`; then calls FUSE's standard
`init_balance_of_plant!` and `init_requirements!`.

Pass `layers_spec` as a vector of NamedTuples `(name, type, thickness, material)`
to override the default radial build.
"""
function init_ife!(dd::dd_ife, ini::FUSE.ParametersAllInits, act::FUSE.ParametersAllActors; layers_spec=nothing)
    p = ini.ife_pellet
    d = ini.ife_driver
    ngrid = ini.core_profiles.ngrid

    if layers_spec === nothing
        layers_spec = [
            (name="chamber", type=Int(IMAS._plasma_), thickness=2.0, material="vacuum"),
            (name="wall", type=Int(IMAS._wall_), thickness=0.05, material="tungsten"),
            (name="blanket", type=Int(IMAS._blanket_), thickness=0.60, material="FLiBe"),
            (name="shield", type=Int(IMAS._shield_), thickness=0.30, material="steel"),
            (name="vessel", type=Int(IMAS._vessel_), thickness=0.10, material="steel")
        ]
    end

    # ---- ife_build ----
    resize!(dd.ife_build.layer, length(layers_spec))
    r = 0.0
    for (k, spec) in enumerate(layers_spec)
        l = dd.ife_build.layer[k]
        l.name = spec.name
        l.type = spec.type
        l.material = spec.material
        l.thickness = spec.thickness
        l.start_radius = r
        r += spec.thickness
        l.end_radius = r
        l.area = 4π * l.start_radius^2
        l.volume = (4π / 3) * (l.end_radius^3 - l.start_radius^3)
        θ = LinRange(0, 2π, 129)
        l.outline.r = l.end_radius .* cos.(θ)
        l.outline.z = l.end_radius .* sin.(θ)
    end

    # ---- pellets ----
    launcher, = resize!(dd.pellets.launcher, 1)
    launcher.name = "IFE target"
    launcher.shape.type.index = 1
    launcher.shape.type.name = "spherical"
    rpellet              = p.fuel_radius * p.hotspot_fraction
    fuel_layer_thickness = p.fuel_radius * (1.0 - p.hotspot_fraction)
    r_pellet_outer       = p.fuel_radius + p.ablator_thickness
    launcher.shape.size  = [r_pellet_outer]

    d_species, t_species = resize!(launcher.species, 2)
    d_species.label = "D";  d_species.z_n = 1.0;  d_species.a = 2.0
    t_species.label = "T";  t_species.z_n = 1.0;  t_species.a = 3.0

    dd.pellets.time = [0.0]
    pts = resize!(dd.pellets.time_slice)
    pellet, = resize!(pts.pellet, 1)
    pellet.frequency = p.rep_rate

    hotspot_layer, dt_layer, ablator_layer = resize!(pellet.layer, 3)

    hotspot_layer.thickness = rpellet
    hs_spec, = resize!(hotspot_layer.species, 1)
    hs_spec.label = "DT hotspot"
    hs_spec.fraction = 1.0

    dt_layer.thickness = fuel_layer_thickness
    d_spec, t_spec = resize!(dt_layer.species, 2)
    d_spec.label = "D";  d_spec.z_n = 1.0;  d_spec.a = 2.0;  d_spec.fraction = 0.5
    t_spec.label = "T";  t_spec.z_n = 1.0;  t_spec.a = 3.0;  t_spec.fraction = 0.5

    ablator_layer.thickness = p.ablator_thickness
    abl_spec, = resize!(ablator_layer.species, 1)
    abl_spec.label = p.ablator_material
    abl_spec.fraction = 1.0

    # ---- ife_driver ----
    tau      = d.pulse_length
    T_rep    = 1.0 / p.rep_rate
    dd.ife_driver.time = [0.0, nextfloat(0.0), tau, nextfloat(tau), T_rep]

    resize!(dd.ife_driver.beam, d.n_drivers)
    energy_per_beam = d.energy / d.n_drivers
    P_peak = energy_per_beam / tau
    for k in 1:d.n_drivers
        beam = dd.ife_driver.beam[k]
        beam.name = d.n_drivers == 1 ? "IFE driver" : "IFE driver $k"
        beam.wavelength = d.wavelength
        beam.energy = energy_per_beam
        beam.pulse_length = d.pulse_length
        beam.power_launched = [0.0, P_peak, P_peak, 0.0, 0.0]
        beam.efficiency.conversion = d.efficiency_conversion
        beam.efficiency.coupling = d.efficiency_coupling
    end

    # ---- core_profiles ----
    dd.global_time = 0.0
    dd.core_profiles.time = [0.0]

    cp1d = resize!(dd.core_profiles.profiles_1d)
    rad = collect(range(0.0, 1.0, ngrid))
    cp1d.grid.rho_tor_norm = rad
    cp1d.grid.volume = @. (4π / 3) * (rad * rpellet)^3
    cp1d.grid.area   = @. 4π * (rad * rpellet)^2

    m_u       = 1.66054e-27   # kg per atomic mass unit
    rho_DT    = 213.0         # kg/m³, cryogenic liquid DT
    R_f_out   = p.fuel_radius
    m_fuel    = rho_DT * (4π / 3) * (R_f_out^3 - rpellet^3)
    ne_core   = m_fuel / (2.5 * m_u * (4π / 3) * rpellet^3)

    cp1d.electrons.density_thermal = @. ne_core * (1 - rad^2) + 1e-3 * ne_core
    cp1d.electrons.temperature     = @. p.Te_core * (1 - rad^2) + 1e-3 * p.Te_core

    bulk_ion, = resize!(cp1d.ion, 1)
    IMAS.ion_element!(bulk_ion, :DT)
    bulk_ion.density_thermal = cp1d.electrons.density_thermal ./ 2
    bulk_ion.temperature     = cp1d.electrons.temperature

    cp1d.zeff = ones(ngrid)

    # ---- fusion sources (cold state at t=0) ----
    IMAS.fusion_source!(dd.core_sources, dd.core_profiles)

    # ---- create remaining time slices in chronological order ----
    for t in [nextfloat(0.0), tau, nextfloat(tau), T_rep]
        IMAS.new_timeslice!(dd.core_profiles, t)
        IMAS.new_timeslice!(dd.core_sources, t)
    end
    dd.global_time = tau

    # ---- balance of plant + requirements (FUSE standard, with Phase 3a IMAS.DD relaxation) ----
    FUSE.init_balance_of_plant!(dd, ini, act)
    FUSE.init_requirements!(dd, ini, act)

    # ---- costing baseline fields (normally set by FUSE.ActorCosting, but
    #      ActorCostingIFE bypasses that actor — copy the defaults from act).
    #      `act.ActorCosting.*` are Measurement{Float64}; dd_ife{Float64}.costing
    #      fields are plain Float64, so extract the nominal `.val` component. ----
    dd.costing.construction_start_year = act.ActorCosting.construction_start_year.val
    dd.costing.future.inflation_rate   = act.ActorCosting.future_inflation_rate.val
    dd.costing.plant_lifetime          = act.ActorCosting.plant_lifetime.val
    dd.costing.availability            = act.ActorCosting.availability.val

    return dd
end
