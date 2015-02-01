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
isfile(depsjl) ? include(depsjl) : error("CoinOptServices not properly ",
    "installed. Please run\nPkg.build(\"CoinOptServices\")")
OSSolverService = joinpath(dirname(libOS), "..", "bin", "OSSolverService")
osildir = Pkg.dir("CoinOptServices", ".osil")

export OsilSolver
immutable OsilSolver <: AbstractMathProgSolver
    solver::String
    osil::String
    osol::String
    osrl::String
    printLevel::Int
    options
end
# note that changing DEFAULT_OUTPUT_LEVEL in OS/src/OSUtils/OSOutput.h
# from ENUM_OUTPUT_LEVEL_error (1) to -1 is required to make printLevel=0
# actually silent, since there are several instances of OSPrint that use
# ENUM_OUTPUT_LEVEL_always (0) *before* command-line flags like -printLevel
# have been read, and OSPrint shows output whenever the output level for a
# call is <= the printLevel
OsilSolver(;
    solver = "",
    osil = joinpath(osildir, "problem.osil"),
    osol = joinpath(osildir, "options.osol"),
    osrl = joinpath(osildir, "results.osrl"),
    printLevel = 1,
    options...) = OsilSolver(solver, osil, osol, osrl, printLevel, options)

type OsilMathProgModel <: AbstractMathProgModel
    solver::String
    osil::String
    osol::String
    osrl::String
    printLevel::Int
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
    numQuadConstr::Int
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
    variables::XMLElement
    constraints::XMLElement
    quadraticCoefficients::XMLElement
    quadobjterms::Vector{XMLElement}

    OsilMathProgModel(solver, osil, osol, osrl, printLevel; options...) =
        new(solver, osil, osol, osrl, printLevel, options)
end

MathProgBase.model(s::OsilSolver) = OsilMathProgModel(s.solver,
    s.osil, s.osol, s.osrl, s.printLevel; s.options...)

include("probmod.jl")

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

    m.variables = new_child(m.instanceData, "variables")
    set_attribute(m.variables, "numberOfVariables", numberOfVariables)
    for i = 1:numberOfVariables
        newvar!(m.variables, xl[i], xu[i])
    end

    objectives = new_child(m.instanceData, "objectives")
    # can MathProgBase do multi-objective problems?
    set_attribute(objectives, "numberOfObjectives", "1")
    m.obj = new_child(objectives, "obj")
    set_attribute(m.obj, "maxOrMin", lowercase(string(objsense)))

    m.constraints = new_child(m.instanceData, "constraints")
    set_attribute(m.constraints, "numberOfConstraints", numberOfConstraints)
    for i = 1:numberOfConstraints
        newcon!(m.constraints, cl[i], cu[i])
    end
    m.numQuadConstr = 0 # move this once MathProgBase.loadquadproblem! exists

    return m
end

function MathProgBase.setobj!(m::OsilMathProgModel, f)
    # unlink and free any existing children of m.obj
    for el in child_elements(m.obj)
        unlink(el)
        free(el)
    end
    numberOfObjCoef = 0
    for i = 1:length(f)
        val = f[i]
        (val == 0.0) && continue
        numberOfObjCoef += 1
        newobjcoef!(m.obj, i - 1, val) # OSiL is 0-based
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
    MathProgBase.setobj!(m, f)

    # transpose linear constraint matrix so it is easier
    # to add linear rows in addquadconstr!
    if issparse(A)
        At = A'
    else
        At = sparse(A)'
    end
    rowptr = At.colptr
    colval = At.rowval
    nzval = At.nzval
    if length(nzval) > 0
        (linConstrCoefs, rowstarts, colIdx, values) =
            create_empty_linconstr!(m)
        set_attribute(linConstrCoefs, "numberOfValues", length(nzval))
        @assertequal(rowptr[1], 1)
        for i = 2:length(rowptr)
            add_text(new_child(rowstarts, "el"), string(rowptr[i] - 1)) # OSiL is 0-based
        end
        for i = 1:length(colval)
            addnonzero!(colIdx, values, colval[i] - 1, nzval[i]) # OSiL is 0-based
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
        i = findnext(indicator, 1)
        while i != 0
            numberOfObjCoef += 1
            newobjcoef!(m.obj, i - 1, densevals[i]) # OSiL is 0-based
            densevals[i] = 0.0 # reset for later use in linear constraints
            i = findnext(indicator, i + 1)
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
        (linConstrCoefs, rowstarts, colIdx, values) =
            create_empty_linconstr!(m)
        numberOfValues = 0
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
            addnonzero!(colIdx, values, idx - 1, densevals[idx]) # OSiL is 0-based
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
        set_attribute(linConstrCoefs, "numberOfValues", numberOfValues)
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
    xdoc = parse_file(osrl, C_NULL, 64) # 64 == XML_PARSE_NOWARNING
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
    if statusdescription != nothing
        if m.status != :UserLimit && startswith(statusdescription, "LIMIT")
            warn("osrl status was $statustype but description was:\n",
                statusdescription, " so setting m.status = :UserLimit")
            m.status = :UserLimit
        elseif statustype == "error" && (statusdescription ==
                "The problem is infeasible")
            m.status = :Infeasible
        elseif statustype == "error" && (statusdescription ==
                "The problem is unbounded" ||
                startswith(statusdescription, "CONTINUOUS_UNBOUNDED"))
            m.status = :Unbounded
        end
    end

    variables = find_element(solution, "variables")
    if variables == nothing
        m.solution = fill(NaN, m.numberOfVariables)
        (m.status == :Optimal) && warn("status was $statustype but no ",
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
        (m.status == :Optimal) && warn("status was $statustype but no ",
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
            any(x -> !(x == :Cont || x == :Fixed), m.vartypes)
        warn("Maximization problems can be buggy with ",
            "OSSolverService and MINLP solvers, see ",
            "https://projects.coin-or.org/OS/ticket/52. Formulate your ",
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
    # clear existing content from m.osrl, if any
    close(open(m.osrl, "w"))
    if isempty(m.solver)
        solvercmd = `` # use default
    else
        solvercmd = `-solver $(m.solver)`
    end
    run(`$OSSolverService -osil $(m.osil) -osol $(m.osol) -osrl $(m.osrl)
        $solvercmd -printLevel $(m.printLevel)`)
    if filesize(m.osrl) == 0
        warn(m.osrl, " is empty")
        m.status = :Error
    else
        read_osrl_file!(m, m.osrl)
    end
    return m.status
end

end # module
