abstract type AbstractReformatContext end

function transform_reformat(root)
    root = concordize(transform_ssa(root)) #in general, we don't need to concordize
    println(root)
    root = transform_reformat(root, RepermuteReadContext())
    root = transform_reformat(root, ReformatWorkspaceContext())
    root = transform_reformat(root, ReformatReadContext())
    root
end

transform_reformat(node, ctx) = transform_reformat(node, ctx, make_style(node, ctx))

function transform_reformat(node::Loop, ctx::AbstractReformatContext, ::DefaultStyle)
    isempty(node.idxs) && return transform_reformat(node.body, ctx)
    push!(ctx.qnt, node.idxs[1])
    body′ = transform_reformat(Loop(node.idxs[2:end], node.body), ctx)
    pop!(ctx.qnt)
    return Loop(Any[node.idxs[1]], body′)
end

function transform_reformat(node::With, ctx::AbstractReformatContext, ::DefaultStyle)
    prod = transform_reformat(node.prod, ctx)
    ctx.nest[getname(getresult(node.prod))] = length(ctx.qnt)
    cons = transform_reformat(node.cons, ctx)
    delete!(ctx.nest, getname(getresult(node.prod)))
    return With(cons, prod)
end

function transform_reformat(node, ctx::AbstractReformatContext, ::DefaultStyle)
    if istree(node)
        similarterm(node, operation(node), map(arg -> transform_reformat(arg, ctx), arguments(node)))
    else
        node
    end
end

struct ReformatSymbolicStyle
    style
end

combine_style(a::ReformatSymbolicStyle, b::DefaultStyle) = ReformatSymbolicStyle(result_style(a.style, b))
combine_style(a::ReformatSymbolicStyle, b::ReformatSymbolicStyle) = ReformatSymbolicStyle(result_style(a.style, b.style))

struct ReformatWorkspaceContext <: AbstractReformatContext
    qnt
    nest
end
ReformatWorkspaceContext() = ReformatWorkspaceContext([], Dict())
mutable struct ReformatWorkspaceCollectContext <: AbstractReformatContext
    qnt
    nest
    tns
    format
end
mutable struct ReformatWorkspaceSubstituteContext <: AbstractReformatContext
    qnt
    nest
    tns
    tns′
end
function transform_reformat(root::With, ctx::ReformatWorkspaceContext, style::ReformatSymbolicStyle)
    transform_reformat_workspace(root::With, ctx::ReformatWorkspaceContext, getresult(root.prod))
end
function transform_reformat_workspace(root::With, ctx::ReformatWorkspaceContext, tns::SymbolicHollowDirector)
    format = deepcopy(getformat(tns))
    transform_reformat(root, ReformatWorkspaceCollectContext(ctx.qnt, ctx.nest, tns.tns, format))
    tns′ = SymbolicHollowTensor(getname(tns), format, tns.tns.dims, tns.tns.default)
    prod′ = transform_reformat(transform_reformat(root.prod, ReformatWorkspaceSubstituteContext(ctx.qnt, ctx.nest, tns.tns, tns′)), ctx)
    cons′ = transform_reformat(transform_reformat(root.cons, ReformatWorkspaceSubstituteContext(ctx.qnt, ctx.nest, tns.tns, tns′)), ctx)
    return With(cons′, prod′)
end

make_style(node::With, ::ReformatWorkspaceContext, ::Access{SymbolicHollowDirector}) = ReformatSymbolicStyle(DefaultStyle())

function transform_reformat(node::Access{SymbolicHollowDirector}, ctx::ReformatWorkspaceCollectContext, ::DefaultStyle)
    if node.tns.tns == ctx.tns
        ctx.format .= map(widenformat, ctx.format, getprotocol(node.tns))
    end
    node
end
function transform_reformat(node::Access{SymbolicHollowDirector}, ctx::ReformatWorkspaceSubstituteContext, ::DefaultStyle)
    if node.tns.tns == ctx.tns
        tns′ = SymbolicHollowDirector(ctx.tns′, node.tns.protocol)
        return Access(tns′, node.mode, node.idxs)
    end
    return node
end

struct ReformatReadContext <: AbstractReformatContext
    qnt
    nest
end
ReformatReadContext() = ReformatReadContext([], Dict())
mutable struct ReformatReadTensorContext <: AbstractReformatContext
    qnt
    nest
    tnss
end
mutable struct ReformatReadCollectContext <: AbstractReformatContext
    qnt
    nest
    reqs
end
mutable struct ReformatReadSubstituteContext <: AbstractReformatContext
    qnt
    nest
    tns
    keep
    tns′
end
function transform_reformat(root, ctx::ReformatReadContext, style::ReformatSymbolicStyle)
    reqs = Dict()
    transform_reformat(root, ReformatReadCollectContext(ctx.qnt, ctx.nest, reqs))
    prods = []
    for (name, req) in pairs(reqs)
        if issubset(req.idxs, ctx.qnt) # && haskey(ctx.nest, name) || req.global
            format′ = req.format[req.keep : end]
            name′ = freshen(getname(req.tns))
            dims′ = req.tns.dims[req.keep : end]
            tns′ = SymbolicHollowTensor(name′, format′, dims′, req.tns.default)
            idxs′ = Any[Name(gensym()) for _ in format′]
            #for now, assume that a different pass will add "default" read/write protocols
            root = transform_reformat(root, ReformatReadSubstituteContext(ctx.qnt, ctx.nest, req.tns, req.keep, tns′))
            conv_protocol = Any[ConvertProtocol() for _ = 1:length(tns′.perm)]
            dir′ = SymbolicHollowDirector(tns′, conv_protocol)
            dir = SymbolicHollowDirector(req.tns, vcat(req.protocol, conv_protocol))
            push!(prods, @i (@loop $idxs′ $dir′[$idxs′] = $(dir)[$(req.idxs), $idxs′]))
        end
    end
    return foldl(with, prods, init = transform_reformat(root, ctx, style.style))
end
make_style(node, ::ReformatReadContext, ::Access{SymbolicHollowDirector, Read}) = ReformatSymbolicStyle(DefaultStyle())
mutable struct ReformatReadRequest
    tns
    keep
    idxs
    protocol
    format
end
function transform_reformat(node::Access{SymbolicHollowDirector, Read}, ctx::ReformatReadCollectContext, ::DefaultStyle)
    name = getname(node.tns)
    protocol = getprotocol(node.tns)
    format = getformat(node.tns)
    top = get(ctx.nest, name, 0)
    if !all(i -> hasprotocol(format[i], protocol[i]), 1:length(format))
        req = get!(ctx.reqs, name, ReformatReadRequest(node.tns.tns, length(protocol), node.idxs, deepcopy(protocol), Any[NoFormat() for _ in format]))
        keep = findfirst(1:length(format)) do i
            !(i <= req.keep &&
                ctx.qnt[top + i] == node.idxs[i] &&
                hasprotocol(format[i], protocol[i]) &&
                protocol[i] == req.protocol[i])
        end
        req.keep = min(req.keep, keep)
        req.idxs = intersect(req.idxs, node.idxs[1:keep-1])
        req.protocol = protocol[1:keep-1]
        req.format .= map(widenformat, req.format, protocol)
    end
    return node
end
function transform_reformat(node::Access{SymbolicHollowDirector}, ctx::ReformatReadSubstituteContext, ::DefaultStyle)
    if node.tns.tns == ctx.tns
        if !all(i -> hasprotocol(getformat(node.tns)[i], getprotocol(node.tns)[i]), 1:length(getformat(node.tns)))
            return Access(SymbolicHollowDirector(ctx.tns′, getprotocol(node.tns)[ctx.keep:end]), node.mode, node.idxs[ctx.keep:end])
        end
    end
    return node
end

struct RepermuteReadContext <: AbstractReformatContext
    qnt
    nest
end
RepermuteReadContext() = RepermuteReadContext([], Dict())
mutable struct RepermuteReadTensorContext <: AbstractReformatContext
    qnt
    nest
    tnss
end
mutable struct RepermuteReadCollectContext <: AbstractReformatContext
    qnt
    nest
    reqs
end
mutable struct RepermuteReadSubstituteContext <: AbstractReformatContext
    qnt
    nest
    tns
    keep
    perm
    tns′
end
function transform_reformat(root, ctx::RepermuteReadContext, style::ReformatSymbolicStyle)
    reqs = Dict()
    transform_reformat(root, RepermuteReadCollectContext(ctx.qnt, ctx.nest, reqs))
    prods = []
    for ((name, perm), req) in pairs(reqs)
        if issubset(req.idxs, ctx.qnt) # && haskey(ctx.nest, name) || req.global
            format′ = Any[NoFormat() for i = req.keep : length(getsites(req.tns))]
            name′ = freshen(getname(req.tns))
            dims′ = req.tns.dims[req.keep : end]
            tns′ = SymbolicHollowTensor(name′, format′, dims′, req.tns.default)
            idxs′ = [Name(gensym()) for _ in format′]
            #for now, assume that a different pass will add "default" read/write protocols
            root = transform_reformat(root, RepermuteReadSubstituteContext(ctx.qnt, ctx.nest, req.tns, req.keep, perm, tns′))
            conv_protocol = [ConvertProtocol() for _ = 1:length(tns′.perm)]
            dir′ = SymbolicHollowDirector(tns′, conv_protocol)
            dir = SymbolicHollowDirector(req.tns, vcat(req.protocol, conv_protocol))
            push!(prods, @i (@loop $idxs′ $dir′[$idxs′] = $dir[$(req.idxs), $(idxs′[perm[req.keep:end] .- req.keep .+ 1])]))
        end
    end
    return foldl(with, prods, init = transform_reformat(root, ctx, style.style))
end
make_style(node, ::RepermuteReadContext, ::Access{SymbolicHollowDirector, Read}) = ReformatSymbolicStyle(DefaultStyle())
mutable struct RepermuteReadRequest
    tns
    keep
    idxs
    protocol
end
function transform_reformat(node::Access{SymbolicHollowDirector, Read}, ctx::RepermuteReadCollectContext, ::DefaultStyle)
    name = getname(node.tns)
    protocol = getprotocol(node.tns)
    perm = node.tns.perm

    top = get(ctx.nest, name, 0)
    println(perm)
    if !all(i -> (i == perm[i]), 1:length(perm))
        req = get!(ctx.reqs, (name, perm), RepermuteReadRequest(node.tns.tns, length(protocol), node.idxs, deepcopy(protocol)))
        keep = findfirst(1:length(perm)) do i
            !(i <= req.keep &&
                ctx.qnt[top + i] == node.idxs[i] &&
                protocol[i] == req.protocol[i] &&
                perm[i] == i)
        end
        req.keep = min(req.keep, keep)
        req.idxs = intersect(req.idxs, node.idxs[1:keep-1])
        req.protocol = protocol[1:keep-1]
    end
    return node
end

function transform_reformat(node::Access{SymbolicHollowDirector}, ctx::RepermuteReadSubstituteContext, ::DefaultStyle)
    if node.tns.tns == ctx.tns && node.tns.perm == ctx.perm
        return Access(SymbolicHollowDirector(ctx.tns′, getprotocol(node.tns)[ctx.keep:end]), node.mode, node.idxs[ctx.keep:end])
    end
    return node
end