# Struct emission for `IFEdd.generate_user_dd` — activates as a package extension
# as soon as GenerateDD is loaded alongside IFEdd.
#
# Only baking a customized container needs GenerateDD. `IFEdd.dd()` is built from
# code generated ahead of time and committed, so keeping this dependency weak means
# a plain install of IFEdd never has to fetch GenerateDD, whose repo is private.

module IFEddGenerateDDExt

import IFEdd
import GenerateDD

function IFEdd._emit_raw_structs(workdir::AbstractString, names)
    desired = String[]
    for name in names
        append!(desired, keys(GenerateDD.imas_dd_ids(workdir, name)))
    end
    sort!(unique!(desired))
    return join(GenerateDD.imas_julia_struct(workdir, desired), "\n")
end

end # module
