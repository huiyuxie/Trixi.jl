using OrdinaryDiffEqLowStorageRK
using Trixi

###############################################################################
# semidiscretization of the linear advection equation

equations = MaxwellEquations1D()

solver = DGSEM(polydeg = 3, surface_flux = flux_lax_friedrichs)

coordinates_min = 0.0
coordinates_max = 1.0

# Create a uniformly refined mesh with periodic boundaries
mesh = TreeMesh(coordinates_min, coordinates_max,
                initial_refinement_level = 4,
                n_cells_max = 30_000) # set maximum capacity of tree data structure

# Excite the electric field which causes a standing wave.
# The solution is an undamped exchange between electric and magnetic energy.
function initial_condition_E_excitation(x, t, equations::MaxwellEquations1D)
    RealT = eltype(x)
    c = equations.speed_of_light
    E = -c * sinpi(2 * x[1])
    B = 0

    return SVector(E, B)
end

initial_condition = initial_condition_E_excitation
semi = SemidiscretizationHyperbolic(mesh, equations, initial_condition, solver)

###############################################################################
# ODE solvers, callbacks etc.

# As the wave speed is equal to the speed of light which is on the order of 3 * 10^8
# we consider only a small time horizon.
ode = semidiscretize(semi, (0.0, 1e-7))

summary_callback = SummaryCallback()

# The AnalysisCallback allows to analyse the solution in regular intervals and prints the results
analysis_callback = AnalysisCallback(semi, interval = 100)

# The StepsizeCallback handles the re-calculation of the maximum Δt after each time step
stepsize_callback = StepsizeCallback(cfl = 1.6)

# Create a CallbackSet to collect all callbacks such that they can be passed to the ODE solver
callbacks = CallbackSet(summary_callback, analysis_callback, stepsize_callback)

###############################################################################
# run the simulation

sol = solve(ode, CarpenterKennedy2N54(williamson_condition = false);
            dt = 1.0, # solve needs some value here but it will be overwritten by the stepsize_callback
            ode_default_options()..., callback = callbacks);
