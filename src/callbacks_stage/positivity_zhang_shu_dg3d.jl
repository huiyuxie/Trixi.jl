# By default, Julia/LLVM does not use fused multiply-add operations (FMAs).
# Since these FMAs can increase the performance of many numerical algorithms,
# we need to opt-in explicitly.
# See https://ranocha.de/blog/Optimizing_EC_Trixi for further details.
@muladd begin
#! format: noindent

function limiter_zhang_shu!(u, threshold::Real, variable,
                            mesh::AbstractMesh{3}, equations, dg::DGSEM, cache)
    @unpack weights = dg.basis
    @unpack inverse_jacobian = cache.elements

    @threaded for element in eachelement(dg, cache)
        # determine minimum value
        value_min = typemax(eltype(u))
        for k in eachnode(dg), j in eachnode(dg), i in eachnode(dg)
            u_node = get_node_vars(u, equations, dg, i, j, k, element)
            value_min = min(value_min, variable(u_node, equations))
        end

        # detect if limiting is necessary
        value_min < threshold || continue

        # compute mean value
        u_mean = zero(get_node_vars(u, equations, dg, 1, 1, 1, element))
        total_volume = zero(eltype(u))
        for k in eachnode(dg), j in eachnode(dg), i in eachnode(dg)
            volume_jacobian = abs(inv(get_inverse_jacobian(inverse_jacobian, mesh,
                                                           i, j, k, element)))
            u_node = get_node_vars(u, equations, dg, i, j, k, element)
            u_mean += u_node * weights[i] * weights[j] * weights[k] * volume_jacobian
            total_volume += weights[i] * weights[j] * weights[k] * volume_jacobian
        end
        # normalize with the total volume
        u_mean = u_mean / total_volume

        # We compute the value directly with the mean values, as we assume that
        # Jensen's inequality holds (e.g. pressure for compressible Euler equations).
        value_mean = variable(u_mean, equations)
        theta = (value_mean - threshold) / (value_mean - value_min)
        for k in eachnode(dg), j in eachnode(dg), i in eachnode(dg)
            u_node = get_node_vars(u, equations, dg, i, j, k, element)
            set_node_vars!(u, theta * u_node + (1 - theta) * u_mean,
                           equations, dg, i, j, k, element)
        end
    end

    return nothing
end
end # @muladd
