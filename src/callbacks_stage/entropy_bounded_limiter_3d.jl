# By default, Julia/LLVM does not use fused multiply-add operations (FMAs).
# Since these FMAs can increase the performance of many numerical algorithms,
# we need to opt-in explicitly.
# See https://ranocha.de/blog/Optimizing_EC_Trixi for further details.
@muladd begin
#! format: noindent

function limiter_entropy_bounded!(u, u_prev, exp_entropy_decrease_max,
                                  mesh::AbstractMesh{3}, equations, dg::DGSEM, cache)
    @unpack weights = dg.basis
    @unpack inverse_jacobian = cache.elements

    @threaded for element in eachelement(dg, cache)
        # Minimum exponentiated entropy within the current `element`
        # of the previous iterate `u_prev`
        exp_s_min = typemax(eltype(u_prev))

        # Determine minimum value for entropy difference
        # Can use zero here since d_exp_s is defined as min{0, min_x exp_entropy_change(x)}
        d_exp_s_min = zero(eltype(u))
        for k in eachnode(dg), j in eachnode(dg), i in eachnode(dg)
            u_node = get_node_vars(u, equations, dg, i, j, k, element)
            u_node_prev = get_node_vars(u_prev, equations, dg, i, j, k, element)

            exp_s = exp(entropy_thermodynamic(u_node_prev, equations))
            exp_s_min = min(exp_s_min, exp_s)

            d_exp_s = exp_entropy_change(pressure(u_node, equations),
                                         density(u_node, equations),
                                         equations.gamma,
                                         exp_s)
            d_exp_s_min = min(d_exp_s_min, d_exp_s)
        end

        # Detect if limiting is necessary. Avoid division by ("near") zero
        d_exp_s_min < exp_entropy_decrease_max || continue

        # Compute mean value
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

        entropy_change_mean = exp_entropy_change(pressure(u_mean, equations),
                                                 density(u_mean, equations),
                                                 equations.gamma,
                                                 exp_s_min)

        epsilon = d_exp_s_min / (d_exp_s_min - entropy_change_mean)

        # In the derivation of the limiter it is assumed that 
        # entropy_change_mean >= 0 which would imply epsilon <= 1 (maximum limiting).
        # However, this might not always be the case in a simulation as 
        # we usually do not enforce the corresponding CFL condition from Lemma 3.
        # Thus, we clip epsilon at 1.
        if epsilon > 1
            epsilon = 1
        end

        for k in eachnode(dg), j in eachnode(dg), i in eachnode(dg)
            u_node = get_node_vars(u, equations, dg, i, j, k, element)
            set_node_vars!(u, (1 - epsilon) * u_node + epsilon * u_mean,
                           equations, dg, i, j, k, element)
        end
    end

    return nothing
end
end # @muladd
