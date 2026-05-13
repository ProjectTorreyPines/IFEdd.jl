# IFEParametersActors — IFE-flavored version of `FUSE.ParametersActors`.
#
# FUSE.ParametersActors uses `@insert_subtype_members FUSE.ParametersActor`
# which enumerates all `FUSE.ParametersActor` subtypes at struct definition
# time. Because IFEdd is loaded *after* FUSE, IFE-specific actor parameter
# structs (FUSEparameters__ActorIFE*) become visible to that macro only when
# it's re-invoked from inside IFEdd. So we re-define the container locally.
#
# Resulting struct has the same field set as FUSE.ParametersActors *plus*
# any FUSE.ParametersActor subtype that IFEdd defines before this file is
# included — i.e. the IFE actors. `act::FUSE.ParametersAllActors` dispatches
# in FUSE accept this subtype transparently.

mutable struct IFEParametersActors{T<:Real} <: FUSE.ParametersAllActors{T}
    _parent::WeakRef
    _name::Symbol
    FUSE.@insert_subtype_members FUSE.ParametersActor
end

function IFEParametersActors{T}() where {T<:Real}
    act = IFEParametersActors{T}(
        WeakRef(nothing),
        :act,
        (FUSE.@insert_constructor_members FUSE.ParametersActor)...
    )
    FUSE.setup_parameters!(act)
    return act
end

IFEParametersActors() = IFEParametersActors{Float64}()
