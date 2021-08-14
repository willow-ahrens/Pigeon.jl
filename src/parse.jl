
const index_grammar = """
_hole: INTERPOLATE | slot
_holes: INTERPOLATE | slot | segment | splat

_statement: where | _producer
where: _statement _WHERE _producer
_producer: _hole | forall | assign | _OPEN_PAREN _statement _CLOSE_PAREN

forall: _FORALL (index | _holes) (_COMMA (index | _holes))* _statement
index: SYMBOL

assign: (access | _hole) [(operator | _holes)] _EQUALS _expression

operator: SYMBOL | PLUS | MINUS | TIMES | SLASH | CARET

access: (tensor | _hole) _OPEN_BRACKET [(index | _holes) ((_COMMA index) | (_COMMA _holes))*] _CLOSE_BRACKET
tensor: SYMBOL

_expression: add | subtract | negate | _term
add: _expression PLUS _term
subtract: _expression MINUS _term
negate: MINUS _term
_term: multiply | divide | _factor
multiply: _term TIMES _factor
divide: _term SLASH _factor
_factor: exponentiate | _base
exponentiate: _base CARET _factor
_base: _hole | LITERAL | _OPEN_PAREN _expression _CLOSE_PAREN | call | access
call: (operator | _hole) _OPEN_PAREN (_expression | segment | splat) (_COMMA (_expression | segment | splat))* _CLOSE_PAREN

slot: _APPROX SYMBOL
segment: _APPROX _APPROX SYMBOL
splat: _APPROX _APPROX SYMBOL _ELLIPSIS

PLUS: /\\+\\s*/
MINUS: /\\-\\s*/
TIMES: /\\*\\s*/
SLASH: /\\/\\s*/
CARET: /\\^\\s*/

_WHERE: /##where#\\s*/
_EQUALS: /\\=\\s*/
_COMMA: /,\\s*/
_APPROX: /~/
_ELLIPSIS: /\\.\\.\\.\\s*/
_OPEN_PAREN: /\\(\\s*/
_CLOSE_PAREN: /\\)\\s*/
_OPEN_BRACKET: /\\[\\s*/
_CLOSE_BRACKET: /\\]\\s*/
_FORALL: /##forall#\\s*/

LITERAL: /\\-?[0-9]+\\.[0-9]+\\s*/
SYMBOL: /[_A-Za-z][_A-Za-z0-9]*\\s*/
INTERPOLATE: /##interpolate#[0-9_]*\\s*/

%import common.SIGNED_NUMBER
%import common.CNAME
"""

const index_expression_parser = Lerche.Lark(
    "?start: _expression\n" * index_grammar,
    parser="lalr",lexer="contextual"
)

const index_statement_parser = Lerche.Lark(
    "?start: _statement\n" * index_grammar,
    parser="lalr",lexer="contextual"
)

struct TreeToConcrete <: Lerche.Transformer end

Lerche.@inline_rule where(t::TreeToConcrete, cons, prod) = :(Where($cons, $prod))
Lerche.@rule forall(t::TreeToConcrete, args) = :(Forall($(args...)))
Lerche.@inline_rule index(t::TreeToConcrete, name) = Index(name)
Lerche.@terminal PLUS(t::TreeToConcrete, _) = :+
Lerche.@terminal MINUS(t::TreeToConcrete, _) = :-
Lerche.@terminal TIMES(t::TreeToConcrete, _) = :*
Lerche.@terminal SLASH(t::TreeToConcrete, _) = :/
Lerche.@terminal CARET(t::TreeToConcrete, _) = :^
Lerche.@terminal SYMBOL(t::TreeToConcrete, name) = Symbol(strip(String(name), [' ',]))
Lerche.@terminal INTERPOLATE(t::TreeToConcrete, name) = Symbol(strip(String(name), [' ',]))
Lerche.@terminal LITERAL(t::TreeToConcrete, num) = parse(Int, strip(String(num), [' ',]))
Lerche.@inline_rule slot(t::TreeToConcrete, name) = esc(:(~$name))
Lerche.@inline_rule segment(t::TreeToConcrete, name) = esc(:(~~$name))
Lerche.@inline_rule splat(t::TreeToConcrete, name) = esc(:(~~$name...))
Lerche.@rule assign(t::TreeToConcrete, lhs_op_rhs) = :(Assign($(lhs_op_rhs...)))
Lerche.@inline_rule operator(t::TreeToConcrete, name) = Operator(name)
Lerche.@inline_rule access(t::TreeToConcrete, tns, idxs...) = :(Access($tns, $(idxs...)))
Lerche.@inline_rule tensor(t::TreeToConcrete, name) = Tensor(name)
Lerche.@inline_rule call(t::TreeToConcrete, f, args...) = :(Call($f, $(args...)))
Lerche.@inline_rule add(t::TreeToConcrete, arg1, f, arg2) = :(Call(Operator($f), $arg1, $arg2))
Lerche.@inline_rule subtract(t::TreeToConcrete, arg1, f, arg2) = :(Call(Operator($f), $arg1, $arg2))
Lerche.@inline_rule negate(t::TreeToConcrete, f, arg) = :(Call(Operator($f), $arg))
Lerche.@inline_rule multiply(t::TreeToConcrete, arg1, f, arg2) = :(Call(Operator($f), $arg1, $arg2))
Lerche.@inline_rule divide(t::TreeToConcrete, arg1, f, arg2) = :(Call(Operator($f), $arg1, $arg2))
Lerche.@inline_rule exponentiate(t::TreeToConcrete, arg1, f, arg2) = :(Call(Operator($f), $arg1, $arg2))

function preparse_index(s)
	s′ = []
	pos = 1
	thunk = Expr(:block)
	while (m = findnext("\$", s, pos)) !== nothing
        push!(s′, s[pos:first(m) - 1])
        pos = first(m) + 1
        (ex, pos′) = Meta.parse(s, pos, greedy=false)
        sym = gensym(:interpolate)
        push!(thunk.args, :($sym = esc($ex)))
        push!(s′, "$(string(sym))")
        pos = pos′
	end
    if pos < lastindex(s)
        push!(s′, s[pos:end])
    end
    s = join(s′, " ")
    s = replace(s, r"\n"=>" ")
    s = replace(s, r"∀|(\bfor\b)|(\bforall\b)"=>"##forall#")
    s = replace(s, r"(\bwhere\b)"=>"##where#")
    s = String(strip(s, [' ',]))
    (s, thunk)
end

function parse_index_expression(s)
    (s, thunk) = preparse_index(s)
    t = Lerche.parse(index_expression_parser,s) 
    push!(thunk.args, Lerche.transform(TreeToConcrete(),t))
    return thunk
end

function parse_index_statement(s)
    (s, thunk) = preparse_index(s)
    t = Lerche.parse(index_statement_parser,s) 
    push!(thunk.args, Lerche.transform(TreeToConcrete(),t))
    return thunk
end

macro is_str(s)
    return parse_index_statement(s)
end

macro ie_str(s)
    return parse_index_expression(s)
end

macro xrule(ex)
    return esc(:($SymbolicUtils.@rule $(macroexpand(__module__, ex))))
end

macro xarule(ex)
    return esc(:(SymbolicUtils.@ordered_acrule $(macroexpand(__module__, ex))))
end

macro xacrule(ex)
    return esc(:(SymbolicUtils.@acrule $(macroexpand(__module__, ex))))
end