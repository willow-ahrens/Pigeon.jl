mutable struct SparseFiberRelation
    name
    format
    dims
    default
    perm
    implicit
end
Base.copy(tns::SparseFiberRelation) = SparseFiberRelation(
    tns.name,
    tns.format,
    tns.dims,
    tns.default,
    tns.perm,
    tns.implicit)

#TODO this type probably needs a rework, but we will wait till we see what the enumerator needs
SparseFiberRelation(name, format, dims) = SparseFiberRelation(name, format, dims, 0)
SparseFiberRelation(name, format, dims, default) = SparseFiberRelation(name, format, dims, default, collect(1:length(dims)), false)

function show_expression(io, mime, ex::SparseFiberRelation)
    print(io, ex.name)
    print(io, "{")
    if length(ex.format) >= 1
        for lvl in ex.format
            show_expression(io, mime, lvl)
        end
    end
    print(io, "}")
end

mutable struct DenseRelation
    name
    dims
    perm
end
Base.copy(tns::DenseRelation) = DenseRelation(
    tns.name,
    tns.dims,
    tns.perm)

#TODO this type probably needs a rework, but we will wait till we see what the enumerator needs
DenseRelation(name, dims) = DenseRelation(name, dims, collect(1:length(dims)))

function show_expression(io, mime, ex::DenseRelation)
    print(io, ex.name)
end

#=
function retranspose(acc::Access{<:SparseFiberRelation}, σ)
    return Access(tns, acc.mode, acc.idxs[σ])
end

function concordize()
=#

function retranspose(tns::SparseFiberRelation, σ)
    tns = copy(tns)
    tns.perm = tns.perm[σ]
    tns.format = tns.format[σ]
    tns.dims = tns.dims[σ]
    return (tns, σ)
end

function retranspose(tns::DenseRelation, σ)
    tns = copy(tns)
    tns.perm = tns.perm[σ]
    tns.dims = tns.dims[σ]
    return (tns, σ)
end

getname(tns::SparseFiberRelation) = tns.name
rename(tns::SparseFiberRelation, name) = (tns = Base.copy(tns); tns.name = name; tns)

getname(tns::DenseRelation) = tns.name
rename(tns::DenseRelation, name) = (tns = Base.copy(tns); tns.name = name; tns)

function saturate_formats(tns::SparseFiberRelation)
    result = []
    for format in product(tns.format...)
        tns′ = copy(tns)
        tns′.format = collect(format)
        push!(result, tns′)
    end
    result
end

const Fiber = SparseFiberRelation
const Dense = DenseRelation

initialize(tns::SparseFiberRelation) = (tns.data = PointQuery(false))
implicitize(tns::SparseFiberRelation) = (tns = copy(tns); tns.implicit = true; tns)
isimplicit(tns::SparseFiberRelation) = tns.implicit

struct CoiterateRelator end
struct LocateRelator end

const coiter = CoiterateRelator()
const locate = LocateRelator()

function show_expression(io, mime, ex::CoiterateRelator)
    print(io, "c")
end
function show_expression(io, mime, ex::LocateRelator)
    print(io, "l")
end

mutable struct AsymptoticContext
    itrs::Any
    qnts::Vector{Any}
    guards::Vector{Any}
    state::Dict
    dims
end

function getdata(tns::SparseFiberRelation, ctx::AsymptoticContext)
    default = PointQuery(Predicate(getname(tns), [CanonVariable(n) for n in tns.perm]...))
    get!(ctx.state, getname(tns), default)
end

lower_axes(tns::SparseFiberRelation, ::AsymptoticContext) = tns.dims
lower_axes(tns::SparseFiberRelation, ::DimensionalizeWorkspaceContext{AsymptoticContext}) = tns.dims
lower_sites(tns::SparseFiberRelation) = tns.perm
lower_axes(tns::DenseRelation, ::AsymptoticContext) = tns.dims
lower_axes(tns::DenseRelation, ::DimensionalizeWorkspaceContext{AsymptoticContext}) = tns.dims
lower_sites(tns::DenseRelation) = tns.perm
lower_axis_merge(::AsymptoticContext, a, b) = (@assert a == b; b)
lower_axis_merge(::DimensionalizeWorkspaceContext{AsymptoticContext}, a, b) = (@assert a == b; b)

AsymptoticContext() = AsymptoticContext(Empty(), [], [true], Dict(), Dimensions())

getdims(ctx::AsymptoticContext) = ctx.dims

function asymptote(prgm, ctx = AsymptoticContext())
    #TODO messy
    prgm = transform_ssa(prgm)
    lower!(prgm, ctx)
    return ctx.itrs
end

function read_cost(tns::SparseFiberRelation, ctx = AsymptoticContext())
    idxs = [gensym() for _ in tns.format]
    pred = getdata(tns, ctx)[Name.(idxs)...]
    return Such(Times(Domain.(idxs, tns.dims)...), pred)
end

function read_cost(tns::DenseRelation, ctx = AsymptoticContext())
    idxs = [gensym() for _ in tns.dims]
    return Times(Domain.(idxs, tns.dims)...)
end

function assume_nonempty(tns::SparseFiberRelation)
    idxs = [gensym() for _ in tns.format]
    return Exists(idxs..., Predicate(getname(tns), idxs...))
end

iterate!(ctx) = iterate!(ctx, true)
function iterate!(ctx, cond)
    qnts = map(qnt->Domain(getname(qnt), ctx.dims[getname(qnt)]), ctx.qnts)
    ctx.itrs = Cup(ctx.itrs, Such(Times(qnts...), Wedge(guard(ctx), cond)))
end

quantify(f, ctx, var) = (push!(ctx.qnts, var); f(); pop!(ctx.qnts))
enguard(f, ctx, cond) = (push!(ctx.guards, cond); f(); pop!(ctx.guards))
guard(ctx) = reduce(Wedge, ctx.guards)

lower!(::Pass, ::AsymptoticContext, ::DefaultStyle) = nothing

#assumes unique foralls
function lower!(root::Assign, ctx::AsymptoticContext, ::DefaultStyle)
    iterate!(ctx)
end

function lower!(stmt::Loop, ctx::AsymptoticContext, ::DefaultStyle)
    isempty(stmt.idxs) && return lower!(stmt.body, ctx)
    quantify(ctx, stmt.idxs[1]) do
        iterate!(ctx)
        lower!(Loop(stmt.idxs[2:end], stmt.body), ctx)
    end
end

function lower!(stmt::With, ctx::AsymptoticContext, ::DefaultStyle)
    initialize!(getresult(stmt.prod), ctx)
    lower!(stmt.prod, ctx)
    lower!(stmt.cons, ctx)
end

struct CoiterateStyle
end

#TODO handle children of access?
function make_style(root, ctx::AsymptoticContext, node::Access{SparseFiberRelation})
    isdimensionalized(getdims(ctx), node) || return DimensionalizeStyle()
    return DefaultStyle()
end

function make_style(root, ctx::AsymptoticContext, node::Access{DenseRelation})
    isdimensionalized(getdims(ctx), node) || return DimensionalizeStyle()
    return DefaultStyle()
end

function make_style(root::Loop, ctx::AsymptoticContext, node::Access{SparseFiberRelation})
    isdimensionalized(getdims(ctx), node) || return DimensionalizeStyle()
    isempty(root.idxs) && return DefaultStyle()
    i = findfirst(isequal(root.idxs[1]), node.idxs)
    (i !== nothing && node.idxs[1:i-1] ⊆ ctx.qnts) || return DefaultStyle()
    node.tns.format[i] === coiter || return DefaultStyle()
    return CoiterateStyle()
end
combine_style(a::CoiterateStyle, b::CoiterateStyle) = CoiterateStyle()
combine_style(a::CoiterateStyle, b::DimensionalizeStyle) = DimensionalizeStyle()
combine_style(a::DefaultStyle, b::DimensionalizeStyle) = DimensionalizeStyle()
combine_style(a::DimensionalizeStyle, b::DimensionalizeStyle) = DimensionalizeStyle()

#TODO generalize the interface to annihilation analysis
annihilate_index = Fixpoint(Prewalk(Chain([
    (@ex@rule @i((~f)(~~a)) => if isliteral(~f) && all(isliteral, ~~a) Literal(value(~f)(value.(~~a)...)) end),
    (@ex@rule @i((~~a, +(~~b), ~~c)) => @i +(~~a, ~~b, ~~c)),
    (@ex@rule @i(+(~~a)) => if count(isliteral, ~~a) >= 2 @i +($(filter(!isliteral, ~~a)), $(Literal(+(value.(filter(isliteral, ~~a))...)))) end),
    (@ex@rule @i(+(~~a, 0, ~~b)) => @i +(~~a, ~~b)),

    (@ex@rule @i(*(~~a, *(~~b), ~~c)) => @i *(~~a, ~~b, ~~c)),
    (@ex@rule @i(*(~~a)) => if count(isliteral, ~~a) >= 2 @i(*($(filter(!isliteral, ~~a)), $(Literal(*(value.(filter(isliteral, ~~a))...))))) end),
    (@ex@rule @i(*(~~a, 1, ~~b)) => @i *(~~a, ~~b)),
    (@ex@rule @i(*(~~a, 0, ~~b)) => 0),

    (@ex@rule @i(+(~a)) => ~a),
    (@ex@rule @i(~a - ~b) => @i ~a + - ~b),
    (@ex@rule @i(- (- ~a)) => ~a),
    (@ex@rule @i(- +(~a, ~~b)) => @i +(- ~a, - +(~~b))),
    (@ex@rule @i(*(~a)) => ~a),
    (@ex@rule @i(*(~~a, - ~b, ~~c)) => @i -(*(~~a, ~b, ~~c))),

    #(@ex@rule @i(+(~~a)) => if !issorted(~~a) @i +($(sort(~~a))) end),
    #(@ex@rule @i(*(~~a)) => if !issorted(~~a) @i *($(sort(~~a))) end),

    (@ex@rule @i((~a)[~~i] = 0) => pass(~a)), #TODO this is only valid when the default of A is 0
    (@ex@rule @i((~a)[~~i] += 0) => pass(~a)),
    (@ex@rule @i((~a)[~~i] *= 1) => pass(~a)),

    (@ex@rule @i((~a)[~~i] *= ~b) => if isimplicit(~a) && (~a).default == 0 pass(~a) end),
    (@ex@rule @i((~a)[~~i] = ~b) => if isimplicit(~a) && (~a).default == ~b pass(~a) end),
    ((a) -> if a isa Literal && isliteral(value(a)) value(a) end), #only quote when necessary

    (@ex@rule @i(@loop (~~i) @pass(~~a)) => pass(~~a)),
    (@ex@rule @i(@pass(~~a) where ~x) => pass(~~a)),
    #(@ex@rule @i(~x where @pass(~~a)) => ~x), #can't do this bc produced tensors won't get initialized
])))

function lower!(stmt::Loop, ctx::AsymptoticContext, ::CoiterateStyle)
    isempty(stmt.idxs) && return ctx(stmt.body)
    quantify(ctx, stmt.idxs[1]) do
        stmt′ = Loop(stmt.idxs[2:end], stmt.body)
        cases = coiterate_cases(stmt, ctx, stmt′)
        for (guard, body) in cases
            enguard(ctx, guard) do
                lower!(annihilate_index(body), ctx)
            end
        end
        coiterate_asymptote!(stmt, ctx, stmt′)
    end
end

function coiterate_asymptote!(root, ctx, node)
    if istree(node)
        return mapreduce(arg->coiterate_asymptote!(root, ctx, arg), Cup, arguments(node))
    else
        return Empty()
    end
end

function coiterate_asymptote!(root, ctx, stmt::Access{SparseFiberRelation})
    i = findfirst(isequal(root.idxs[1]), stmt.idxs)
    (i !== nothing && stmt.idxs[1:i] ⊆ ctx.qnts) || return Empty()
    stmt.tns.format[i] === coiter || return Empty() #TODO this line isn't extensible
    pred = Exists(getname.(setdiff(stmt.idxs, ctx.qnts))..., getdata(stmt.tns, ctx)[stmt.idxs...])
    return iterate!(ctx, pred)
end

function coiterate_cases(root, ctx, node)
    if istree(node)
        map(product(map(arg->coiterate_cases(root, ctx, arg), arguments(node))...)) do case
            (guards, bodies) = zip(case...)
            (reduce(Wedge, guards), operation(node)(bodies...))
        end
    else
        [(true, node),]
    end
end
function coiterate_cases(root, ctx::AsymptoticContext, stmt::Access{SparseFiberRelation})
    single = [(true, stmt),]
    i = findfirst(isequal(root.idxs[1]), stmt.idxs)
    (i !== nothing && stmt.idxs[1:i] ⊆ ctx.qnts) || return single
    stmt.tns.format[i] === coiter || return single
    stmt′ = stmt.mode === Read() ? stmt.tns.default : Access(implicitize(stmt.tns), stmt.mode, stmt.idxs)
    pred = Exists(getname.(setdiff(stmt.idxs, ctx.qnts))..., getdata(stmt.tns, ctx)[stmt.idxs...])
    return [(pred, stmt), (true, stmt′),]
end

function lower!(root::Assign{<:Access{SparseFiberRelation}}, ctx::AsymptoticContext, ::DefaultStyle)
    iterate!(ctx)
    pred = Exists(getname.(setdiff(ctx.qnts, root.lhs.idxs))..., guard(ctx))
    getdata(root.lhs.tns, ctx)[root.lhs.idxs...] = pred
end

function initialize!(tns::SparseFiberRelation, ctx::AsymptoticContext)
    ctx.state[getname(tns)] = PointQuery(false)
end

using Random

function filter_pareto(kernels; sunk_costs=[], assumptions=[])
    pareto = []
    lower_time = 0
    supersimplify_time = 0
    filter_time = 0
    global simplify_time = 0
    global normalize_time = 0
    global normalize_calls = 0
    global dominate_calls = 0
    asymptotes = @showprogress 0.1 "analysis..." map(kernel->begin
        #supersimplify_asymptote(Cup(asymptote(kernel), sunk_costs...))
        lower_time += @elapsed a = asymptote(kernel)
        supersimplify_time += @elapsed a = supersimplify_asymptote(Cup(a, sunk_costs...))
        #supersimplify_time += @elapsed a = normalize_asymptote(Cup(a, sunk_costs...))
        a;
    end, kernels)
    #foreach(display, asymptotes)
    @showprogress 1 "filtering..." for (a, asy_a) in collect(zip(kernels, asymptotes))[randperm(end)]
        pareto′ = Any[(a, asy_a)]
        filter_time += @elapsed begin
            keep = true
            for (b, asy_b) in pareto
                dom_a = isdominated(asy_a, asy_b, assumptions=assumptions)
                dom_b = isdominated(asy_b, asy_a, assumptions=assumptions)
                if dom_b && !dom_a
                    keep = false
                    break
                elseif !(dom_a && !dom_b)
                    push!(pareto′, (b, asy_b))
                end
            end
            if keep
                pareto = pareto′
            end
        end
    end

    @info "breakdown" lower_time supersimplify_time filter_time simplify_time normalize_time normalize_calls normalize_time/normalize_calls dominate_calls
    return first.(pareto)
end
