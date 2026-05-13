# IFE-specific extensions to IMAS functions.
#
# This file lives inside the IFEdd module (not a package extension), so
# `function IMAS.<name>(...)` directly adds methods to IMAS's generic
# functions. Not type-piracy: every dispatch involves at least one
# IFEdd-owned type.
#
# Sections to populate (mapping joey_fork/IMAS.jl `ife` branch contents):
# 1. extract_ife — `IMAS.extract`-style functions for IFE scenarios
#    (cf. joey_fork/IMAS.jl/src/extract/extract_ife.jl, +128 lines)
# 2. plot recipes — Plots.jl @recipe definitions for ife_build, ife_driver
#    (cf. joey_fork/IMAS.jl/src/plot.jl IFE sections, +319 lines)

# --- extract ---------------------------------------------------------------
# TODO: define IFE ExtractFunction groups (:driver, :target, :plasma_peak,
# :power_avg, :neutronics, :bop, :costing) and an `extract_ife(dd::dd_ife)`
# entry point.

# --- plot recipes ----------------------------------------------------------
# TODO: add `@recipe function f(b::ife_build) ... end` etc. once Plots/RecipesBase
# integration is in scope.
