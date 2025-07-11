using OrdinaryDiffEqLowStorageRK
using Trixi

###############################################################################
# Semidiscretization of the quasi 1d compressible Euler equations
# See Chan et al.  https://doi.org/10.48550/arXiv.2307.12089 for details

equations = CompressibleEulerEquationsQuasi1D(1.4)

"""
    initial_condition_discontinuity(x, t, equations::CompressibleEulerEquations1D)

A discontinuous initial condition taken from
- Jesse Chan, Khemraj Shukla, Xinhui Wu, Ruofeng Liu, Prani Nalluri (2023)
    High order entropy stable schemes for the quasi-one-dimensional
    shallow water and compressible Euler equations
    [DOI: 10.48550/arXiv.2307.12089](https://doi.org/10.48550/arXiv.2307.12089)
"""
function initial_condition_discontinuity(x, t,
                                         equations::CompressibleEulerEquationsQuasi1D)
    RealT = eltype(x)
    rho = (x[1] < 0) ? RealT(3.4718) : RealT(2.0)
    v1 = (x[1] < 0) ? RealT(-2.5923) : RealT(-3.0)
    p = (x[1] < 0) ? RealT(5.7118) : RealT(2.639)
    a = (x[1] < 0) ? 1.0f0 : 1.5f0

    return prim2cons(SVector(rho, v1, p, a), equations)
end

initial_condition = initial_condition_discontinuity

surface_flux = (flux_lax_friedrichs, flux_nonconservative_chan_etal)
volume_flux = (flux_chan_etal, flux_nonconservative_chan_etal)

basis = LobattoLegendreBasis(3)
indicator_sc = IndicatorHennemannGassner(equations, basis,
                                         alpha_max = 0.5,
                                         alpha_min = 0.001,
                                         alpha_smooth = true,
                                         variable = density_pressure)
volume_integral = VolumeIntegralShockCapturingHG(indicator_sc;
                                                 volume_flux_dg = volume_flux,
                                                 volume_flux_fv = surface_flux)
solver = DGSEM(basis, surface_flux, volume_integral)

coordinates_min = (-1.0,)
coordinates_max = (1.0,)
mesh = TreeMesh(coordinates_min, coordinates_max,
                initial_refinement_level = 6,
                n_cells_max = 10_000)

semi = SemidiscretizationHyperbolic(mesh, equations, initial_condition, solver)

###############################################################################
# ODE solvers, callbacks etc.

tspan = (0.0, 2.0)
ode = semidiscretize(semi, tspan)

summary_callback = SummaryCallback()

analysis_interval = 100

analysis_callback = AnalysisCallback(semi, interval = analysis_interval)

alive_callback = AliveCallback(analysis_interval = analysis_interval)

save_solution = SaveSolutionCallback(interval = 100,
                                     save_initial_solution = true,
                                     save_final_solution = true,
                                     solution_variables = cons2prim)

stepsize_callback = StepsizeCallback(cfl = 0.5)

callbacks = CallbackSet(summary_callback,
                        analysis_callback, alive_callback,
                        save_solution,
                        stepsize_callback)

###############################################################################
# run the simulation

sol = solve(ode, CarpenterKennedy2N54(williamson_condition = false);
            dt = 1.0, # solve needs some value here but it will be overwritten by the stepsize_callback
            ode_default_options()..., callback = callbacks);
