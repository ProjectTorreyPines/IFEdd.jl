# IFEParametersInits — IFE-flavored version of `FUSE.ParametersInits`.
#
# joey_fork added `ife_pellet` and `ife_driver` fields directly to FUSE's
# `ParametersInits` struct. Since IFEdd can't extend a sealed struct from the
# outside, we mirror the standard field list and append the two IFE groups.
#
# Dispatches on `FUSE.ParametersAllActors`/`FUSE.ParametersAllInits` abstract
# types throughout FUSE accept this subtype transparently — verified by
# `case_parameters` accepting `act::FUSE.ParametersAllActors` etc.
#
# Maintenance note: if FUSE upstream adds/removes a field from `ParametersInits`,
# this struct + constructor must be re-synced. Tests below should catch any
# mismatch (e.g. via `propertynames`).

mutable struct IFEParametersInits{T<:Real} <: FUSE.ParametersAllInits{T}
    _parent::WeakRef
    _name::Symbol
    # FUSE.ParametersInits standard groups (mirrored from FUSE.jl)
    general::FUSE.FUSEparameters__general{T}
    time::FUSE.FUSEparameters__time{T}
    ods::FUSE.FUSEparameters__ods{T}
    equilibrium::FUSE.FUSEparameters__equilibrium{T}
    core_profiles::FUSE.FUSEparameters__core_profiles{T}
    pf_active::FUSE.FUSEparameters__pf_active{T}
    rampup::FUSE.FUSEparameters__rampup{T}
    nb_unit::FUSE.ParametersVector{FUSE.FUSEparameters__nb_unit{T}}
    ec_launcher::FUSE.ParametersVector{FUSE.FUSEparameters__ec_launcher{T}}
    pellet_launcher::FUSE.ParametersVector{FUSE.FUSEparameters__pellet_launcher{T}}
    ic_antenna::FUSE.ParametersVector{FUSE.FUSEparameters__ic_antenna{T}}
    lh_antenna::FUSE.ParametersVector{FUSE.FUSEparameters__lh_antenna{T}}
    hcd::FUSE.FUSEparameters__hcd{T}
    build::FUSE.FUSEparameters__build{T}
    center_stack::FUSE.FUSEparameters__center_stack{T}
    tf::FUSE.FUSEparameters__tf{T}
    oh::FUSE.FUSEparameters__oh{T}
    bop::FUSE.FUSEparameters__balance_of_plant{T}
    requirements::FUSE.FUSEparameters__requirements{T}
    # IFE-specific groups
    ife_pellet::FUSEparameters__ife_pellet{T}
    ife_driver::FUSEparameters__ife_driver{T}
end

function IFEParametersInits{T}() where {T<:Real}
    ini = IFEParametersInits{T}(
        WeakRef(nothing),
        :ini,
        FUSE.FUSEparameters__general{T}(),
        FUSE.FUSEparameters__time{T}(),
        FUSE.FUSEparameters__ods{T}(),
        FUSE.FUSEparameters__equilibrium{T}(),
        FUSE.FUSEparameters__core_profiles{T}(),
        FUSE.FUSEparameters__pf_active{T}(),
        FUSE.FUSEparameters__rampup{T}(),
        FUSE.ParametersVector{FUSE.FUSEparameters__nb_unit{T}}(),
        FUSE.ParametersVector{FUSE.FUSEparameters__ec_launcher{T}}(),
        FUSE.ParametersVector{FUSE.FUSEparameters__pellet_launcher{T}}(),
        FUSE.ParametersVector{FUSE.FUSEparameters__ic_antenna{T}}(),
        FUSE.ParametersVector{FUSE.FUSEparameters__lh_antenna{T}}(),
        FUSE.FUSEparameters__hcd{T}(),
        FUSE.FUSEparameters__build{T}(),
        FUSE.FUSEparameters__center_stack{T}(),
        FUSE.FUSEparameters__tf{T}(),
        FUSE.FUSEparameters__oh{T}(),
        FUSE.FUSEparameters__balance_of_plant{T}(),
        FUSE.FUSEparameters__requirements{T}(),
        FUSEparameters__ife_pellet{T}(),
        FUSEparameters__ife_driver{T}(),
    )
    FUSE.setup_parameters!(ini)
    return ini
end

IFEParametersInits() = IFEParametersInits{Float64}()
