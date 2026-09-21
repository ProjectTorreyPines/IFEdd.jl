# Plots.jl recipes for IFE-owned IDS — activates as a package extension as soon
# as Plots is loaded alongside IFEdd.
#
# Everything here reads the IFE schema and draws geometry; nothing calls into
# physics. That is why the recipes can live next to the data dictionary they
# visualize instead of in IFE, and why `Plots` is the extension's only trigger.
#
# `HelpPlots` is a hard dependency of IFEdd, so `recipe_dispatch` and
# `assert_type_and_record_argument` are always available and IFE plots follow
# the same self-documenting convention as the rest of the IMAS stack.

module IFEddPlotsExt

using IFEdd
using IMASdd
using HelpPlots
using Plots  # provides @recipe, @series (re-exports RecipesBase)

#= ============== =#
#  recipe_dispatch  #
#= ============== =#
# Report IDS paths ("build", "driver", "build.layer") rather than raw type
# names in `help_plot` output. Dispatching on IFEdd-owned abstracts keeps these
# methods off IMASdd's types, so they never collide with IMAS's own
# `recipe_dispatch(::IMASdd.IDS)` — and, being more specific, they win when both
# packages are loaded.
HelpPlots.recipe_dispatch(arg::IFEdd.AbstractIFEDD) = IMASdd.ulocation(arg)
HelpPlots.recipe_dispatch(arg::IFEdd.AbstractIFEBuild) = IMASdd.ulocation(arg)
HelpPlots.recipe_dispatch(arg::IFEdd.AbstractIFEDriver) = IMASdd.ulocation(arg)
HelpPlots.recipe_dispatch(arg::AbstractVector{<:IFEdd.AbstractIFEBuildLayer}) = IMASdd.ulocation(arg)

#= ================ =#
#  build layer types  #
#= ================ =#
# Layer type codes are fixed by the IFEdd schema itself — see
# `build.layer[:].type` in `data_dictionary/data_structures_extra/build.json`.
# The values coincide with IMAS's `BuildLayerType` enum so the two stacks stay
# interchangeable, but declaring them here means plotting needs nothing from
# IMAS, which in turn keeps `Plots` the extension's single trigger.
const LAYER_PLASMA = -1
const LAYER_GAP = 0
const LAYER_SHIELD = 3
const LAYER_BLANKET = 4
const LAYER_WALL = 5
const LAYER_VESSEL = 6
const LAYER_CRYOSTAT = 7

"""
    layer_attrs(l::IFEdd.AbstractIFEBuildLayer) -> (name, color)

Display label and fill color for one build layer. Gaps are drawn but never
labelled, so the legend lists materials rather than voids.
"""
function layer_attrs(l::IFEdd.AbstractIFEBuildLayer)
    name = IMASdd.ismissing(l, :name) ? "" : l.name
    color = :gray
    if !IMASdd.ismissing(l, :type)
        t = l.type
        if t == LAYER_PLASMA
            color = :white
        elseif t == LAYER_GAP
            name = ""
            color = :white
        elseif t == LAYER_SHIELD
            color = :red
        elseif t == LAYER_BLANKET
            color = :orange
        elseif t == LAYER_WALL
            color = :yellow
        elseif t == LAYER_VESSEL
            color = :lightyellow
        elseif t == LAYER_CRYOSTAT
            color = :lightgray
        end
    end
    return name, color
end

#= ===== =#
#  build  #
#= ===== =#
@recipe function plot_build(bd::IFEdd.AbstractIFEBuild; cx=true)
    id = HelpPlots.recipe_dispatch(bd)
    HelpPlots.assert_type_and_record_argument(id, Bool, "Plot cross section"; cx)

    legend_position --> :outerbottomright
    aspect_ratio := :equal
    grid --> :none

    @series begin
        cx := cx
        bd.layer
    end
end

@recipe function plot_build_layers(layers::AbstractVector{<:IFEdd.AbstractIFEBuildLayer}; cx=true)
    id = HelpPlots.recipe_dispatch(layers)
    HelpPlots.assert_type_and_record_argument(id, Bool, "Plot cross section"; cx)

    legend_position --> :outerbottomright
    grid --> :none

    base_linewidth = get(plotattributes, :linewidth, 1.0)

    if cx && !isempty(layers)
        aspect_ratio := :equal

        rmax = maximum(l.end_radius for l in layers if !IMASdd.ismissing(l, :end_radius); init=1.0)
        lim = rmax * 1.05
        xlim --> [-lim, lim]
        ylim --> [-lim, lim]

        ϕ = range(0, 2π, 361)

        # Draw outermost to innermost so each inner layer overdraws the center
        # of the outer. Labels appear once per name.
        seen_labels = Set{String}()
        for layer in Iterators.reverse(layers)
            IMASdd.ismissing(layer, :end_radius) && continue
            name, color = layer_attrs(layer)
            r_out = layer.end_radius
            r_circ = r_out .* cos.(ϕ)
            z_circ = r_out .* sin.(ϕ)

            show_label = !isempty(name) && name ∉ seen_labels
            show_label && push!(seen_labels, name)
            @series begin
                seriestype --> :shape
                linewidth := 0.5 * base_linewidth
                linecolor --> :black
                color --> color
                label --> (show_label ? uppercasefirst(name) : "")
                r_circ, z_circ
            end
        end

    else  # radial bar chart
        at = 0.0
        seen_labels = Set{String}()
        for layer in layers
            IMASdd.ismissing(layer, :thickness) && continue
            name, color = layer_attrs(layer)
            show_label = !isempty(name) && name ∉ seen_labels
            show_label && push!(seen_labels, name)
            @series begin
                seriestype --> :vspan
                label --> (show_label ? uppercasefirst(name) : "")
                color --> color
                alpha --> 0.3
                [at, at + layer.thickness]
            end
            at += layer.thickness
            @series begin
                seriestype --> :vline
                linewidth := 0.5 * base_linewidth
                label --> ""
                color --> :black
                [at]
            end
        end
    end
end

#= ====== =#
#  driver  #
#= ====== =#
@recipe function plot_driver(drv::IFEdd.AbstractIFEDriver)
    # Guard with `if`, never an early `return`: inside a `@recipe` body a bare
    # `return` does not stop the `@series` blocks below it from being emitted,
    # so an empty driver would silently plot a bar chart of zeros.
    if !isempty(drv.beam)
        P_wall = 0.0
        P_launched = 0.0
        P_absorbed = 0.0
        for beam in drv.beam
            pl = (!IMASdd.ismissing(beam, :power_launched) && !isempty(beam.power_launched)) ? beam.power_launched[end] : 0.0
            η_conv = (!IMASdd.ismissing(beam.efficiency, :conversion) && beam.efficiency.conversion > 0) ? beam.efficiency.conversion : 1.0
            η_coup = !IMASdd.ismissing(beam.efficiency, :coupling) ? beam.efficiency.coupling : 1.0
            P_wall += pl / η_conv
            P_launched += pl
            P_absorbed += pl * η_coup
        end

        title --> "IFE driver power flow"
        ylabel --> "Power [MW]"
        legend --> false
        xticks --> (1:3, ["Wall plug", "Launched", "Absorbed"])
        ylim --> (0, max(P_wall, P_launched, P_absorbed) / 1e6 * 1.2)

        @series begin
            seriestype := :bar
            bar_width --> 0.5
            color --> [:steelblue, :orange, :green]
            [P_wall / 1e6, P_launched / 1e6, P_absorbed / 1e6]
        end
    end
end

#= =============== =#
#  chamber overview  #
#= =============== =#
"""
    target_layer_attrs(layer) -> (label, color)

Display label and fill color for one target-capsule shell. `layer` is an
`IMASdd` pellet layer: this is a plain helper, not a recipe, so it adds no
method to a type IFEdd does not own.
"""
function target_layer_attrs(layer)
    lbl = ""
    color = :gray
    if !isempty(layer.species)
        labels = [s.label for s in layer.species if !IMASdd.ismissing(s, :label)]
        lbl = join(labels, "/")
        if any(l ∈ ("D", "T", "DT") for l in labels)
            color = :lightblue
        end
    end
    return lbl, color
end

"""
    target_shells(pellets, r_display) -> Vector{(r_in, r_out, lbl, color)}

Resolve the capsule's concentric shells, scaled so the outermost sits at
`r_display`. Thicknesses run outside-in in the schema; the leftover core is
reported as the hot spot.
"""
function target_shells(pellets, r_display::Float64)
    shells = NamedTuple{(:r_in, :r_out, :lbl, :color),Tuple{Float64,Float64,String,Symbol}}[]
    isempty(pellets.launcher) && return shells
    launcher = pellets.launcher[1]
    (IMASdd.ismissing(launcher.shape, :size) || isempty(launcher.shape.size)) && return shells
    r_outer = launcher.shape.size[1]
    r_outer <= 0 && return shells
    scale = r_display / r_outer

    layers = (!isempty(pellets.time_slice) && !isempty(pellets.time_slice[].pellet)) ? pellets.time_slice[].pellet[1].layer : ()

    r_in = r_display
    for layer in Iterators.reverse(layers)
        IMASdd.ismissing(layer, :thickness) && continue
        r_out = r_in
        r_in = r_out - layer.thickness * scale
        lbl, col = target_layer_attrs(layer)
        pushfirst!(shells, (r_in=r_in, r_out=r_out, lbl=lbl, color=col))
    end
    r_in > 0 && pushfirst!(shells, (r_in=0.0, r_out=r_in, lbl="hot spot", color=:white))
    return shells
end

"""
    plot(dd::IFEdd.AbstractIFEDD; pellet_scale=0.15)

IFE chamber cross-section: the concentric build layers, driver beams converging
on the centre, and the target capsule drawn at the centre. `pellet_scale` sets
the capsule's display radius as a fraction of the chamber inner radius — a real
capsule is millimetric and would otherwise be invisible.

The capsule is drawn inline rather than delegated to a `pellets` recipe: that
type belongs to IMASdd, and leaving it alone keeps this extension free of any
method IFEdd does not own.
"""
@recipe function plot_chamber_cx(dd::IFEdd.AbstractIFEDD; pellet_scale=0.15)
    id = HelpPlots.recipe_dispatch(dd)
    HelpPlots.assert_type_and_record_argument(id, Float64, "Capsule display radius, as a fraction of the chamber radius"; pellet_scale)

    layers = dd.build.layer

    # An `if` rather than an early `return`: see `plot_driver` — a bare `return`
    # in a `@recipe` body does not suppress the `@series` blocks that follow it.
    if !isempty(layers)
        legend_position --> :outerbottomright
        aspect_ratio := :equal
        grid --> :none

        rmax = maximum(l.end_radius for l in layers if !IMASdd.ismissing(l, :end_radius); init=1.0)
        lim = rmax * 1.05
        xlim --> [-lim, lim]
        ylim --> [-lim, lim]

        # 1. concentric build layers (outermost → innermost)
        @series begin
            cx := true
            layers
        end

        # 2. driver beams — from the first wall's inner surface to the centre
        wall_idx = findfirst(l -> !IMASdd.ismissing(l, :type) && l.type == LAYER_WALL, layers)
        # Layers run innermost → outermost, so without a wall the chamber's own
        # outer boundary — `layers[1].end_radius` — is where the beams start.
        r_beam_start = wall_idx !== nothing ? layers[wall_idx].start_radius : layers[1].end_radius
        n_beams = max(1, length(dd.driver.beam))
        ϕ_beams = range(0, 2π, n_beams + 1)[1:n_beams]
        for (i, ϕ) in enumerate(ϕ_beams)
            @series begin
                seriestype := :path
                linecolor --> :red
                linewidth --> 1.0
                label --> (i == 1 ? "Driver beams" : "")
                [r_beam_start * cos(ϕ), 0.0], [r_beam_start * sin(ϕ), 0.0]
            end
        end

        # 3. target capsule, scaled up at the centre
        ϕ = range(0, 2π, 361)
        seen = Set{String}()
        for (; r_out, lbl, color) in Iterators.reverse(target_shells(dd.pellets, r_beam_start * pellet_scale))
            r_out == 0 && continue
            show_label = !isempty(lbl) && lbl ∉ seen
            show_label && push!(seen, lbl)
            @series begin
                seriestype := :shape
                linewidth := 0.5
                linecolor --> :black
                color --> color
                label --> (show_label ? uppercasefirst(lbl) : "")
                r_out .* cos.(ϕ), r_out .* sin.(ϕ)
            end
        end
    end
end

end # module
