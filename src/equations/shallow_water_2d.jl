# By default, Julia/LLVM does not use fused multiply-add operations (FMAs).
# Since these FMAs can increase the performance of many numerical algorithms,
# we need to opt-in explicitly.
# See https://ranocha.de/blog/Optimizing_EC_Trixi for further details.
@muladd begin
#! format: noindent

@doc raw"""
    ShallowWaterEquations2D(; gravity_constant, H0 = 0)

Shallow water equations (SWE) in two space dimensions. The equations are given by
```math
\begin{aligned}
  \frac{\partial h}{\partial t} + \frac{\partial}{\partial x}(h v_1)
    + \frac{\partial}{\partial y}(h v_2) &= 0 \\
    \frac{\partial}{\partial t}(h v_1) + \frac{\partial}{\partial x}\left(h v_1^2 + \frac{g}{2}h^2\right)
    + \frac{\partial}{\partial y}(h v_1 v_2) + g h \frac{\partial b}{\partial x} &= 0 \\
    \frac{\partial}{\partial t}(h v_2) + \frac{\partial}{\partial x}(h v_1 v_2)
    + \frac{\partial}{\partial y}\left(h v_2^2 + \frac{g}{2}h^2\right) + g h \frac{\partial b}{\partial y} &= 0.
\end{aligned}
```
The unknown quantities of the SWE are the water height ``h`` and the velocities ``\mathbf{v} = (v_1, v_2)^T``.
The gravitational constant is denoted by `g` and the (possibly) variable bottom topography function ``b(x,y)``.
Conservative variable water height ``h`` is measured from the bottom topography ``b``, therefore one
also defines the total water height as ``H = h + b``.

The additional quantity ``H_0`` is also available to store a reference value for the total water height that
is useful to set initial conditions or test the "lake-at-rest" well-balancedness.

The bottom topography function ``b(x,y)`` is set inside the initial condition routine
for a particular problem setup. To test the conservative form of the SWE one can set the bottom topography
variable `b` to zero.

In addition to the unknowns, Trixi.jl currently stores the bottom topography values at the approximation points
despite being fixed in time. This is done for convenience of computing the bottom topography gradients
on the fly during the approximation as well as computing auxiliary quantities like the total water height ``H``
or the entropy variables.
This affects the implementation and use of these equations in various ways:
* The flux values corresponding to the bottom topography must be zero.
* The bottom topography values must be included when defining initial conditions, boundary conditions or
  source terms.
* [`AnalysisCallback`](@ref) analyzes this variable.
* Trixi.jl's visualization tools will visualize the bottom topography by default.

References for the SWE are many but a good introduction is available in Chapter 13 of the book:
- Randall J. LeVeque (2002)
  Finite Volume Methods for Hyperbolic Problems
  [DOI: 10.1017/CBO9780511791253](https://doi.org/10.1017/CBO9780511791253)
"""
struct ShallowWaterEquations2D{RealT <: Real} <: AbstractShallowWaterEquations{2, 4}
    gravity::RealT # gravitational constant
    H0::RealT      # constant "lake-at-rest" total water height
end

# Allow for flexibility to set the gravitational constant within an elixir depending on the
# application where `gravity_constant=1.0` or `gravity_constant=9.81` are common values.
# The reference total water height H0 defaults to 0.0 but is used for the "lake-at-rest"
# well-balancedness test cases.
# Strict default values for thresholds that performed well in many numerical experiments
function ShallowWaterEquations2D(; gravity_constant, H0 = zero(gravity_constant))
    ShallowWaterEquations2D(gravity_constant, H0)
end

have_nonconservative_terms(::ShallowWaterEquations2D) = True()
varnames(::typeof(cons2cons), ::ShallowWaterEquations2D) = ("h", "h_v1", "h_v2", "b")
# Note, we use the total water height, H = h + b, as the first primitive variable for easier
# visualization and setting initial conditions
varnames(::typeof(cons2prim), ::ShallowWaterEquations2D) = ("H", "v1", "v2", "b")

# Set initial conditions at physical location `x` for time `t`
"""
    initial_condition_convergence_test(x, t, equations::ShallowWaterEquations2D)

A smooth initial condition used for convergence tests in combination with
[`source_terms_convergence_test`](@ref)
(and [`BoundaryConditionDirichlet(initial_condition_convergence_test)`](@ref) in non-periodic domains).
"""
function initial_condition_convergence_test(x, t, equations::ShallowWaterEquations2D)
    # some constants are chosen such that the function is periodic on the domain [0,sqrt(2)]^2
    RealT = eltype(x)
    c = 7
    omega_x = 2 * convert(RealT, pi) * sqrt(convert(RealT, 2))
    omega_t = 2 * convert(RealT, pi)

    x1, x2 = x

    H = c + cos(omega_x * x1) * sin(omega_x * x2) * cos(omega_t * t)
    v1 = 0.5f0
    v2 = 1.5f0
    b = 2 + 0.5f0 * sinpi(sqrt(convert(RealT, 2)) * x1) +
        0.5f0 * sinpi(sqrt(convert(RealT, 2)) * x2)
    return prim2cons(SVector(H, v1, v2, b), equations)
end

"""
    source_terms_convergence_test(u, x, t, equations::ShallowWaterEquations2D)

Source terms used for convergence tests in combination with
[`initial_condition_convergence_test`](@ref)
(and [`BoundaryConditionDirichlet(initial_condition_convergence_test)`](@ref) in non-periodic domains).

This manufactured solution source term is specifically designed for the bottom topography function
`b(x,y) = 2 + 0.5 * sinpi(sqrt(2) * x) + 0.5 * sinpi(sqrt(2) * y)`
as defined in [`initial_condition_convergence_test`](@ref).
"""
@inline function source_terms_convergence_test(u, x, t,
                                               equations::ShallowWaterEquations2D)
    # Same settings as in `initial_condition_convergence_test`. Some derivative simplify because
    # this manufactured solution velocities are taken to be constants
    RealT = eltype(u)
    c = 7
    omega_x = 2 * convert(RealT, pi) * sqrt(convert(RealT, 2))
    omega_t = 2 * convert(RealT, pi)
    omega_b = sqrt(convert(RealT, 2)) * convert(RealT, pi)
    v1 = 0.5f0
    v2 = 1.5f0

    x1, x2 = x

    sinX, cosX = sincos(omega_x * x1)
    sinY, cosY = sincos(omega_x * x2)
    sinT, cosT = sincos(omega_t * t)

    H = c + cosX * sinY * cosT
    H_x = -omega_x * sinX * sinY * cosT
    H_y = omega_x * cosX * cosY * cosT
    # this time derivative for the water height exploits that the bottom topography is
    # fixed in time such that H_t = (h+b)_t = h_t + 0
    H_t = -omega_t * cosX * sinY * sinT

    # bottom topography and its gradient
    b = 2 + 0.5f0 * sinpi(sqrt(convert(RealT, 2)) * x1) +
        0.5f0 * sinpi(sqrt(convert(RealT, 2)) * x2)
    tmp1 = 0.5f0 * omega_b
    b_x = tmp1 * cos(omega_b * x1)
    b_y = tmp1 * cos(omega_b * x2)

    du1 = H_t + v1 * (H_x - b_x) + v2 * (H_y - b_y)
    du2 = v1 * du1 + equations.gravity * (H - b) * H_x
    du3 = v2 * du1 + equations.gravity * (H - b) * H_y
    return SVector(du1, du2, du3, 0)
end

"""
    initial_condition_weak_blast_wave(x, t, equations::ShallowWaterEquations2D)

A weak blast wave discontinuity useful for testing, e.g., total energy conservation.
Note for the shallow water equations to the total energy acts as a mathematical entropy function.
"""
function initial_condition_weak_blast_wave(x, t, equations::ShallowWaterEquations2D)
    # Set up polar coordinates
    RealT = eltype(x)
    inicenter = SVector(convert(RealT, 0.7), convert(RealT, 0.7))
    x_norm = x[1] - inicenter[1]
    y_norm = x[2] - inicenter[2]
    r = sqrt(x_norm^2 + y_norm^2)
    phi = atan(y_norm, x_norm)
    sin_phi, cos_phi = sincos(phi)

    # Calculate primitive variables
    H = r > 0.5f0 ? 3.25f0 : 4.0f0
    v1 = r > 0.5f0 ? zero(RealT) : convert(RealT, 0.1882) * cos_phi
    v2 = r > 0.5f0 ? zero(RealT) : convert(RealT, 0.1882) * sin_phi
    b = 0 # by default assume there is no bottom topography

    return prim2cons(SVector(H, v1, v2, b), equations)
end

"""
    boundary_condition_slip_wall(u_inner, normal_direction, x, t, surface_flux_function,
                                 equations::ShallowWaterEquations2D)
Create a boundary state by reflecting the normal velocity component and keep
the tangential velocity component unchanged. The boundary water height is taken from
the internal value.
For details see Section 9.2.5 of the book:
- Eleuterio F. Toro (2001)
  Shock-Capturing Methods for Free-Surface Shallow Flows
  1st edition
  ISBN 0471987662
"""
@inline function boundary_condition_slip_wall(u_inner, normal_direction::AbstractVector,
                                              x, t,
                                              surface_flux_functions,
                                              equations::ShallowWaterEquations2D)
    surface_flux_function, nonconservative_flux_function = surface_flux_functions

    # normalize the outward pointing direction
    normal = normal_direction / norm(normal_direction)

    # compute the normal velocity
    u_normal = normal[1] * u_inner[2] + normal[2] * u_inner[3]

    # create the "external" boundary solution state
    u_boundary = SVector(u_inner[1],
                         u_inner[2] - 2 * u_normal * normal[1],
                         u_inner[3] - 2 * u_normal * normal[2],
                         u_inner[4])

    # calculate the boundary flux
    flux = surface_flux_function(u_inner, u_boundary, normal_direction, equations)
    noncons_flux = nonconservative_flux_function(u_inner, u_boundary, normal_direction,
                                                 equations)

    return flux, noncons_flux
end

"""
    boundary_condition_slip_wall(u_inner, orientation, direction, x, t,
                                 surface_flux_function, equations::ShallowWaterEquations2D)

Should be used together with [`TreeMesh`](@ref).
"""
@inline function boundary_condition_slip_wall(u_inner, orientation,
                                              direction, x, t,
                                              surface_flux_functions,
                                              equations::ShallowWaterEquations2D)
    # The boundary conditions for the non-conservative term are identically 0 here.
    # Bottom topography is assumed to be continuous at the boundary.
    surface_flux_function, nonconservative_flux_function = surface_flux_functions
    ## get the appropriate normal vector from the orientation
    if orientation == 1
        u_boundary = SVector(u_inner[1], -u_inner[2], u_inner[3], u_inner[4])
    else # orientation == 2
        u_boundary = SVector(u_inner[1], u_inner[2], -u_inner[3], u_inner[4])
    end

    # Calculate boundary flux
    if iseven(direction) # u_inner is "left" of boundary, u_boundary is "right" of boundary
        flux = surface_flux_function(u_inner, u_boundary, orientation, equations)
        noncons_flux = nonconservative_flux_function(u_inner, u_boundary, orientation,
                                                     equations)
    else # u_boundary is "left" of boundary, u_inner is "right" of boundary
        flux = surface_flux_function(u_boundary, u_inner, orientation, equations)
        noncons_flux = nonconservative_flux_function(u_boundary, u_inner, orientation,
                                                     equations)
    end

    return flux, noncons_flux
end

# Calculate 1D flux for a single point
# Note, the bottom topography has no flux
@inline function flux(u, orientation::Integer, equations::ShallowWaterEquations2D)
    h, h_v1, h_v2, _ = u
    v1, v2 = velocity(u, equations)

    p = 0.5f0 * equations.gravity * h^2
    if orientation == 1
        f1 = h_v1
        f2 = h_v1 * v1 + p
        f3 = h_v1 * v2
    else
        f1 = h_v2
        f2 = h_v2 * v1
        f3 = h_v2 * v2 + p
    end
    return SVector(f1, f2, f3, 0)
end

# Calculate 1D flux for a single point in the normal direction
# Note, this directional vector is not normalized and the bottom topography has no flux
@inline function flux(u, normal_direction::AbstractVector,
                      equations::ShallowWaterEquations2D)
    h = waterheight(u, equations)
    v1, v2 = velocity(u, equations)

    v_normal = v1 * normal_direction[1] + v2 * normal_direction[2]
    h_v_normal = h * v_normal
    p = 0.5f0 * equations.gravity * h^2

    f1 = h_v_normal
    f2 = h_v_normal * v1 + p * normal_direction[1]
    f3 = h_v_normal * v2 + p * normal_direction[2]
    return SVector(f1, f2, f3, 0)
end

"""
    flux_nonconservative_wintermeyer_etal(u_ll, u_rr, orientation::Integer,
                                          equations::ShallowWaterEquations2D)
    flux_nonconservative_wintermeyer_etal(u_ll, u_rr,
                                          normal_direction::AbstractVector,
                                          equations::ShallowWaterEquations2D)

Non-symmetric two-point volume flux discretizing the nonconservative (source) term
that contains the gradient of the bottom topography [`ShallowWaterEquations2D`](@ref).

For the `surface_flux` either [`flux_wintermeyer_etal`](@ref) or [`flux_fjordholm_etal`](@ref) can
be used to ensure well-balancedness and entropy conservation.

Further details are available in the papers:
- Niklas Wintermeyer, Andrew R. Winters, Gregor J. Gassner and David A. Kopriva (2017)
  An entropy stable nodal discontinuous Galerkin method for the two dimensional
  shallow water equations on unstructured curvilinear meshes with discontinuous bathymetry
  [DOI: 10.1016/j.jcp.2017.03.036](https://doi.org/10.1016/j.jcp.2017.03.036)
- Patrick Ersing, Andrew R. Winters (2023)
  An entropy stable discontinuous Galerkin method for the two-layer shallow water equations on
  curvilinear meshes
  [DOI: 10.48550/arXiv.2306.12699](https://doi.org/10.48550/arXiv.2306.12699)
"""
@inline function flux_nonconservative_wintermeyer_etal(u_ll, u_rr, orientation::Integer,
                                                       equations::ShallowWaterEquations2D)
    # Pull the necessary left and right state information
    h_ll = waterheight(u_ll, equations)
    b_jump = u_rr[4] - u_ll[4]

    # Bottom gradient nonconservative term: (0, g h b_x, g h b_y, 0)
    if orientation == 1
        f = SVector(0, equations.gravity * h_ll * b_jump, 0, 0)
    else # orientation == 2
        f = SVector(0, 0, equations.gravity * h_ll * b_jump, 0)
    end
    return f
end

@inline function flux_nonconservative_wintermeyer_etal(u_ll, u_rr,
                                                       normal_direction::AbstractVector,
                                                       equations::ShallowWaterEquations2D)
    # Pull the necessary left and right state information
    h_ll = waterheight(u_ll, equations)
    b_jump = u_rr[4] - u_ll[4]

    # Bottom gradient nonconservative term: (0, g h b_x, g h b_y, 0)
    return SVector(0,
                   normal_direction[1] * equations.gravity * h_ll * b_jump,
                   normal_direction[2] * equations.gravity * h_ll * b_jump,
                   0)
end

"""
    flux_nonconservative_fjordholm_etal(u_ll, u_rr, orientation::Integer,
                                        equations::ShallowWaterEquations2D)
    flux_nonconservative_fjordholm_etal(u_ll, u_rr,
                                        normal_direction::AbstractVector,
                                        equations::ShallowWaterEquations2D)

Non-symmetric two-point surface flux discretizing the nonconservative (source) term of
that contains the gradient of the bottom topography [`ShallowWaterEquations2D`](@ref).

This flux can be used together with [`flux_fjordholm_etal`](@ref) at interfaces to ensure entropy
conservation and well-balancedness.

Further details for the original finite volume formulation are available in
- Ulrik S. Fjordholm, Siddhartha Mishra and Eitan Tadmor (2011)
  Well-balanced and energy stable schemes for the shallow water equations with discontinuous topography
  [DOI: 10.1016/j.jcp.2011.03.042](https://doi.org/10.1016/j.jcp.2011.03.042)
and for curvilinear 2D case in the paper:
- Niklas Wintermeyer, Andrew R. Winters, Gregor J. Gassner and David A. Kopriva (2017)
  An entropy stable nodal discontinuous Galerkin method for the two dimensional
  shallow water equations on unstructured curvilinear meshes with discontinuous bathymetry
  [DOI: 10.1016/j.jcp.2017.03.036](https://doi.org/10.1016/j.jcp.2017.03.036)
"""
@inline function flux_nonconservative_fjordholm_etal(u_ll, u_rr, orientation::Integer,
                                                     equations::ShallowWaterEquations2D)
    # Pull the necessary left and right state information
    h_ll, _, _, b_ll = u_ll
    h_rr, _, _, b_rr = u_rr

    h_average = 0.5f0 * (h_ll + h_rr)
    b_jump = b_rr - b_ll

    # Bottom gradient nonconservative term: (0, g h b_x, g h b_y, 0)
    if orientation == 1
        f = SVector(0,
                    equations.gravity * h_average * b_jump,
                    0, 0)
    else # orientation == 2
        f = SVector(0, 0,
                    equations.gravity * h_average * b_jump,
                    0)
    end

    return f
end

@inline function flux_nonconservative_fjordholm_etal(u_ll, u_rr,
                                                     normal_direction::AbstractVector,
                                                     equations::ShallowWaterEquations2D)
    # Pull the necessary left and right state information
    h_ll, _, _, b_ll = u_ll
    h_rr, _, _, b_rr = u_rr

    h_average = 0.5f0 * (h_ll + h_rr)
    b_jump = b_rr - b_ll

    # Bottom gradient nonconservative term: (0, g h b_x, g h b_y, 0)
    f2 = normal_direction[1] * equations.gravity * h_average * b_jump
    f3 = normal_direction[2] * equations.gravity * h_average * b_jump

    # First and last equations do not have a nonconservative flux
    f1 = f4 = 0

    return SVector(f1, f2, f3, f4)
end

"""
    hydrostatic_reconstruction_audusse_etal(u_ll, u_rr, orientation_or_normal_direction,
                                            equations::ShallowWaterEquations2D)

A particular type of hydrostatic reconstruction on the water height to guarantee well-balancedness
for a general bottom topography [`ShallowWaterEquations2D`](@ref). The reconstructed solution states
`u_ll_star` and `u_rr_star` variables are used to evaluate the surface numerical flux at the interface.
Use in combination with the generic numerical flux routine [`FluxHydrostaticReconstruction`](@ref).

Further details for the hydrostatic reconstruction and its motivation can be found in
- Emmanuel Audusse, François Bouchut, Marie-Odile Bristeau, Rupert Klein, and Benoit Perthame (2004)
  A fast and stable well-balanced scheme with hydrostatic reconstruction for shallow water flows
  [DOI: 10.1137/S1064827503431090](https://doi.org/10.1137/S1064827503431090)
"""
@inline function hydrostatic_reconstruction_audusse_etal(u_ll, u_rr,
                                                         equations::ShallowWaterEquations2D)
    # Unpack left and right water heights and bottom topographies
    h_ll, _, _, b_ll = u_ll
    h_rr, _, _, b_rr = u_rr

    # Get the velocities on either side
    v1_ll, v2_ll = velocity(u_ll, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    # Compute the reconstructed water heights
    h_ll_star = max(0, h_ll + b_ll - max(b_ll, b_rr))
    h_rr_star = max(0, h_rr + b_rr - max(b_ll, b_rr))

    # Create the conservative variables using the reconstruted water heights
    u_ll_star = SVector(h_ll_star, h_ll_star * v1_ll, h_ll_star * v2_ll, b_ll)
    u_rr_star = SVector(h_rr_star, h_rr_star * v1_rr, h_rr_star * v2_rr, b_rr)

    return u_ll_star, u_rr_star
end

"""
    flux_nonconservative_audusse_etal(u_ll, u_rr, orientation::Integer,
                                      equations::ShallowWaterEquations2D)
    flux_nonconservative_audusse_etal(u_ll, u_rr,
                                      normal_direction::AbstractVector,
                                      equations::ShallowWaterEquations2D)

Non-symmetric two-point surface flux that discretizes the nonconservative (source) term.
The discretization uses the `hydrostatic_reconstruction_audusse_etal` on the conservative
variables.

This hydrostatic reconstruction ensures that the finite volume numerical fluxes remain
well-balanced for discontinuous bottom topographies [`ShallowWaterEquations2D`](@ref).
Should be used together with [`FluxHydrostaticReconstruction`](@ref) and
[`hydrostatic_reconstruction_audusse_etal`](@ref) in the surface flux to ensure consistency.

Further details for the hydrostatic reconstruction and its motivation can be found in
- Emmanuel Audusse, François Bouchut, Marie-Odile Bristeau, Rupert Klein, and Benoit Perthame (2004)
  A fast and stable well-balanced scheme with hydrostatic reconstruction for shallow water flows
  [DOI: 10.1137/S1064827503431090](https://doi.org/10.1137/S1064827503431090)
"""
@inline function flux_nonconservative_audusse_etal(u_ll, u_rr, orientation::Integer,
                                                   equations::ShallowWaterEquations2D)
    # Pull the water height and bottom topography on the left
    h_ll, _, _, b_ll = u_ll

    # Create the hydrostatic reconstruction for the left solution state
    u_ll_star, _ = hydrostatic_reconstruction_audusse_etal(u_ll, u_rr, equations)

    # Copy the reconstructed water height for easier to read code
    h_ll_star = u_ll_star[1]

    if orientation == 1
        f = SVector(0,
                    equations.gravity * (h_ll^2 - h_ll_star^2),
                    0, 0)
    else # orientation == 2
        f = SVector(0, 0,
                    equations.gravity * (h_ll^2 - h_ll_star^2),
                    0)
    end

    return f
end

@inline function flux_nonconservative_audusse_etal(u_ll, u_rr,
                                                   normal_direction::AbstractVector,
                                                   equations::ShallowWaterEquations2D)
    # Pull the water height and bottom topography on the left
    h_ll, _, _, b_ll = u_ll

    # Create the hydrostatic reconstruction for the left solution state
    u_ll_star, _ = hydrostatic_reconstruction_audusse_etal(u_ll, u_rr, equations)

    # Copy the reconstructed water height for easier to read code
    h_ll_star = u_ll_star[1]

    f2 = normal_direction[1] * equations.gravity * (h_ll^2 - h_ll_star^2)
    f3 = normal_direction[2] * equations.gravity * (h_ll^2 - h_ll_star^2)

    # First and last equations do not have a nonconservative flux
    f1 = f4 = 0

    return SVector(f1, f2, f3, f4)
end

"""
    flux_fjordholm_etal(u_ll, u_rr, orientation_or_normal_direction,
                        equations::ShallowWaterEquations2D)

Total energy conservative (mathematical entropy for shallow water equations). When the bottom topography
is nonzero this should only be used as a surface flux otherwise the scheme will not be well-balanced.
For well-balancedness in the volume flux use [`flux_wintermeyer_etal`](@ref).

Details are available in Eq. (4.1) in the paper:
- Ulrik S. Fjordholm, Siddhartha Mishra and Eitan Tadmor (2011)
  Well-balanced and energy stable schemes for the shallow water equations with discontinuous topography
  [DOI: 10.1016/j.jcp.2011.03.042](https://doi.org/10.1016/j.jcp.2011.03.042)
"""
@inline function flux_fjordholm_etal(u_ll, u_rr, orientation::Integer,
                                     equations::ShallowWaterEquations2D)
    # Unpack left and right state
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    # Average each factor of products in flux
    h_avg = 0.5f0 * (h_ll + h_rr)
    v1_avg = 0.5f0 * (v1_ll + v1_rr)
    v2_avg = 0.5f0 * (v2_ll + v2_rr)
    p_avg = 0.25f0 * equations.gravity * (h_ll^2 + h_rr^2)

    # Calculate fluxes depending on orientation
    if orientation == 1
        f1 = h_avg * v1_avg
        f2 = f1 * v1_avg + p_avg
        f3 = f1 * v2_avg
    else
        f1 = h_avg * v2_avg
        f2 = f1 * v1_avg
        f3 = f1 * v2_avg + p_avg
    end

    return SVector(f1, f2, f3, 0)
end

@inline function flux_fjordholm_etal(u_ll, u_rr, normal_direction::AbstractVector,
                                     equations::ShallowWaterEquations2D)
    # Unpack left and right state
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    v_dot_n_ll = v1_ll * normal_direction[1] + v2_ll * normal_direction[2]
    v_dot_n_rr = v1_rr * normal_direction[1] + v2_rr * normal_direction[2]

    # Average each factor of products in flux
    h_avg = 0.5f0 * (h_ll + h_rr)
    v1_avg = 0.5f0 * (v1_ll + v1_rr)
    v2_avg = 0.5f0 * (v2_ll + v2_rr)
    h2_avg = 0.5f0 * (h_ll^2 + h_rr^2)
    p_avg = 0.5f0 * equations.gravity * h2_avg
    v_dot_n_avg = 0.5f0 * (v_dot_n_ll + v_dot_n_rr)

    # Calculate fluxes depending on normal_direction
    f1 = h_avg * v_dot_n_avg
    f2 = f1 * v1_avg + p_avg * normal_direction[1]
    f3 = f1 * v2_avg + p_avg * normal_direction[2]

    return SVector(f1, f2, f3, 0)
end

"""
    flux_wintermeyer_etal(u_ll, u_rr, orientation_or_normal_direction,
                          equations::ShallowWaterEquations2D)

Total energy conservative (mathematical entropy for shallow water equations) split form.
When the bottom topography is nonzero this scheme will be well-balanced when used as a `volume_flux`.
For the `surface_flux` either [`flux_wintermeyer_etal`](@ref) or [`flux_fjordholm_etal`](@ref) can
be used to ensure well-balancedness and entropy conservation.

Further details are available in Theorem 1 of the paper:
- Niklas Wintermeyer, Andrew R. Winters, Gregor J. Gassner and David A. Kopriva (2017)
  An entropy stable nodal discontinuous Galerkin method for the two dimensional
  shallow water equations on unstructured curvilinear meshes with discontinuous bathymetry
  [DOI: 10.1016/j.jcp.2017.03.036](https://doi.org/10.1016/j.jcp.2017.03.036)
"""
@inline function flux_wintermeyer_etal(u_ll, u_rr, orientation::Integer,
                                       equations::ShallowWaterEquations2D)
    # Unpack left and right state
    h_ll, h_v1_ll, h_v2_ll, _ = u_ll
    h_rr, h_v1_rr, h_v2_rr, _ = u_rr

    # Get the velocities on either side
    v1_ll, v2_ll = velocity(u_ll, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    # Average each factor of products in flux
    v1_avg = 0.5f0 * (v1_ll + v1_rr)
    v2_avg = 0.5f0 * (v2_ll + v2_rr)
    p_avg = 0.5f0 * equations.gravity * h_ll * h_rr

    # Calculate fluxes depending on orientation
    if orientation == 1
        f1 = 0.5f0 * (h_v1_ll + h_v1_rr)
        f2 = f1 * v1_avg + p_avg
        f3 = f1 * v2_avg
    else
        f1 = 0.5f0 * (h_v2_ll + h_v2_rr)
        f2 = f1 * v1_avg
        f3 = f1 * v2_avg + p_avg
    end

    return SVector(f1, f2, f3, 0)
end

@inline function flux_wintermeyer_etal(u_ll, u_rr, normal_direction::AbstractVector,
                                       equations::ShallowWaterEquations2D)
    # Unpack left and right state
    h_ll, h_v1_ll, h_v2_ll, _ = u_ll
    h_rr, h_v1_rr, h_v2_rr, _ = u_rr

    # Get the velocities on either side
    v1_ll, v2_ll = velocity(u_ll, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    # Average each factor of products in flux
    h_v1_avg = 0.5f0 * (h_v1_ll + h_v1_rr)
    h_v2_avg = 0.5f0 * (h_v2_ll + h_v2_rr)
    v1_avg = 0.5f0 * (v1_ll + v1_rr)
    v2_avg = 0.5f0 * (v2_ll + v2_rr)
    p_avg = 0.5f0 * equations.gravity * h_ll * h_rr

    # Calculate fluxes depending on normal_direction
    f1 = h_v1_avg * normal_direction[1] + h_v2_avg * normal_direction[2]
    f2 = f1 * v1_avg + p_avg * normal_direction[1]
    f3 = f1 * v2_avg + p_avg * normal_direction[2]

    return SVector(f1, f2, f3, 0)
end

# Calculate maximum wave speed for local Lax-Friedrichs-type dissipation as the
# maximum velocity magnitude plus the maximum speed of sound
@inline function max_abs_speed_naive(u_ll, u_rr, orientation::Integer,
                                     equations::ShallowWaterEquations2D)
    # Get the velocity quantities in the appropriate direction
    if orientation == 1
        v_ll, _ = velocity(u_ll, equations)
        v_rr, _ = velocity(u_rr, equations)
    else
        _, v_ll = velocity(u_ll, equations)
        _, v_rr = velocity(u_rr, equations)
    end

    # Calculate the wave celerity on the left and right
    h_ll = waterheight(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    c_ll = sqrt(equations.gravity * h_ll)
    c_rr = sqrt(equations.gravity * h_rr)

    return max(abs(v_ll), abs(v_rr)) + max(c_ll, c_rr)
end

@inline function max_abs_speed_naive(u_ll, u_rr, normal_direction::AbstractVector,
                                     equations::ShallowWaterEquations2D)
    # Extract and compute the velocities in the normal direction
    v1_ll, v2_ll = velocity(u_ll, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)
    v_ll = v1_ll * normal_direction[1] + v2_ll * normal_direction[2]
    v_rr = v1_rr * normal_direction[1] + v2_rr * normal_direction[2]

    # Compute the wave celerity on the left and right
    h_ll = waterheight(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    c_ll = sqrt(equations.gravity * h_ll)
    c_rr = sqrt(equations.gravity * h_rr)

    # The normal velocities are already scaled by the norm
    return max(abs(v_ll), abs(v_rr)) + max(c_ll, c_rr) * norm(normal_direction)
end

# Less "cautious", i.e., less overestimating `λ_max` compared to `max_abs_speed_naive`
@inline function max_abs_speed(u_ll, u_rr, orientation::Integer,
                               equations::ShallowWaterEquations2D)
    # Get the velocity quantities in the appropriate direction
    if orientation == 1
        v_ll, _ = velocity(u_ll, equations)
        v_rr, _ = velocity(u_rr, equations)
    else
        _, v_ll = velocity(u_ll, equations)
        _, v_rr = velocity(u_rr, equations)
    end

    # Calculate the wave celerity on the left and right
    h_ll = waterheight(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    c_ll = sqrt(equations.gravity * h_ll)
    c_rr = sqrt(equations.gravity * h_rr)

    return max(abs(v_ll) + c_ll, abs(v_rr) + c_rr)
end

# Less "cautious", i.e., less overestimating `λ_max` compared to `max_abs_speed_naive`
@inline function max_abs_speed(u_ll, u_rr, normal_direction::AbstractVector,
                               equations::ShallowWaterEquations2D)
    # Extract and compute the velocities in the normal direction
    v1_ll, v2_ll = velocity(u_ll, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)
    v_ll = v1_ll * normal_direction[1] + v2_ll * normal_direction[2]
    v_rr = v1_rr * normal_direction[1] + v2_rr * normal_direction[2]

    # Compute the wave celerity on the left and right
    h_ll = waterheight(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    c_ll = sqrt(equations.gravity * h_ll)
    c_rr = sqrt(equations.gravity * h_rr)

    norm_ = norm(normal_direction)
    # The normal velocities are already scaled by the norm
    return max(abs(v_ll) + c_ll * norm_, abs(v_rr) + c_rr * norm_)
end

# Specialized `DissipationLocalLaxFriedrichs` to avoid spurious dissipation in the bottom topography
@inline function (dissipation::DissipationLocalLaxFriedrichs)(u_ll, u_rr,
                                                              orientation_or_normal_direction,
                                                              equations::ShallowWaterEquations2D)
    λ = dissipation.max_abs_speed(u_ll, u_rr, orientation_or_normal_direction,
                                  equations)
    diss = -0.5f0 * λ * (u_rr - u_ll)
    return SVector(diss[1], diss[2], diss[3], 0)
end

# Specialized `FluxHLL` to avoid spurious dissipation in the bottom topography
@inline function (numflux::FluxHLL)(u_ll, u_rr, orientation_or_normal_direction,
                                    equations::ShallowWaterEquations2D)
    λ_min, λ_max = numflux.min_max_speed(u_ll, u_rr, orientation_or_normal_direction,
                                         equations)

    if λ_min >= 0 && λ_max >= 0
        return flux(u_ll, orientation_or_normal_direction, equations)
    elseif λ_max <= 0 && λ_min <= 0
        return flux(u_rr, orientation_or_normal_direction, equations)
    else
        f_ll = flux(u_ll, orientation_or_normal_direction, equations)
        f_rr = flux(u_rr, orientation_or_normal_direction, equations)
        inv_λ_max_minus_λ_min = inv(λ_max - λ_min)
        factor_ll = λ_max * inv_λ_max_minus_λ_min
        factor_rr = λ_min * inv_λ_max_minus_λ_min
        factor_diss = λ_min * λ_max * inv_λ_max_minus_λ_min
        diss = u_rr - u_ll
        return factor_ll * f_ll - factor_rr * f_rr +
               factor_diss * SVector(diss[1], diss[2], diss[3], 0)
    end
end

# Calculate estimates for minimum and maximum wave speeds for HLL-type fluxes
@inline function min_max_speed_naive(u_ll, u_rr, orientation::Integer,
                                     equations::ShallowWaterEquations2D)
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    if orientation == 1 # x-direction
        λ_min = v1_ll - sqrt(equations.gravity * h_ll)
        λ_max = v1_rr + sqrt(equations.gravity * h_rr)
    else # y-direction
        λ_min = v2_ll - sqrt(equations.gravity * h_ll)
        λ_max = v2_rr + sqrt(equations.gravity * h_rr)
    end

    return λ_min, λ_max
end

@inline function min_max_speed_naive(u_ll, u_rr, normal_direction::AbstractVector,
                                     equations::ShallowWaterEquations2D)
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    v_normal_ll = v1_ll * normal_direction[1] + v2_ll * normal_direction[2]
    v_normal_rr = v1_rr * normal_direction[1] + v2_rr * normal_direction[2]

    norm_ = norm(normal_direction)
    # The v_normals are already scaled by the norm
    λ_min = v_normal_ll - sqrt(equations.gravity * h_ll) * norm_
    λ_max = v_normal_rr + sqrt(equations.gravity * h_rr) * norm_

    return λ_min, λ_max
end

# More refined estimates for minimum and maximum wave speeds for HLL-type fluxes
@inline function min_max_speed_davis(u_ll, u_rr, orientation::Integer,
                                     equations::ShallowWaterEquations2D)
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    c_ll = sqrt(equations.gravity * h_ll)
    c_rr = sqrt(equations.gravity * h_rr)

    if orientation == 1 # x-direction
        λ_min = min(v1_ll - c_ll, v1_rr - c_rr)
        λ_max = max(v1_ll + c_ll, v1_rr + c_rr)
    else # y-direction
        λ_min = min(v2_ll - c_ll, v2_rr - c_rr)
        λ_max = max(v2_ll + c_ll, v2_rr + c_rr)
    end

    return λ_min, λ_max
end

@inline function min_max_speed_davis(u_ll, u_rr, normal_direction::AbstractVector,
                                     equations::ShallowWaterEquations2D)
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    norm_ = norm(normal_direction)
    c_ll = sqrt(equations.gravity * h_ll) * norm_
    c_rr = sqrt(equations.gravity * h_rr) * norm_

    v_normal_ll = v1_ll * normal_direction[1] + v2_ll * normal_direction[2]
    v_normal_rr = v1_rr * normal_direction[1] + v2_rr * normal_direction[2]

    # The v_normals are already scaled by the norm
    λ_min = min(v_normal_ll - c_ll, v_normal_rr - c_rr)
    λ_max = max(v_normal_ll + c_ll, v_normal_rr + c_rr)

    return λ_min, λ_max
end

@inline function min_max_speed_einfeldt(u_ll, u_rr, orientation::Integer,
                                        equations::ShallowWaterEquations2D)
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    c_ll = sqrt(equations.gravity * h_ll)
    c_rr = sqrt(equations.gravity * h_rr)

    if orientation == 1 # x-direction
        v_roe, c_roe = calc_wavespeed_roe(u_ll, u_rr, orientation, equations)
        λ_min = min(v1_ll - c_ll, v_roe - c_roe)
        λ_max = max(v1_rr + c_rr, v_roe + c_roe)
    else # y-direction
        v_roe, c_roe = calc_wavespeed_roe(u_ll, u_rr, orientation, equations)
        λ_min = min(v2_ll - c_ll, v_roe - c_roe)
        λ_max = max(v2_rr + c_rr, v_roe + c_roe)
    end

    return λ_min, λ_max
end

@inline function min_max_speed_einfeldt(u_ll, u_rr, normal_direction::AbstractVector,
                                        equations::ShallowWaterEquations2D)
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    norm_ = norm(normal_direction)

    c_ll = sqrt(equations.gravity * h_ll) * norm_
    c_rr = sqrt(equations.gravity * h_rr) * norm_

    v_normal_ll = (v1_ll * normal_direction[1] + v2_ll * normal_direction[2])
    v_normal_rr = (v1_rr * normal_direction[1] + v2_rr * normal_direction[2])

    v_roe, c_roe = calc_wavespeed_roe(u_ll, u_rr, normal_direction, equations)
    λ_min = min(v_normal_ll - c_ll, v_roe - c_roe)
    λ_max = max(v_normal_rr + c_rr, v_roe + c_roe)

    return λ_min, λ_max
end

@inline function max_abs_speeds(u, equations::ShallowWaterEquations2D)
    h = waterheight(u, equations)
    v1, v2 = velocity(u, equations)

    c = sqrt(equations.gravity * h)
    return abs(v1) + c, abs(v2) + c
end

# Helper function to extract the velocity vector from the conservative variables
@inline function velocity(u, equations::ShallowWaterEquations2D)
    h, h_v1, h_v2, _ = u

    v1 = h_v1 / h
    v2 = h_v2 / h
    return SVector(v1, v2)
end

@inline function velocity(u, orientation::Int, equations::ShallowWaterEquations2D)
    h = u[1]
    v = u[orientation + 1] / h
    return v
end

# Convert conservative variables to primitive
@inline function cons2prim(u, equations::ShallowWaterEquations2D)
    h, _, _, b = u

    H = h + b
    v1, v2 = velocity(u, equations)
    return SVector(H, v1, v2, b)
end

# Convert conservative variables to entropy
# Note, only the first three are the entropy variables, the fourth entry still
# just carries the bottom topography values for convenience
@inline function cons2entropy(u, equations::ShallowWaterEquations2D)
    h, h_v1, h_v2, b = u

    v1, v2 = velocity(u, equations)
    v_square = v1^2 + v2^2

    w1 = equations.gravity * (h + b) - 0.5f0 * v_square
    w2 = v1
    w3 = v2
    return SVector(w1, w2, w3, b)
end

# Convert entropy variables to conservative
@inline function entropy2cons(w, equations::ShallowWaterEquations2D)
    w1, w2, w3, b = w

    h = (w1 + 0.5f0 * (w2^2 + w3^2)) / equations.gravity - b
    h_v1 = h * w2
    h_v2 = h * w3
    return SVector(h, h_v1, h_v2, b)
end

# Convert primitive to conservative variables
@inline function prim2cons(prim, equations::ShallowWaterEquations2D)
    H, v1, v2, b = prim

    h = H - b
    h_v1 = h * v1
    h_v2 = h * v2
    return SVector(h, h_v1, h_v2, b)
end

@inline function waterheight(u, equations::ShallowWaterEquations2D)
    return u[1]
end

@inline function pressure(u, equations::ShallowWaterEquations2D)
    h = waterheight(u, equations)
    p = 0.5f0 * equations.gravity * h^2
    return p
end

@inline function waterheight_pressure(u, equations::ShallowWaterEquations2D)
    return waterheight(u, equations) * pressure(u, equations)
end

"""
    calc_wavespeed_roe(u_ll, u_rr, direction::Integer,
                       equations::ShallowWaterEquations2D)

Calculate Roe-averaged velocity `v_roe` and wavespeed `c_roe = sqrt{g * h_roe}` depending on direction.
See for instance equation (62) in
- Paul A. Ullrich, Christiane Jablonowski, and Bram van Leer (2010)
  High-order finite-volume methods for the shallow-water equations on the sphere
  [DOI: 10.1016/j.jcp.2010.04.044](https://doi.org/10.1016/j.jcp.2010.04.044)
Or [this slides](https://faculty.washington.edu/rjl/classes/am574w2011/slides/am574lecture20nup3.pdf),
slides 8 and 9.
"""
@inline function calc_wavespeed_roe(u_ll, u_rr, orientation::Integer,
                                    equations::ShallowWaterEquations2D)
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    h_roe = 0.5f0 * (h_ll + h_rr)
    c_roe = sqrt(equations.gravity * h_roe)

    h_ll_sqrt = sqrt(h_ll)
    h_rr_sqrt = sqrt(h_rr)

    if orientation == 1 # x-direction
        v_roe = (h_ll_sqrt * v1_ll + h_rr_sqrt * v1_rr) / (h_ll_sqrt + h_rr_sqrt)
    else # y-direction
        v_roe = (h_ll_sqrt * v2_ll + h_rr_sqrt * v2_rr) / (h_ll_sqrt + h_rr_sqrt)
    end

    return v_roe, c_roe
end

@inline function calc_wavespeed_roe(u_ll, u_rr, normal_direction::AbstractVector,
                                    equations::ShallowWaterEquations2D)
    h_ll = waterheight(u_ll, equations)
    v1_ll, v2_ll = velocity(u_ll, equations)
    h_rr = waterheight(u_rr, equations)
    v1_rr, v2_rr = velocity(u_rr, equations)

    norm_ = norm(normal_direction)

    h_roe = 0.5f0 * (h_ll + h_rr)
    c_roe = sqrt(equations.gravity * h_roe) * norm_

    h_ll_sqrt = sqrt(h_ll)
    h_rr_sqrt = sqrt(h_rr)

    v1_roe = (h_ll_sqrt * v1_ll + h_rr_sqrt * v1_rr) / (h_ll_sqrt + h_rr_sqrt)
    v2_roe = (h_ll_sqrt * v2_ll + h_rr_sqrt * v2_rr) / (h_ll_sqrt + h_rr_sqrt)

    v_roe = (v1_roe * normal_direction[1] + v2_roe * normal_direction[2])

    return v_roe, c_roe
end

# Entropy function for the shallow water equations is the total energy
@inline function entropy(cons, equations::ShallowWaterEquations2D)
    energy_total(cons, equations)
end

# Calculate total energy for a conservative state `cons`
@inline function energy_total(cons, equations::ShallowWaterEquations2D)
    h, h_v1, h_v2, b = cons

    e = (h_v1^2 + h_v2^2) / (2 * h) + 0.5f0 * equations.gravity * h^2 +
        equations.gravity * h * b
    return e
end

# Calculate kinetic energy for a conservative state `cons`
@inline function energy_kinetic(u, equations::ShallowWaterEquations2D)
    h, h_v1, h_v2, _ = u
    return (h_v1^2 + h_v2^2) / (2 * h)
end

# Calculate potential energy for a conservative state `cons`
@inline function energy_internal(cons, equations::ShallowWaterEquations2D)
    return energy_total(cons, equations) - energy_kinetic(cons, equations)
end

# Calculate the error for the "lake-at-rest" test case where H = h+b should
# be a constant value over time.
@inline function lake_at_rest_error(u, equations::ShallowWaterEquations2D)
    h, _, _, b = u

    return abs(equations.H0 - (h + b))
end
end # @muladd
