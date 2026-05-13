# IFE-specific extract functions.
#
# Ported from joey_fork/IMAS.jl/src/extract/extract_ife.jl. In joey's monolithic
# fork, IMAS.dd held both standard IDS and IFE IDS, so all extract functions
# took a single `dd::IMAS.dd`. Here IFE data lives in `dd_ife` (this package)
# while standard IDS stays in `IMAS.dd`, so cross-container functions need two
# arguments: `f(dd::IMAS.dd, ife::dd_ife)`.
#
# Status:
#   - IFE-only functions (e.g. `ife_duty_cycle`) are fully active.
#   - Cross-container functions (`extract_ife`, `IFEExtractFunctionsLibrary`)
#     are scaffolded; the ExtractFunction registry is left as a TODO until the
#     two-container ExtractFunction signature is decided.

using OrderedCollections: OrderedDict

"""
    ife_duty_cycle(ife::dd_ife) -> Float64

Return the IFE duty cycle `τ_pulse / T_rep` from `ife.ife_driver`.
Returns `NaN` if the driver is not populated.
"""
function ife_duty_cycle(ife::dd_ife)
    isempty(ife.ife_driver.beam) && return NaN
    isempty(ife.ife_driver.time) && return NaN
    tau = ife.ife_driver.beam[1].pulse_length    # s
    T_rep = ife.ife_driver.time[end]             # s
    return tau / T_rep
end

"""
    extract_ife(dd::IMAS.dd, ife::dd_ife)

Extract key scalar quantities for an IFE case.

Power quantities (fusion, neutron, alpha, wall flux) are duty-cycle-averaged:
`<P> = P_peak × (τ_pulse / T_rep)`.

# Groups (joey reference, to be ported)
- `:driver`      — laser/driver beam parameters         (ife.ife_driver)
- `:target`      — pellet geometry and repetition rate  (dd.pellets)
- `:plasma_peak` — hot-state plasma quantities          (dd.core_profiles)
- `:power_avg`   — duty-cycle-averaged power, Q         (mixed)
- `:neutronics`  — TBR, cycle-averaged peak wall flux   (dd.blanket, dd.neutronics)
- `:bop`         — balance-of-plant electric output     (dd.balance_of_plant)
- `:costing`     — capital cost, levelized CoE          (dd.costing)

# Status
TODO: port `IFEExtractFunctionsLibrary` from joey once the two-container
`ExtractFunction` signature is decided (single-arg `dd ->` closures need to
become two-arg `(dd, ife) ->` or close over `ife` at registration time).
"""
function extract_ife(dd::IMAS.dd, ife::dd_ife)
    # TODO: populate via IFEExtractFunctionsLibrary (see reference block below).
    # Skeleton: emit only the IFE-only entries that can be computed without
    # touching standard IDS; standard-IDS-dependent entries will land here as
    # the registry is ported.
    out = OrderedDict{Symbol,Any}()
    out[:duty_cycle] = ife_duty_cycle(ife)
    out[:global_time] = dd.global_time
    return out
end

# Reference: joey_fork/IMAS.jl/src/extract/extract_ife.jl L22-L99
# IFEExtractFunctionsLibrary registration. To be ported in the next step.
#
#     const IFEExtractFunctionsLibrary = OrderedDict{Symbol,IMAS.ExtractFunction}()
#     function update_IFEExtractFunctionsLibrary!()
#         # --- driver --- (IFE-only, can use `ife` directly)
#         # EF(:driver, :E_driver, "MJ", (dd,ife) -> sum(b.energy for b in ife.ife_driver.beam)/1e6)
#         # ...
#         # --- target --- (uses dd.pellets, dd is IMAS.dd)
#         # EF(:target, :R_target, "mm", (dd,ife) -> dd.pellets.launcher[1].shape.size[1]*1e3)
#         # ...
#         # --- plasma_peak --- (uses dd.core_profiles, IMAS.fusion_power(dd))
#         # --- power_avg ---   (mixed: ife_duty_cycle(ife) * IMAS.fusion_power(dd))
#         # --- neutronics ---  (dd.blanket, dd.neutronics)
#         # --- bop ---         (dd.balance_of_plant)
#         # --- costing ---     (dd.costing)
#     end
