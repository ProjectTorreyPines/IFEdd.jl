# IFE-specific init parameter groups.
#
# Ported from joey_fork/FUSE.jl/src/parameters/parameters_inits.jl L271-291.
# These are standalone ParametersInit subtypes — IFEdd hosts them so FUSE
# proper stays free of IFE-specific references.

Base.@kwdef mutable struct FUSEparameters__ife_pellet{T} <: FUSE.ParametersInit{T}
    _parent::WeakRef = WeakRef(nothing)
    _name::Symbol = :ife_pellet
    fuel_radius::FUSE.Entry{T} = FUSE.Entry{T}("m", "Total fuel radius (hot spot + DT ice layer)";
        default=100e-6, check=x -> @assert x > 0.0 "must be: fuel_radius > 0.0")
    hotspot_fraction::FUSE.Entry{T} = FUSE.Entry{T}("-", "Fraction of fuel_radius occupied by the hot spot (rpellet = hotspot_fraction * fuel_radius)";
        default=0.3, check=x -> @assert 0.0 < x < 1.0 "must be: 0 < hotspot_fraction < 1")
    ablator_thickness::FUSE.Entry{T} = FUSE.Entry{T}("m", "Thickness of the outer ablator shell";
        default=900e-6, check=x -> @assert x > 0.0 "must be: ablator_thickness > 0.0")
    ablator_material::FUSE.Entry{String} = FUSE.Entry{String}("-", "Ablator material label (e.g. \"CH\", \"Be\", \"HDC\")";
        default="HDC")
    rep_rate::FUSE.Entry{T} = FUSE.Entry{T}("Hz", "Target repetition rate";
        default=10.0, check=x -> @assert x > 0.0 "must be: rep_rate > 0.0")
    Te_core::FUSE.Entry{T} = FUSE.Entry{T}("eV", "Cold initial pellet temperature";
        default=0.05, check=x -> @assert x > 0.0 "must be: Te_core > 0.0")
end

Base.@kwdef mutable struct FUSEparameters__ife_driver{T} <: FUSE.ParametersInit{T}
    _parent::WeakRef = WeakRef(nothing)
    _name::Symbol = :ife_driver
    n_drivers::FUSE.Entry{Int} = FUSE.Entry{Int}("-", "Number of driver beams (total energy split equally among them)";
        default=1, check=x -> @assert x >= 1 "must be: n_drivers >= 1")
    energy::FUSE.Entry{T} = FUSE.Entry{T}("J", "Total driver energy per pulse delivered to target";
        default=1.8e6, check=x -> @assert x > 0.0 "must be: energy > 0.0")
    wavelength::FUSE.Entry{T} = FUSE.Entry{T}("m", "Driver wavelength (e.g. 351e-9 for UV laser)";
        default=351e-9, check=x -> @assert x > 0.0 "must be: wavelength > 0.0")
    pulse_length::FUSE.Entry{T} = FUSE.Entry{T}("s", "Driver pulse duration";
        default=10e-9, check=x -> @assert x > 0.0 "must be: pulse_length > 0.0")
    efficiency_conversion::FUSE.Entry{T} = FUSE.Entry{T}("-", "Wall-plug to driver efficiency";
        default=0.10, check=x -> @assert 0.0 < x <= 1.0 "must be: 0.0 < efficiency_conversion <= 1.0")
    efficiency_coupling::FUSE.Entry{T} = FUSE.Entry{T}("-", "Driver to target coupling efficiency";
        default=0.85, check=x -> @assert 0.0 < x <= 1.0 "must be: 0.0 < efficiency_coupling <= 1.0")
end
