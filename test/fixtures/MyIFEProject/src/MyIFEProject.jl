module MyIFEProject

using IMASdd
using IFEdd

# These two files are baked by `IFEdd.generate_user_dd` (driven from
# `deps/build.jl`). They define `my_summary{T} <: IFEdd.AbstractIFESummary{T}`
# and the `MyIFEProject.dd{T} <: IMASdd.DD{T}` container.
include("MyIFEProject_idstypes.jl")
include("MyIFEProject_dd.jl")

end # module
