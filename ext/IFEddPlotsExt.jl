# Plots.jl recipes for IFE-owned IDS — activates as a package extension when
# both IFEdd and Plots are loaded.

module IFEddPlotsExt

using IFEdd
using IMAS
using IMASdd
using Plots  # provides @recipe, @series (re-exports RecipesBase)

#= ========= =#
#  build  #
#= ========= =#
"""
    layer_attrs(l::IFEdd.build__layer) -> (name, color)

Map an IFE build layer to a display label and color using IMAS layer-type enums.
"""
function layer_attrs(l::IFEdd.build__layer)
    name = IMASdd.ismissing(l, :name) ? "" : l.name
    color = :gray
    if !IMASdd.ismissing(l, :type)
        t = l.type
        if t == Int(IMAS._plasma_)
            color = :white
        elseif t == Int(IMAS._gap_)
            name = ""
            color = :white
        elseif t == Int(IMAS._shield_)
            color = :red
        elseif t == Int(IMAS._blanket_)
            color = :orange
        elseif t == Int(IMAS._wall_)
            color = :yellow
        elseif t == Int(IMAS._vessel_)
            color = :lightyellow
        elseif t == Int(IMAS._cryostat_)
            color = :lightgray
        end
    end
    return name, color
end

@recipe function plot_build(bd::IFEdd.build; cx=true)
    legend_position --> :outerbottomright
    aspect_ratio := :equal
    grid --> :none

    @series begin
        cx := cx
        bd.layer
    end
end

@recipe function plot_build_layers(layers::AbstractVector{<:IFEdd.build__layer}; cx=true)
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

#= ========== =#
#  driver  #
#= ========== =#
@recipe function plot_driver(drv::IFEdd.driver)
    isempty(drv.beam) && return

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

end # module
