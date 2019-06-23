module StatProfilerHTML

export statprofilehtml, @profilehtml

using Profile
using Base.StackTraces: StackFrame
with_value(f, x) = x !== nothing && f(x)

const basepath           = dirname(@__DIR__)
const sharepath          = joinpath(basepath, "share")
const statprofilehtml_pl = joinpath(basepath, "bin", "statprofilehtml.pl")
const perllib            = joinpath(basepath, "perllib")

function statprofilehtml(data::Array{UInt,1} = UInt[],litrace::Dict{UInt,Array{StackFrame,1}} = Dict{UInt,Array{StackFrame,1}}();
                         from_c=false)
    if length(data) == 0
        (data, litrace) = Profile.retrieve()
    end

    data, litrace = Profile.flatten(data, litrace)

    withenv("PERL5LIB" => perllib) do
        open(`perl $statprofilehtml_pl $sharepath`, "w", stdout) do formatter
            lastwaszero = true
            for d in data
                if d == 0
                    if !lastwaszero
                        write(formatter, "\n")
                    end
                    lastwaszero = true
                    continue
                end
                frame = litrace[d]
                if !frame.from_c || from_c
                    file = Base.find_source_file(string(frame.file))
                    func_line = frame.line
                    with_value(frame.linfo) do linfo
                        func_line = linfo.def.line - 1  # off-by-one difference between how StatProfiler and julia seem to map this
                    end

                    file_repr = file == nothing ? "nothing" : file
                    write(formatter, "$(file_repr)\t$(frame.line)\t$(frame.func)\t$(func_line)\n")
                    lastwaszero = false
                end
            end
        end
    end

    @info "Wrote profiling output to file://$(pwd())/statprof/index.html ."
end

macro profilehtml(expr)
    quote
        Profile.clear()
        res = try
            @profile $(esc(expr))
        catch ex
            ex isa InterruptException || rethrow(ex)
            @info "You interrupted the computation; generating profiling view for the computation so far."
        end
        statprofilehtml()
        res
    end
end

end
