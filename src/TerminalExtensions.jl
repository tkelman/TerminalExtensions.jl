module TerminalExtensions

using Compat
#
# None of these functions are operating system specific because they
# might be connect via e.g. SSH to a different client operating system
#

import Base.Terminals: CSI

const DCS = "\eP"
const ST  = "\e\\"

function readDCS(io::IO)
    while nb_available(STDIN) >= 2
        c1 = read(io,UInt8)
        c1 == 0x90 && return true
        if c1 == '\e'
            read(io,UInt8) == 'P' && return true
        end
    end
    return false
end


function readST(io::IO)
    c1 = read(io,UInt8)
    c1 == 0x90 && return true
    c1 != '\e' && return false
    read(io,UInt8) != '\\' && return false
    return true
end

#
# Uses xterm termcap queries to query the termcap database.
#
# The base query is
#   DCS + q Pt ST
#
# We also try our best to hide any output on non xterm-compatible terminals
# though.
#
# This function assumes that it is called with the terminal in raw mode and
# STDIN reading.
#
function queryTermcap(name::ASCIIString)
    # Note: name is currently unused, "TN" is the only query here
    term = Base.Terminals.TTYTerminal("xterm",STDIN,STDOUT,STDERR)

    q = join([hex(c) for c in "TN"])
    query = string(
        "\e7",              # Save cursor position
        CSI,1,"E",          # Cursor next line
        DCS,"+q$q",ST,      # The actual query
        CSI,0,"G",
        CSI,0,"K",          # Clear line
        "\e8",              # Cursor restore
        )
    write(STDOUT,query)

    # Wait 300 ms for an answer
    timedwait(0.3; pollint=0.05) do
         nb_available(STDIN) > 0
    end

    nbytesresponse = nb_available(STDIN)
    nbytesresponse == 0 && error("Timed out!")

    # at least DCS 1 + r $q = ST (where DCS and ST are potentially two characters)
    nb_available(STDIN) < 3 && error("Incomplete Response")

    readDCS(STDIN) || error("Invalid Terminal Response")
    ok = read(STDIN,UInt8)
    if ok != '1'
        read(STDIN,UInt8);read(STDIN,UInt8);readST(STDIN)
        error("Terminal reports Invalid Request")
    end

    nb_available(STDIN) < 5+sizeof(q) && error("Incomplete Response")

    lowercase(bytestring(read(STDIN,3+sizeof(q)))) ==
        lowercase(string("+r",q,'=')) || error("Invalid Terminal Response")

    response = Array(UInt8,0)
    sizehint!(response,nbytesresponse-6)
    while nb_available(STDIN) != 0
        c = read(STDIN,UInt8)
        if c == 0x9c
            break
        elseif c == '\e'
            if (nb_available(STDIN) == 0 || read(STDIN,UInt8) != '\\')
                error("Invalid escape sequence in response")
            end
            break
        end
        push!(response,c)
    end

    rs = Array(UInt8,0)
    sizehint!(rs,div(length(response),2))
    for i = 1:2:length(response)
        push!(rs,parse(Int,bytestring(response[i:i+1]),16))
    end

    bytestring(rs)
end

module iTerm2

    import Base: display
    using Compat

    immutable InlineDisplay <: Display; end

    function set_mark()
        "\033]50;SetMark\007"
    end

    # Runs after interactively edited command but before execution
    function preexec()
        "\033]133;C\007"
    end

    function remotehost_and_currentdir()
        return string("\033]1337;RemoteHost=",ENV["USER"],"@",readstring(`hostname -f`),"\007","\033]1337;CurrentDir=",pwd(),"\007")
    end

    function prompt_prefix(last_success = true)
        return string("\033]133;D;$(convert(Int, last_success))\007",remotehost_and_currentdir(),"\033]133;A\007")
    end

    function prompt_suffix()
        return "\033]133;B\007"
    end

    function shell_version_number()
        return "\033]1337;ShellIntegrationVersion=1\007"
    end


    function prepare_display_file(;filename="Unnamed file", size=nothing, width=nothing, height=nothing, preserveAspectRation::Bool=true, inline::Bool=false)
        q = "\e]1337;File="
        options = ASCIIString[]
        filename != "Unnamed file" && push!(options,"name=" * base64encode(filename))
        size !== nothing && push!(options,"size=" * dec(size))
        height !== nothing && push!(options,"height=" * height)
        width !== nothing && push!(options,"width=" * width)
        preserveAspectRation !== true && push!(options,"preserveAspectRation=0")
        inline !== false && push!(options,"inline=1")
        q *= join(options,';')
        q *= ":"
        write(STDOUT,q)
    end

    function display_file(data::Vector{UInt8}; kwargs...)
        prepare_display_file(;kwargs...)
        write(STDOUT,base64encode(data))
        write(STDOUT,'\a')
    end

    # Incomplete list. Will be extended as necessity comes up
    const iterm2_mimes = ["image/png", "image/gif", "image/jpeg", "application/pdf", "application/eps"]

    for mime in iterm2_mimes
        @eval begin
            function display(d::InlineDisplay, m::MIME{symbol($mime)}, x)
                prepare_display_file(;filename="image",inline=true)
                buf = IOBuffer()
                writemime(Base.Base64EncodePipe(buf),m,x)
                write(STDOUT, takebuf_array(buf))
                write(STDOUT,'\a')
            end
        end
    end

    function display(d::InlineDisplay,x)
        for m in iterm2_mimes
            if mimewritable(m,x)
                return display(d,m,x)
            end
        end
        throw(MethodError(display, (d,x)))
    end

end

function __init__()
    if !(isinteractive() && isdefined(Base, :active_repl))
        return
    end
    # print, but hide initial mark, even before we know we're dealing with iterm
    q = string(
        iTerm2.shell_version_number(),  # Shell mode version
        iTerm2.remotehost_and_currentdir(),    # Remote host and current directory
        # Set preliminary mark (will be updated when command is actually executed)
        iTerm2.set_mark(),
        "\x1b[0G\x1b[0K",               # Clear line
    )
    print(STDOUT,q)
    begin
        term = Base.Terminals.TTYTerminal("xterm",STDIN,STDOUT,STDERR)
        Base.Terminals.raw!(term,true)
        Base.start_reading(STDIN)

        if queryTermcap("TN") == "iTerm2"
            pushdisplay(iTerm2.InlineDisplay())
            repl = Base.active_repl#REPL.LineEditREPL(Terminals.TTYTerminal("xterm",STDIN,STDOUT,STDERR))

            if !isdefined(repl,:interface)
                repl.interface = Base.REPL.setup_interface(repl)
            end

            let waserror = false
                prefix = repl.interface.modes[1].prompt_prefix
                repl.interface.modes[1].prompt_prefix = function ()
                    (TerminalExtensions.iTerm2.prompt_prefix(waserror) * (isa(prefix,Function) ? prefix() : prefix))
                end
                suffix = repl.interface.modes[1].prompt_suffix
                repl.interface.modes[1].prompt_suffix = function ()
                    ((isa(suffix,Function) ? suffix() : suffix) * TerminalExtensions.iTerm2.prompt_suffix())
                end
                for mode in repl.interface.modes
                    if isdefined(mode,:on_done)
                        of = mode.on_done
                        mode.on_done = function (args...)
                            print(STDOUT,TerminalExtensions.iTerm2.preexec())
                            of(args...)
                            waserror = repl.waserror
                        end
                    end
                end
            end
        end
    end
end

export queryTermcap, iTerm2

end # module
