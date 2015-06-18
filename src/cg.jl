# Preconditioners
#  * Empty preconditioner
cg_precondfwd(out::Array, P::Nothing, A::Array) = copy!(out, A)
cg_precondfwddot(A::Array, P::Nothing, B::Array) = _dot(A, B)
cg_precondinvdot(A::Array, P::Nothing, B::Array) = _dot(A, B)

# Diagonal preconditioner
function cg_precondfwd(out::Array, p::Vector, A::Array)
    for i in 1:length(A)
        @inbounds out[i] = p[i] * A[i]
    end
    return out
end
function cg_precondfwddot{T}(A::Array{T}, p::Vector, B::Array)
    s = zero(T)
    for i in 1:length(A)
        @inbounds s += A[i] * p[i] * B[i]
    end
    return s
end
function cg_precondinvdot{T}(A::Array{T}, p::Vector, B::Array)
    s = zero(T)
    for i in 1:length(A)
        @inbounds s += A[i] * B[i] / p[i]
    end
    return s
end

#
# Conjugate gradient
#
# This is an independent implementation of:
#   W. W. Hager and H. Zhang (2006) Algorithm 851: CG_DESCENT, a
#     conjugate gradient method with guaranteed descent. ACM
#     Transactions on Mathematical Software 32: 113–137.
#
# Code comments such as "HZ, stage X" or "HZ, eqs Y" are with
# reference to a particular point in this paper.
#
# Several aspects of the following have also been incorporated:
#   W. W. Hager and H. Zhang (2012) The limited memory conjugate
#     gradient method.
#
# This paper will be denoted HZ2012 below.
#
# There are some modifications and/or extensions from what's in the
# paper (these may or may not be extensions of the cg_descent code
# that can be downloaded from Hager's site; his code has undergone
# numerous revisions since publication of the paper):
#
# cgdescent: the termination condition employs a "unit-correct"
#   expression rather than a condition on gradient
#   components---whether this is a good or bad idea will require
#   additional experience, but preliminary evidence seems to suggest
#   that it makes "reasonable" choices over a wider range of problem
#   types.
#
# linesearch: the Wolfe conditions are checked only after alpha is
#   generated either by quadratic interpolation or secant
#   interpolation, not when alpha is generated by bisection or
#   expansion. This increases the likelihood that alpha will be a
#   good approximation of the minimum.
#
# linesearch: In step I2, we multiply by psi2 only if the convexity
#   test failed, not if the function-value test failed. This
#   prevents one from going uphill further when you already know
#   you're already higher than the point at alpha=0.
#
# both: checks for Inf/NaN function values
#
# both: support maximum value of alpha (equivalently, c). This
#   facilitates using these routines for constrained minimization
#   when you can calculate the distance along the path to the
#   disallowed region. (When you can't easily calculate that
#   distance, it can still be handled by returning Inf/NaN for
#   exterior points. It's just more efficient if you know the
#   maximum, because you don't have to test values that won't
#   work.) The maximum should be specified as the largest value for
#   which a finite value will be returned.  See, e.g., limits_box
#   below.  The default value for alphamax is Inf. See alphamaxfunc
#   for cgdescent and alphamax for linesearch_hz.

macro cgtrace()
    quote
        if tracing
            dt = Dict()
            if extended_trace
                dt["x"] = copy(x)
                dt["g(x)"] = copy(gr)
                dt["Current step size"] = alpha
            end
            grnorm = norm(gr[:], Inf)
            update!(tr,
                    iteration,
                    f_x,
                    grnorm,
                    dt,
                    store_trace,
                    show_trace)
        end
    end
end

function cg{T}(df::Union(DifferentiableFunction,
                         TwiceDifferentiableFunction),
               initial_x::Array{T};
               xtol::Real = convert(T,1e-32),
               ftol::Real = convert(T,1e-8),
               grtol::Real = convert(T,1e-8),
               iterations::Integer = 1_000,
               store_trace::Bool = false,
               show_trace::Bool = false,
               extended_trace::Bool = false,
               linesearch!::Function = hz_linesearch!,
               eta::Real = convert(T,0.4),
               P::Any = nothing,
               precondprep::Function = (P, x) -> nothing)

    # Maintain current state in x and previous state in x_previous
    x, x_previous = copy(initial_x), copy(initial_x)

    # Count the total number of iterations
    iteration = 0

    # Track calls to function and gradient
    f_calls, g_calls = 0, 0

    # Count number of parameters
    n = length(x)

    # Maintain current gradient in gr and previous gradient in gr_previous
    gr, gr_previous = similar(x), similar(x)

    # Maintain the preconditioned gradient in pgr
    pgr = similar(x)

    # The current search direction
    s = similar(x)

    # Buffers for use in line search
    x_ls, gr_ls = similar(x), similar(x)

    # Intermediate value in CG calculation
    y = similar(x)

    # Store f(x) in f_x
    f_x = df.fg!(x, gr)
    @assert typeof(f_x) == T
    f_x_previous = convert(T, NaN)
    f_calls, g_calls = f_calls + 1, g_calls + 1
    copy!(gr_previous, gr)

    # Keep track of step-sizes
    alpha = alphainit(one(T), x, gr, f_x)

    # TODO: How should this flag be set?
    mayterminate = false

    # Maintain a cache for line search results
    lsr = LineSearchResults(T)

    # Trace the history of states visited
    tr = OptimizationTrace()
    tracing = store_trace || show_trace || extended_trace
    @cgtrace

    # Output messages
    if !isfinite(f_x)
        error("Must have finite starting value")
    end
    if !all(isfinite(gr))
        @show gr
        @show find(!isfinite(gr))
        error("Gradient must have all finite values at starting point")
    end

    # Determine the intial search direction
    precondprep(P, x)
    cg_precondfwd(s, P, gr)
    for i in 1:n
        @inbounds s[i] = -s[i]
    end

    # Assess multiple types of convergence
    x_converged, f_converged, gr_converged = false, false, false

    # Iterate until convergence
    converged = false
    while !converged && iteration < iterations
        # Increment the number of steps we've had to perform
        iteration += 1

        # Reset the search direction if it becomes corrupted
        dphi0 = _dot(gr, s)
        if dphi0 >= 0
            for i in 1:n
                @inbounds s[i] = -gr[i]
            end
            dphi0 = _dot(gr, s)
            if dphi0 < 0
                break
            end
        end

        # Refresh the line search cache
        clear!(lsr)
        @assert typeof(f_x) == T
        @assert typeof(dphi0) == T
        push!(lsr, zero(T), f_x, dphi0)

        # Pick the initial step size (HZ #I1-I2)
        alpha, mayterminate, f_update, g_update =
          alphatry(alpha, df, x, s, x_ls, gr_ls, lsr)
        f_calls, g_calls = f_calls + f_update, g_calls + g_update

        # Determine the distance of movement along the search line
        alpha, f_update, g_update =
          linesearch!(df, x, s, x_ls, gr_ls, lsr, alpha, mayterminate)
        f_calls, g_calls = f_calls + f_update, g_calls + g_update

        # Maintain a record of previous position
        copy!(x_previous, x)

        # Update current position
        for i in 1:n
            @inbounds x[i] = x[i] + alpha * s[i]
        end

        # Maintain a record of the previous gradient
        copy!(gr_previous, gr)

        # Update the function value and gradient
        f_x_previous, f_x = f_x, df.fg!(x, gr)
        f_calls, g_calls = f_calls + 1, g_calls + 1

        x_converged,
        f_converged,
        gr_converged,
        converged = assess_convergence(x,
                                       x_previous,
                                       f_x,
                                       f_x_previous,
                                       gr,
                                       xtol,
                                       ftol,
                                       grtol)

        # Check sanity of function and gradient
        if !isfinite(f_x)
            error("Function must finite function values")
        end

        # Determine the next search direction using HZ's CG rule
        #  Calculate the beta factor (HZ2012)
        precondprep(P, x)
        dPd = cg_precondinvdot(s, P, s)
        etak::T = eta * _dot(s, gr_previous) / dPd
        for i in 1:n
            @inbounds y[i] = gr[i] - gr_previous[i]
        end
        ydots = _dot(y, s)
        cg_precondfwd(pgr, P, gr)
        betak = (_dot(y, pgr) - cg_precondfwddot(y, P, y) *
                 _dot(gr, s) / ydots) / ydots
        beta = max(betak, etak)
        for i in 1:n
            @inbounds s[i] = beta * s[i] - pgr[i]
        end

        @cgtrace
    end

    return MultivariateOptimizationResults("Conjugate Gradient",
                                           initial_x,
                                           x,
                                           @compat(Float64(f_x)),
                                           iteration,
                                           iteration == iterations,
                                           x_converged,
                                           xtol,
                                           f_converged,
                                           ftol,
                                           gr_converged,
                                           grtol,
                                           tr,
                                           f_calls,
                                           g_calls)
end
