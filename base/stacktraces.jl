# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Tools for collecting and manipulating stack traces. Mainly used for building errors.
"""
module StackTraces


import Base: hash, ==, show
import Core: CodeInfo, MethodInstance

export StackTrace, StackFrame, stacktrace

"""
    StackFrame

Stack information representing execution context, with the following fields:

- `func::Symbol`

  The name of the function containing the execution context.

- `linfo::Union{Core.MethodInstance, CodeInfo, Nothing}`

  The MethodInstance containing the execution context (if it could be found).

- `file::Symbol`

  The path to the file containing the execution context.

- `line::Int`

  The line number in the file containing the execution context.

- `from_c::Bool`

  True if the code is from C.

- `inlined::Bool`

  True if the code is from an inlined frame.

- `pointer::UInt64`

  Representation of the pointer to the execution context as returned by `backtrace`.

"""
struct StackFrame # this type should be kept platform-agnostic so that profiles can be dumped on one machine and read on another
    "the name of the function containing the execution context"
    func::Symbol
    "the path to the file containing the execution context"
    file::Symbol
    "the line number in the file containing the execution context"
    line::Int
    "the MethodInstance or CodeInfo containing the execution context (if it could be found), \
     or Module (for macro expansions)"
    linfo::Union{MethodInstance, Method, Module, CodeInfo, Nothing}
    "true if the code is from C"
    from_c::Bool
    "true if the code is from an inlined frame"
    inlined::Bool
    "representation of the pointer to the execution context as returned by `backtrace`"
    pointer::UInt64  # Large enough to be read losslessly on 32- and 64-bit machines.
end

StackFrame(func, file, line) = StackFrame(Symbol(func), Symbol(file), line,
                                          nothing, false, false, 0)

"""
    StackTrace

An alias for `Vector{StackFrame}` provided for convenience; returned by calls to
`stacktrace`.
"""
const StackTrace = Vector{StackFrame}

const empty_sym = Symbol("")
const UNKNOWN = StackFrame(empty_sym, empty_sym, -1, nothing, true, false, 0) # === lookup(C_NULL)


#=
If the StackFrame has function and line information, we consider two of them the same if
they share the same function/line information.
=#
function ==(a::StackFrame, b::StackFrame)
    return a.line == b.line && a.from_c == b.from_c && a.func == b.func && a.file == b.file && a.inlined == b.inlined # excluding linfo and pointer
end

function hash(frame::StackFrame, h::UInt)
    h += 0xf4fbda67fe20ce88 % UInt
    h = hash(frame.line, h)
    h = hash(frame.file, h)
    h = hash(frame.func, h)
    h = hash(frame.from_c, h)
    h = hash(frame.inlined, h)
    return h
end

get_inlinetable(::Any) = nothing
function get_inlinetable(mi::MethodInstance)
    isdefined(mi, :def) && mi.def isa Method && isdefined(mi, :cache) && isdefined(mi.cache, :inferred) &&
        mi.cache.inferred !== nothing || return nothing
    linetable = ccall(:jl_uncompress_ir, Any, (Any, Any, Any), mi.def, mi.cache, mi.cache.inferred).linetable
    return filter!(x -> x.inlined_at > 0, linetable)
end

get_method_instance_roots(::Any) = nothing
function get_method_instance_roots(mi::Union{Method, MethodInstance})
    m = mi isa MethodInstance ? mi.def : mi
    m isa Method && isdefined(m, :roots) || return nothing
    return filter(x -> x isa MethodInstance, m.roots)
end

function lookup_inline_frame_info(func::Symbol, file::Symbol, linenum::Int, inlinetable::Vector{Core.LineInfoNode})
    #REPL frames and some base files lack this prefix while others have it; should fix?
    filestripped = Symbol(lstrip(string(file), ('.', '\\', '/')))
    linfo = nothing
    #=
    Some matching entries contain the MethodInstance directly.
    Other matching entries contain only a Method or Symbol (function name); such entries
    are located after the entry with the MethodInstance, so backtracking is required.
    If backtracking fails, the Method or Module is stored for return, but we continue
    the search in case a MethodInstance is found later.
    TODO: If a backtrack has failed, do we need to backtrack again later if another Method
    or Symbol match is found? Or can a limit on the subsequent backtracks be placed?
    =#
    for (i, line) in enumerate(inlinetable)
        Base.IRShow.method_name(line) === func && line.file ∈ (file, filestripped) && line.line == linenum || continue
        if line.method isa MethodInstance
            linfo = line.method
            break
        elseif line.method isa Method || line.method isa Symbol
            linfo = line.method isa Method ? line.method : line.module
            # backtrack to find the matching MethodInstance, if possible
            for j in (i - 1):-1:1
                nextline = inlinetable[j]
                nextline.inlined_at == line.inlined_at && Base.IRShow.method_name(line) === Base.IRShow.method_name(nextline) && line.file === nextline.file || break
                if nextline.method isa MethodInstance
                    linfo = nextline.method
                    break
                end
            end
        end
    end
    return linfo
end

function lookup_inline_frame_info(func::Symbol, file::Symbol, miroots::Vector{Any})
    # REPL frames and some base files lack this prefix while others have it; should fix?
    filestripped = Symbol(lstrip(string(file), ('.', '\\', '/')))
    matches = filter(miroots) do x
        x.def isa Method || return false
        m = x.def::Method
        return m.name == func && m.file ∈ (file, filestripped)
    end
    if length(matches) > 1
        # ambiguous, check if method is same and return that instead
        all_matched = true
        for m in matches
            all_matched = m.def.line == matches[1].def.line &&
                m.def.module == matches[1].def.module
            all_matched || break
        end
        if all_matched
            return matches[1].def
        end
        # all else fails, return module if they match, or give up
        all_matched = true
        for m in matches
            all_matched = m.def.module == matches[1].def.module
            all_matched || break
        end
        return all_matched ? matches[1].def.module : nothing
    elseif length(matches) == 1
        return matches[1]
    end
    return nothing
end

"""
    lookup(pointer::Ptr{Cvoid}) -> Vector{StackFrame}

Given a pointer to an execution context (usually generated by a call to `backtrace`), looks
up stack frame context information. Returns an array of frame information for all functions
inlined at that point, innermost function first.
"""
Base.@constprop :none function lookup(pointer::Ptr{Cvoid})
    infos = ccall(:jl_lookup_code_address, Any, (Ptr{Cvoid}, Cint), pointer, false)::Core.SimpleVector
    pointer = convert(UInt64, pointer)
    isempty(infos) && return [StackFrame(empty_sym, empty_sym, -1, nothing, true, false, pointer)] # this is equal to UNKNOWN
    parent_linfo = infos[end][4]
    inlinetable = get_inlinetable(parent_linfo)
    miroots = inlinetable === nothing ? get_method_instance_roots(parent_linfo) : nothing # fallback if linetable missing
    res = Vector{StackFrame}(undef, length(infos))
    for i in reverse(1:length(infos))
        info = infos[i]::Core.SimpleVector
        @assert(length(info) == 6)
        func = info[1]::Symbol
        file = info[2]::Symbol
        linenum = info[3]::Int
        linfo = info[4]
        if i < length(infos)
            if inlinetable !== nothing
                linfo = lookup_inline_frame_info(func, file, linenum, inlinetable)
            elseif miroots !== nothing
                linfo = lookup_inline_frame_info(func, file, miroots)
            end
            linfo = linfo === nothing ? parentmodule(res[i + 1]) : linfo # e.g. `macro expansion`
        end
        res[i] = StackFrame(func, file, linenum, linfo, info[5]::Bool, info[6]::Bool, pointer)
    end
    return res
end

const top_level_scope_sym = Symbol("top-level scope")

function lookup(ip::Union{Base.InterpreterIP,Core.Compiler.InterpreterIP})
    code = ip.code
    if code === nothing
        # interpreted top-level expression with no CodeInfo
        return [StackFrame(top_level_scope_sym, empty_sym, 0, nothing, false, false, 0)]
    end
    codeinfo = (code isa MethodInstance ? code.uninferred : code)::CodeInfo
    # prepare approximate code info
    if code isa MethodInstance && (meth = code.def; meth isa Method)
        func = meth.name
        file = meth.file
        line = meth.line
    else
        func = top_level_scope_sym
        file = empty_sym
        line = Int32(0)
    end
    i = max(ip.stmt+1, 1)  # ip.stmt is 0-indexed
    if i > length(codeinfo.codelocs) || codeinfo.codelocs[i] == 0
        return [StackFrame(func, file, line, code, false, false, 0)]
    end
    lineinfo = codeinfo.linetable[codeinfo.codelocs[i]]::Core.LineInfoNode
    scopes = StackFrame[]
    while true
        inlined = lineinfo.inlined_at != 0
        push!(scopes, StackFrame(Base.IRShow.method_name(lineinfo)::Symbol, lineinfo.file, lineinfo.line, inlined ? nothing : code, false, inlined, 0))
        inlined || break
        lineinfo = codeinfo.linetable[lineinfo.inlined_at]::Core.LineInfoNode
    end
    return scopes
end

"""
    stacktrace([trace::Vector{Ptr{Cvoid}},] [c_funcs::Bool=false]) -> StackTrace

Return a stack trace in the form of a vector of `StackFrame`s. (By default stacktrace
doesn't return C functions, but this can be enabled.) When called without specifying a
trace, `stacktrace` first calls `backtrace`.
"""
Base.@constprop :none function stacktrace(trace::Vector{<:Union{Base.InterpreterIP,Core.Compiler.InterpreterIP,Ptr{Cvoid}}}, c_funcs::Bool=false)
    stack = StackTrace()
    for ip in trace
        for frame in lookup(ip)
            # Skip frames that come from C calls.
            if c_funcs || !frame.from_c
                push!(stack, frame)
            end
        end
    end
    return stack
end

Base.@constprop :none function stacktrace(c_funcs::Bool=false)
    stack = stacktrace(backtrace(), c_funcs)
    # Remove frame for this function (and any functions called by this function).
    remove_frames!(stack, :stacktrace)
    # also remove all of the non-Julia functions that led up to this point (if that list is non-empty)
    c_funcs && deleteat!(stack, 1:(something(findfirst(frame -> !frame.from_c, stack), 1) - 1))
    return stack
end

"""
    remove_frames!(stack::StackTrace, name::Symbol)

Takes a `StackTrace` (a vector of `StackFrames`) and a function name (a `Symbol`) and
removes the `StackFrame` specified by the function name from the `StackTrace` (also removing
all frames above the specified function). Primarily used to remove `StackTraces` functions
from the `StackTrace` prior to returning it.
"""
function remove_frames!(stack::StackTrace, name::Symbol)
    deleteat!(stack, 1:something(findlast(frame -> frame.func == name, stack), 0))
    return stack
end

function remove_frames!(stack::StackTrace, names::Vector{Symbol})
    deleteat!(stack, 1:something(findlast(frame -> frame.func in names, stack), 0))
    return stack
end

"""
    remove_frames!(stack::StackTrace, m::Module)

Return the `StackTrace` with all `StackFrame`s from the provided `Module` removed.
"""
function remove_frames!(stack::StackTrace, m::Module)
    filter!(f -> !from(f, m), stack)
    return stack
end

is_top_level_frame(f::StackFrame) = f.linfo isa CodeInfo || (f.linfo === nothing && f.func === top_level_scope_sym)

function show_spec_linfo(io::IO, frame::StackFrame)
    linfo = frame.linfo
    if linfo === nothing
        if frame.func === empty_sym
            print(io, "ip:0x", string(frame.pointer, base=16))
        elseif frame.func === top_level_scope_sym
            print(io, "top-level scope")
        else
            Base.print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
        end
    elseif linfo isa CodeInfo
        print(io, "top-level scope")
    elseif linfo isa Module
        Base.print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
    else
        def, sig = if linfo isa MethodInstance
             linfo.def, linfo.specTypes
        else
            linfo, linfo.sig
        end
        if def isa Method
            if get(io, :limit, :false)::Bool
                if !haskey(io, :displaysize)
                    io = IOContext(io, :displaysize => displaysize(io))
                end
            end
            argnames = Base.method_argnames(def)
            argnames = replace(argnames, :var"#unused#" => :var"")
            if def.nkw > 0
                # rearrange call kw_impl(kw_args..., func, pos_args...) to func(pos_args...)
                kwarg_types = Any[ fieldtype(sig, i) for i = 2:(1+def.nkw) ]
                uw = Base.unwrap_unionall(sig)::DataType
                pos_sig = Base.rewrap_unionall(Tuple{uw.parameters[(def.nkw+2):end]...}, sig)
                kwnames = argnames[2:(def.nkw+1)]
                for i = 1:length(kwnames)
                    str = string(kwnames[i])::String
                    if endswith(str, "...")
                        kwnames[i] = Symbol(str[1:end-3])
                    end
                end
                Base.show_tuple_as_call(io, def.name, pos_sig;
                                        demangle=true,
                                        kwargs=zip(kwnames, kwarg_types),
                                        argnames=argnames[def.nkw+2:end])
            else
                Base.show_tuple_as_call(io, def.name, sig; demangle=true, argnames)
            end
        else
            Base.show_mi(io, linfo, true)
        end
    end
end

function show(io::IO, frame::StackFrame)
    show_spec_linfo(io, frame)
    if frame.file !== empty_sym
        file_info = basename(string(frame.file))
        print(io, " at ")
        print(io, file_info, ":")
        if frame.line >= 0
            print(io, frame.line)
        else
            print(io, "?")
        end
    end
    if frame.inlined
        print(io, " [inlined]")
    end
end

function Base.parentmodule(frame::StackFrame)
    linfo = frame.linfo
    if linfo isa MethodInstance
        def = linfo.def
        if def isa Module
            return def
        else
            return (def::Method).module
        end
    elseif linfo isa Method
        return linfo.module
    elseif linfo isa Module
        return linfo
    else
        # The module is not always available (common reasons include
        # frames arising from the interpreter)
        nothing
    end
end

"""
    from(frame::StackFrame, filter_mod::Module) -> Bool

Return whether the `frame` is from the provided `Module`
"""
function from(frame::StackFrame, m::Module)
    return parentmodule(frame) === m
end

end
