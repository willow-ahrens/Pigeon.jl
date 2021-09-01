distributes(a, b) = false
distributes(a::IndexNode, b::IndexNode) = distributes(value(a), value(b))
distributes(a::typeof(+), b::typeof(*)) = true
distributes(a::typeof(+), b::typeof(-)) = true #should use a special operator here to mean "negation"

indices(stmt::Access) = collect(stmt.idxs)
indices(stmt::Loop) = union(indices(stmt.body), stmt.idxs)
indices(node) = istree(node) ? mapreduce(indices, union, push!(arguments(node), nothing)) : []

reducer(stmt::Assign) = stmt.op
reducer(stmt::Loop) = reducer(stmt.body)
reducer(stmt::With) = reducer(stmt.cons)

w₀ = Workspace(0)
w₁ = Workspace(1)
w₊ = Postwalk(node -> node isa Workspace ? Workspace(node.n + 1) : node)
w₋(_w) = Postwalk(node -> node isa Workspace ? (node.n == 1 ? _w : Workspace(node.n - 1)) : node)

function name_workspaces(prgm)
	w_n = 1
	Postwalk(PassThrough((node) -> if node isa With
	    w = access(Name(Symbol("w_$w_n")), intersect(indices(node.prod), indices(node.cons)))
	    w_n += 1
	    return w₋(w)(node)
	end))(prgm)
end

function saturate_index(stmt)
    normalize = Fixpoint(Postwalk(Chain([
        (@ex@rule i"∀ (~~i) ∀ (~~j) ~s"p => i"∀ (~~i), (~~j) ~s"c),
    ])))

    stmt = loop(stmt)
    (@ex@capture normalize(stmt) i"∀ (~~idxs) ~lhs <~~op>= ~rhs"p) ||
        throw(ArgumentError("expecting statement in index notation"))

    splay = Fixpoint(Postwalk(Chain([
        (@ex@rule i"+(~a, ~b, ~c, ~~d)"p => i"~a + +(~b, ~c, ~~d)"c),
        (@ex@rule i"+(~a)"p => ~a),
        (@ex@rule i"*(~a, ~b, ~c, ~~d)"p => i"~a * *(~b, ~c, ~~d)"c),
        (@ex@rule i"*(~a)"p => ~a),
        (@ex@rule i"~a - ~b"p => i"~a + (- ~b)"c),
        (@ex@rule i"- (- ~a)"p => ~a),
        (@ex@rule i"- +(~a, ~~b)"p => i"+(- ~a, - +(~~b))"c),
        (@ex@rule i"*(~~a, - ~b, ~~c)"p => i"-(*(~~a, ~b, ~~c))"c),
    ])))
    rhs = splay(rhs)

    churn = FixpointStep(PostwalkStep(ChainStep([
        (@ex@rule i"~a + (~b + ~c)"p => [i"(~a + ~b) + ~c"c]),
        (@ex@rule i"~a + ~b"p => [i"~b + ~a"c]),
        #(@ex@rule i"- ~a + (- ~b)"p => [i"-(~b + ~a)"c]),
        #(@ex@rule i"-(~a + ~b)"p => [i"- ~b + (- ~a)"c]),
        (@ex@rule i"~a * (~b * ~c)"p => [i"(~a * ~b) * ~c"c]),
        (@ex@rule i"~a * ~b"p => [i"~b * ~a"c]),
        #(@ex@rule i"~a * (- ~b)"p => [i"-(~a * ~b)"c]),
        #(@ex@rule i"-(~a * ~b)"p => [i"(- ~a) * ~b"c]),
        (@ex@rule i"~a * (~b + ~c)"p => [i"~a * ~b + ~a * ~c"]),
    ])))
    rhss = churn(rhs)

    decommute = Postwalk(Chain([
        (@ex@rule i"+(~~a)"p => if !issorted(~~a) i"+($(sort(~~a)))"c end),
        (@ex@rule i"*(~~a)"p => if !issorted(~~a) i"*($(sort(~~a)))"c end),
    ]))

    rhss = unique(map(decommute, rhss))

    bodies = map(rhs->i"$lhs <$op>=$rhs", rhss)

    #here, we only treat the second argument because we already did a bunch of churning earlier to consider different orders

    precompute = PrewalkStep(ChainStep([
        (x-> if @ex@capture x i"~Ai <~~f>= ~a"p
            bs = FixpointStep(PassThroughStep(@ex@rule i"(~g)(~~b)"p => ~~b))(a)
            ys = []
            for b in bs
                if b != a && @ex @capture b i"(~h)(~~c)"p
                    d = Postwalk(PassThrough(@ex@rule b => w₀))(a)
                    push!(ys, w₊(i"$Ai <$f>= $d with $w₀ = $b"))
                end
            end
            return ys
        end),
        (x-> if @ex@capture x i"~Ai <~f>= ~a"p
            bs = FixpointStep(PassThroughStep(@ex@rule i"(~g)(~~b)"p =>
                if distributes(f, ~g) ~~b end))(a)
            ys = []
            for b in bs
                if b != a && @ex @capture b i"(~h)(~~c)"p
                    d = Postwalk(PassThrough(@ex@rule b => w₀))(a)
                    push!(ys, w₊(i"$Ai <$f>= $d with $w₀ <$f>= $b"))
                end
            end
            return ys
        end),
    ]))

    slurp = Fixpoint(Postwalk(Chain([
        (@ex@rule i"+(~~a, +(~~b), ~~c)"p => i"+(~~a, ~~b, ~~c)"c),
        (@ex@rule i"+(~a)"p => ~a),
        (@ex@rule i"~a - ~b"p => i"~a + (- ~b)"c),
        (@ex@rule i"- (- ~a)"p => ~a),
        (@ex@rule i"- +(~a, ~~b)"p => i"+(- ~a, - +(~~b))"c),
        (@ex@rule i"*(~~a, *(~~b), ~~c)"p => i"*(~~a, ~~b, ~~c)"c),
        (@ex@rule i"*(~a)"p => ~a),
        (@ex@rule i"*(~~a, - ~b, ~~c)"p => i"-(*(~~a, ~b, ~~c))"c),
        (@ex@rule i"+(~~a)"p => if !issorted(~~a) i"+($(sort(~~a)))"c end),
        (@ex@rule i"*(~~a)"p => if !issorted(~~a) i"*($(sort(~~a)))"c end),
    ])))

    bodies = unique(mapreduce(body->map(slurp, precompute(body)), vcat, bodies))

    prgms = map(body->i"∀ ($idxs) $body", bodies)

    #absorb = PassThrough(@ex@rule i"∀ ~i ∀ ~~j ~s"p => i"∀ $(sort([~i; ~~j])) ~s"c)

    internalize = PrewalkStep(PassThroughStep(
        (x) -> if @ex @capture x i"∀ (~~is) (~c with ~p)"p
            if reducer(p) != nothing
                return map(combinations(intersect(is, indices(x)))) do js
                    i"""∀ ($(setdiff(is, js)))
                        ((∀ ($(intersect(js, indices(c)))) $c)
                      with
                        (∀ ($(intersect(js, indices(p)))) $p))
                    """
                end
            else
                return map(combinations(intersect(is, indices(p)))) do js
                    i"""∀ ($(setdiff(is, js)))
                        ((∀ ($(intersect(js, indices(c)))) $c)
                      with
                        (∀ ($js) $p))
                    """
                end
            end
        end
    ))
    prgms = mapreduce(internalize, vcat, prgms)
    prgms = map(Postwalk(PassThrough(@ex@rule i"∀ ($([]...)) ~s"p => ~s)), prgms)

    reorder = PrewalkStep(PassThroughStep(
        @ex@rule i"∀ (~~is) ~s"p => map(js-> i"∀ ($js) ~s"c, collect(permutations(~~is))[2:end])
    ))

    return map(name_workspaces, mapreduce(reorder, vcat, prgms))
end