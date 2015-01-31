module CoinOptServices

using MathProgBase, LightXML, Compat
importall MathProgBase.SolverInterface

debug = true # (ccall(:jl_is_debugbuild, Cint, ()) == 1)
if debug
    macro assertequal(x, y)
        msg = "Expected $x == $y, got "
        :($x == $y ? nothing : error($msg, repr($x), " != ", repr($y)))
    end
else
    macro assertequal(x, y)
    end
end

include("translations.jl")

depsjl = Pkg.dir("CoinOptServices", "deps", "deps.jl")
isfile(depsjl) ? include(depsjl) : error("CoinOptServices not properly " *
    "installed. Please run\nPkg.build(\"CoinOptServices\")")
OSSolverService = joinpath(dirname(libOS), "..", "bin", "OSSolverService")
osildir = Pkg.dir("CoinOptServices", ".osil")

export OsilSolver
immutable OsilSolver <: AbstractMathProgSolver
    solver::String
    osil::String
    osol::String
    osrl::String
    options
end
OsilSolver(;
    solver = "",
    osil = joinpath(osildir, "problem.osil"),
    osol = joinpath(osildir, "options.osol"),
    osrl = joinpath(osildir, "results.osrl"),
    options...) = OsilSolver(solver, osil, osol, osrl, options)

type OsilMathProgModel <: AbstractMathProgModel
    solver::String
    osil::String
    osol::String
    osrl::String
    options

    numberOfVariables::Int
    numberOfConstraints::Int
    xl::Vector{Float64}
    xu::Vector{Float64}
    cl::Vector{Float64}
    cu::Vector{Float64}
    objsense::Symbol
    d::AbstractNLPEvaluator

    numLinConstr::Int
    vartypes::Vector{Symbol}
    x0::Vector{Float64}

    objval::Float64
    solution::Vector{Float64}
    reducedcosts::Vector{Float64}
    constrduals::Vector{Float64}
    status::Symbol

    xdoc::XMLDocument # TODO: finalizer
    instanceData::XMLElement
    obj::XMLElement
    vars::Vector{XMLElement}
    cons::Vector{XMLElement}

    function OsilMathProgModel(solver, osil, osol, osrl; options...)
        new(solver, osil, osol, osrl, options)
    end
end

MathProgBase.model(s::OsilSolver) =
    OsilMathProgModel(s.solver, s.osil, s.osol, s.osrl; s.options...)


function create_osil_common!(m::OsilMathProgModel, xl, xu, cl, cu, objsense)
    # create osil data that is common between linear and nonlinear problems
    @assertequal(length(xl), length(xu))
    @assertequal(length(cl), length(cu))
    numberOfVariables = length(xl)
    numberOfConstraints = length(cl)

    m.numberOfVariables = numberOfVariables
    m.numberOfConstraints = numberOfConstraints
    m.xl = xl
    m.xu = xu
    m.cl = cl
    m.cu = cu
    m.objsense = objsense

    # clear existing problem, if defined
    isdefined(m, :xdoc) && free(m.xdoc)
    m.xdoc = XMLDocument()
    m.vars = Array(XMLElement, numberOfVariables)
    m.cons = Array(XMLElement, numberOfConstraints)

    xroot = create_root(m.xdoc, "osil")
    set_attribute(xroot, "xmlns", "os.optimizationservices.org")
    set_attribute(xroot, "xmlns:xsi",
        "http://www.w3.org/2001/XMLSchema-instance")
    set_attribute(xroot, "xsi:schemaLocation",
        "os.optimizationservices.org " *
        "http://www.optimizationservices.org/schemas/2.0/OSiL.xsd")

    instanceHeader = new_child(xroot, "instanceHeader")
    description = new_child(instanceHeader, "description")
    add_text(description, "generated by CoinOptServices.jl on " *
        strftime("%Y/%m/%d at %H:%M:%S", time()))

    m.instanceData = new_child(xroot, "instanceData")

    variables = new_child(m.instanceData, "variables")
    set_attribute(variables, "numberOfVariables", numberOfVariables)
    for i = 1:numberOfVariables
        vari = new_child(variables, "var")
        set_attribute(vari, "lb", xl[i]) # lb defaults to 0 if not specified!
        isfinite(xu[i]) && set_attribute(vari, "ub", xu[i])
        m.vars[i] = vari
    end

    objectives = new_child(m.instanceData, "objectives")
    # can MathProgBase do multi-objective problems?
    set_attribute(objectives, "numberOfObjectives", "1")
    m.obj = new_child(objectives, "obj")
    set_attribute(m.obj, "maxOrMin", lowercase(string(objsense)))

    constraints = new_child(m.instanceData, "constraints")
    set_attribute(constraints, "numberOfConstraints", numberOfConstraints)
    for i = 1:numberOfConstraints
        coni = new_child(constraints, "con")
        # assume no constant attributes on constraints
        isfinite(cl[i]) && set_attribute(coni, "lb", cl[i])
        isfinite(cu[i]) && set_attribute(coni, "ub", cu[i])
        m.cons[i] = coni
    end

    return m
end

# cannot use this multiple times without removing existing children of m.obj
function _setobj!(m::OsilMathProgModel, f)
    numberOfObjCoef = 0
    for idx = 1:length(f)
        val = f[idx]
        (val == 0.0) && continue
        numberOfObjCoef += 1
        coef = new_child(m.obj, "coef")
        set_attribute(coef, "idx", idx - 1) # OSiL is 0-based
        add_text(coef, string(val))
    end
    set_attribute(m.obj, "numberOfObjCoef", numberOfObjCoef)
end

function MathProgBase.loadproblem!(m::OsilMathProgModel,
        A, xl, xu, f, cl, cu, objsense)
    # populate osil data that is specific to linear problems
    @assertequal(size(A, 1), length(cl))
    @assertequal(size(A, 2), length(xl))
    @assertequal(size(A, 2), length(f))

    create_osil_common!(m, xl, xu, cl, cu, objsense)

    _setobj!(m, f)

    if issparse(A)
        colptr = A.colptr
        rowval = A.rowval
        nzval = A.nzval
    else
        Asparse = sparse(A)
        colptr = Asparse.colptr
        rowval = Asparse.rowval
        nzval = Asparse.nzval
    end
    if length(nzval) > 0
        linearConstraintCoefficients = new_child(m.instanceData,
            "linearConstraintCoefficients")
        set_attribute(linearConstraintCoefficients, "numberOfValues",
            length(nzval))
        colstarts = new_child(linearConstraintCoefficients, "start")
        rowIdx = new_child(linearConstraintCoefficients, "rowIdx")
        values = new_child(linearConstraintCoefficients, "value")
        for i=1:length(colptr)
            add_text(new_child(colstarts, "el"), string(colptr[i] - 1)) # OSiL is 0-based
        end
        for i=1:length(rowval)
            add_text(new_child(rowIdx, "el"), string(rowval[i] - 1)) # OSiL is 0-based
            add_text(new_child(values, "el"), string(nzval[i]))
        end
    end
    m.numLinConstr = length(cl)

    return m
end

function MathProgBase.loadnonlinearproblem!(m::OsilMathProgModel,
        numberOfVariables, numberOfConstraints, xl, xu, cl, cu, objsense,
        d::MathProgBase.AbstractNLPEvaluator)
    # populate osil data that is specific to nonlinear problems
    @assert numberOfVariables == length(xl)
    @assert numberOfConstraints == length(cl)

    create_osil_common!(m, xl, xu, cl, cu, objsense)

    m.d = d
    MathProgBase.initialize(d, [:ExprGraph])

    # TODO: compare BitArray vs. Array{Bool} here
    indicator = falses(numberOfVariables)
    densevals = zeros(numberOfVariables)

    objexpr = MathProgBase.obj_expr(d)
    nlobj = false
    if MathProgBase.isobjlinear(d)
        @assertequal(objexpr.head, :call)
        objexprargs = objexpr.args
        @assertequal(objexprargs[1], :+)
        constant = 0.0
        for i = 2:length(objexprargs)
            constant += addLinElem!(indicator, densevals, objexprargs[i])
        end
        (constant == 0.0) || set_attribute(m.obj, "constant", constant)
        numberOfObjCoef = 0
        idx = findnext(indicator, 1)
        while idx != 0
            numberOfObjCoef += 1
            coef = new_child(m.obj, "coef")
            set_attribute(coef, "idx", idx - 1) # OSiL is 0-based
            add_text(coef, string(densevals[idx]))

            densevals[idx] = 0.0 # reset for later use in linear constraints
            idx = findnext(indicator, idx + 1)
        end
        fill!(indicator, false) # for Array{Bool}, set to false one element at a time?
        set_attribute(m.obj, "numberOfObjCoef", numberOfObjCoef)
    else
        nlobj = true
        set_attribute(m.obj, "numberOfObjCoef", "0")
        # nonlinear objective goes in nonlinearExpressions, <nl idx="-1">
    end

    # assume linear constraints are all at start
    row = 1
    nextrowlinear = MathProgBase.isconstrlinear(d, row)
    if nextrowlinear
        # has at least 1 linear constraint
        linearConstraintCoefficients = new_child(m.instanceData,
            "linearConstraintCoefficients")
        numberOfValues = 0
        rowstarts = new_child(linearConstraintCoefficients, "start")
        add_text(new_child(rowstarts, "el"), "0")
        colIdx = new_child(linearConstraintCoefficients, "colIdx")
        values = new_child(linearConstraintCoefficients, "value")
    end
    while nextrowlinear
        constrexpr = MathProgBase.constr_expr(d, row)
        @assertequal(constrexpr.head, :comparison)
        #(lhs, rhs) = constr2bounds(constrexpr.args...)
        constrlinpart = constrexpr.args[end - 2]
        @assertequal(constrlinpart.head, :call)
        constrlinargs = constrlinpart.args
        @assertequal(constrlinargs[1], :+)
        for i = 2:length(constrlinargs)
            addLinElem!(indicator, densevals, constrlinargs[i]) == 0.0 ||
                error("Unexpected constant term in linear constraint")
        end
        idx = findnext(indicator, 1)
        while idx != 0
            numberOfValues += 1
            add_text(new_child(colIdx, "el"), string(idx - 1)) # OSiL is 0-based
            add_text(new_child(values, "el"), string(densevals[idx]))

            densevals[idx] = 0.0 # reset for next row
            idx = findnext(indicator, idx + 1)
        end
        fill!(indicator, false) # for Array{Bool}, set to false one element at a time?
        add_text(new_child(rowstarts, "el"), string(numberOfValues))
        row += 1
        nextrowlinear = MathProgBase.isconstrlinear(d, row)
    end
    m.numLinConstr = row - 1
    if m.numLinConstr > 0
        # fill in remaining row starts for nonlinear constraints
        for row = m.numLinConstr + 1 : numberOfConstraints
            add_text(new_child(rowstarts, "el"), string(numberOfValues))
        end
        set_attribute(linearConstraintCoefficients, "numberOfValues",
            numberOfValues)
    end

    numberOfNonlinearExpressions = numberOfConstraints - m.numLinConstr +
        (nlobj ? 1 : 0)
    if numberOfNonlinearExpressions > 0
        # has nonlinear objective or at least 1 nonlinear constraint
        nonlinearExpressions = new_child(m.instanceData,
            "nonlinearExpressions")
        set_attribute(nonlinearExpressions, "numberOfNonlinearExpressions",
            numberOfNonlinearExpressions)
        if nlobj
            nl = new_child(nonlinearExpressions, "nl")
            set_attribute(nl, "idx", "-1")
            expr2osnl!(nl, MathProgBase.obj_expr(d))
        end
        for row = m.numLinConstr + 1 : numberOfConstraints
            nl = new_child(nonlinearExpressions, "nl")
            set_attribute(nl, "idx", row - 1) # OSiL is 0-based
            constrexpr = MathProgBase.constr_expr(d, row)
            @assertequal(constrexpr.head, :comparison)
            #(lhs, rhs) = constr2bounds(constrexpr.args...)
            expr2osnl!(nl, constrexpr.args[end - 2])
        end
    end

    return m
end


function write_osol_file(osol, x0, options)
    xdoc = XMLDocument()
    xroot = create_root(xdoc, "osol")
    set_attribute(xroot, "xmlns", "os.optimizationservices.org")
    set_attribute(xroot, "xmlns:xsi",
        "http://www.w3.org/2001/XMLSchema-instance")
    set_attribute(xroot, "xsi:schemaLocation",
        "os.optimizationservices.org " *
        "http://www.optimizationservices.org/schemas/2.0/OSoL.xsd")

    optimization = new_child(xroot, "optimization")
    if length(x0) > 0
        variables = new_child(optimization, "variables")
        initialVariableValues = new_child(variables, "initialVariableValues")
        set_attribute(initialVariableValues, "numberOfVar", length(x0))
    end
    for idx = 1:length(x0)
        vari = new_child(initialVariableValues, "var")
        set_attribute(vari, "idx", idx - 1) # OSiL is 0-based
        set_attribute(vari, "value", x0[idx])
    end

    # TODO: implement these differently
    if length(options) > 0
        solverOptions = new_child(optimization, "solverOptions")
        set_attribute(solverOptions, "numberOfSolverOptions", length(options))
        for i = 1:length(options)
            solverOption = new_child(solverOptions, "solverOption")
            set_attribute(solverOption, "name", options[i][1])
            set_attribute(solverOption, "value", options[i][2])
        end
    end

    ret = save_file(xdoc, osol)
    free(xdoc)
    return ret
end

function read_osrl_file!(m::OsilMathProgModel, osrl)
    xdoc = parse_file(osrl) # TODO: figure out how to suppress namespace warning
    xroot = root(xdoc)
    # do something with general/generalStatus ?
    optimization = find_element(xroot, "optimization")
    @assertequal(int(attribute(optimization, "numberOfVariables")),
        m.numberOfVariables)
    @assertequal(int(attribute(optimization, "numberOfConstraints")),
        m.numberOfConstraints)
    numberOfSolutions = attribute(optimization, "numberOfSolutions")
    if numberOfSolutions != "1"
        warn("numberOfSolutions expected to be 1, was $numberOfSolutions")
    end
    solution = find_element(optimization, "solution")
    status = find_element(solution, "status")
    statustype = attribute(status, "type")
    statusdescription = attribute(status, "description")
    if haskey(osrl2jl_status, statustype)
        m.status = osrl2jl_status[statustype]
    else
        error("Unknown solution status type $statustype")
    end
    if statusdescription != nothing && startswith(statusdescription, "LIMIT")
        if m.status != :UserLimit
            warn("osrl status was $statustype but description was:\n" *
                "$statusdescription, so setting m.status = :UserLimit")
            m.status = :UserLimit
        end
    end

    variables = find_element(solution, "variables")
    if variables == nothing
        m.solution = fill(NaN, m.numberOfVariables)
        (m.status == :Optimal) && warn("status was $statustype but no " *
            "variables were present in $osrl")
    else
        varvalues = find_element(variables, "values")
        @assertequal(int(attribute(varvalues, "numberOfVar")),
            m.numberOfVariables)
        m.solution = xml2vec(varvalues, m.numberOfVariables)

        # reduced costs
        counter = 0
        reduced_costs_found = false
        for child in child_elements(variables)
            if name(child) == "other"
                counter += 1
                if attribute(child, "name") == "reduced_costs"
                    @assertequal(int(attribute(child, "numberOfVar")),
                        m.numberOfVariables)
                    if reduced_costs_found
                        warn("Overwriting existing reduced costs")
                    end
                    reduced_costs_found = true
                    m.reducedcosts = xml2vec(child, m.numberOfVariables)
                end
            end
        end
        numberOfOther = attribute(variables, "numberOfOtherVariableResults")
        if numberOfOther == nothing
            @assertequal(counter, 0)
        else
            @assertequal(counter, int(numberOfOther))
        end
    end

    objectives = find_element(solution, "objectives")
    if objectives == nothing
        m.objval = NaN
        (m.status == :Optimal) && warn("status was $statustype but no " *
            "objectives were present in $osrl")
    else
        objvalues = find_element(objectives, "values")
        numberOfObj = attribute(objvalues, "numberOfObj")
        if numberOfObj != "1"
            warn("numberOfObj expected to be 1, was $numberOfObj")
        end
        m.objval = float64(content(find_element(objvalues, "obj")))
    end

    # constraint duals
    constraints = find_element(solution, "constraints")
    if constraints == nothing
        m.constrduals = fill(NaN, m.numberOfConstraints)
    else
        dualValues = find_element(constraints, "dualValues")
        @assertequal(int(attribute(dualValues, "numberOfCon")),
            m.numberOfConstraints)
        m.constrduals = xml2vec(dualValues, m.numberOfConstraints)
    end

    # TODO: more status details/messages?
    free(xdoc)
    return m.status
end

function MathProgBase.optimize!(m::OsilMathProgModel)
    if m.objsense == :Max && isdefined(m, :d) && isdefined(m, :vartypes) &&
            !all(x -> (x == :Cont || x == :Fixed), m.vartypes)
        warn("Maximization problems can be buggy with " *
            "OSSolverService and MINLP solvers, see " *
            "https://projects.coin-or.org/OS/ticket/52. Formulate your " *
            "problem as a minimization for more reliable results.")
    end
    save_file(m.xdoc, m.osil)
    if isdefined(m, :x0)
        xl, x0, xu = m.xl, m.x0, m.xu
        have_warned = false
        for i = 1:m.numberOfVariables
            if !have_warned && !(xl[i] <= x0[i] <= xu[i])
                warn("Modifying initial conditions to satisfy bounds")
                have_warned = true
            end
            x0[i] = clamp(x0[i], xl[i], xu[i])
        end
        write_osol_file(m.osol, x0, m.options)
    else
        write_osol_file(m.osol, Float64[], m.options)
    end
    if isempty(m.solver)
        solvercmd = `` # use default
    else
        solvercmd = `-solver $(m.solver)`
    end
    run(`$OSSolverService -osil $(m.osil) -osol $(m.osol) -osrl $(m.osrl)
        $solvercmd`)
    return read_osrl_file!(m, m.osrl)
end

# getters
MathProgBase.status(m::OsilMathProgModel) = m.status
MathProgBase.numvar(m::OsilMathProgModel) = m.numberOfVariables
MathProgBase.numconstr(m::OsilMathProgModel) = m.numberOfConstraints
MathProgBase.numlinconstr(m::OsilMathProgModel) = m.numLinConstr
MathProgBase.numquadconstr(m::OsilMathProgModel) = 0 # TODO: quadratic problems
MathProgBase.getobjval(m::OsilMathProgModel) = m.objval
MathProgBase.getsolution(m::OsilMathProgModel) = m.solution
MathProgBase.getreducedcosts(m::OsilMathProgModel) = m.reducedcosts
MathProgBase.getconstrduals(m::OsilMathProgModel) = m.constrduals
MathProgBase.getsense(m::OsilMathProgModel) = m.objsense
MathProgBase.getvartype(m::OsilMathProgModel) = m.vartypes
MathProgBase.getvarLB(m::OsilMathProgModel) = m.xl
MathProgBase.getvarUB(m::OsilMathProgModel) = m.xu
MathProgBase.getconstrLB(m::OsilMathProgModel) = m.cl
MathProgBase.getconstrUB(m::OsilMathProgModel) = m.cu
MathProgBase.getobj(m::OsilMathProgModel) =
    xml2vec(m.obj, m.numberOfVariables, 0.0)

# setters
function MathProgBase.setvartype!(m::OsilMathProgModel, vartypes::Vector{Symbol})
    vars = m.vars
    @assertequal(length(vars), length(vartypes))
    for i = 1:length(vartypes)
        if haskey(jl2osil_vartypes, vartypes[i])
            set_attribute(vars[i], "type", jl2osil_vartypes[vartypes[i]])
        else
            error("Unrecognized vartype $(vartypes[i])")
        end
    end
    m.vartypes = vartypes
end

function setbounds!(xvec::Vector{XMLElement}, b::Vector{Float64}, attr)
    @assertequal(length(xvec), length(b))
    for i = 1:length(b)
        set_attribute(xvec[i], attr, b[i])
    end
    return b
end

function MathProgBase.setvarLB!(m::OsilMathProgModel, xl::Vector{Float64})
    m.xl = setbounds!(m.vars, xl, "lb")
end

function MathProgBase.setvarUB!(m::OsilMathProgModel, xu::Vector{Float64})
    m.xu = setbounds!(m.vars, xu, "ub")
end

function MathProgBase.setconstrLB!(m::OsilMathProgModel, cl::Vector{Float64})
    m.cl = setbounds!(m.cons, cl, "lb")
end

function MathProgBase.setconstrUB!(m::OsilMathProgModel, cu::Vector{Float64})
    m.cu = setbounds!(m.cons, cu, "ub")
end

function MathProgBase.setsense!(m::OsilMathProgModel, objsense::Symbol)
    set_attribute(m.obj, "maxOrMin", lowercase(string(objsense)))
    m.objsense = objsense
end

function MathProgBase.setwarmstart!(m::OsilMathProgModel, x0::Vector{Float64})
    @assertequal(length(x0), m.numberOfVariables)
    m.x0 = x0
end

# writeproblem for nonlinear?



end # module
