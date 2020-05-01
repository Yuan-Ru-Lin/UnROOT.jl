struct StreamerInfo
    streamer
    dependencies
end

struct Streamers
    tkey::TKey
    refs::Dict{Int32, Any}
    elements::Vector{StreamerInfo}
end

Base.length(s::Streamers) = length(s.elements)

"""
    function read_streamers(io, tkey::TKey)

Reads all the streamers from the ROOT source.
"""
function Streamers(io)
    refs = Dict{Int32, Any}()

    start = position(io)
    tkey = unpack(io, TKey)

    if iscompressed(tkey)
        @debug "Compressed stream at $(start)"
        seekstart(io, tkey)
        compression_header = unpack(io, CompressionHeader)
        if String(compression_header.algo) != "ZL"
            error("Unsupported compression type '$(String(compression_header.algo))'")
        end

        stream = IOBuffer(read(ZlibDecompressorStream(io), tkey.fObjlen))
    else
        @debug "Unompressed stream at $(start)"
        stream = io
    end
    preamble = Preamble(stream, Streamers)
    skiptobj(stream)

    name = readtype(stream, String)
    size = readtype(stream, Int32)
    streamer_infos = Vector{StreamerInfo}()
    for i ∈ 1:size
        obj = readobjany!(stream, tkey, refs)
        if typeof(obj) == TStreamerInfo
            dependencies = Set()
            for element in obj.fElements.elements
                if typeof(element) == TStreamerBase
                    push!(dependencies, element.fName)
                end
            end
            push!(streamer_infos, StreamerInfo(obj, dependencies))
        end
        skip(stream, readtype(stream, UInt8))
    end

    endcheck(stream, preamble)

    Streamers(tkey, refs, topological_sort(streamer_infos))
end

"""
    function topological_sort(streamer_infos)

Sort the streamers with respect to their dependencies and keep only those
which are not defined already.

The implementation is based on https://stackoverflow.com/a/11564769/1623645
"""
function topological_sort(streamer_infos)
    provided = Set{String}()
    sorted_streamer_infos = []
    while length(streamer_infos) > 0
        remaining_items = []
        emitted = false

        for streamer_info in streamer_infos
            if all(d -> isdefined(@__MODULE__, Symbol(d)) || d ∈ provided, streamer_info.dependencies)
                if !isdefined(@__MODULE__, Symbol(streamer_info.streamer.fName)) && aliasfor(streamer_info.streamer.fName) === nothing
                    push!(sorted_streamer_infos, streamer_info)
                end
                push!(provided, streamer_info.streamer.fName)
                emitted = true
            else
                push!(remaining_items, streamer_info)
            end
        end

        if !emitted
            for streamer_info in streamer_infos
                filter!(isequal(streamer_info), remaining_items)
            end
        end

        streamer_infos = remaining_items
    end
    sorted_streamer_infos
end

function define_streamers(streamers)
    for streamer_info in streamers.elements
        # println(streamer_info.streamer.fName)
        # for dep in streamer_info.dependencies
        #     println("  $dep")
        # end
    end
end


"""
    function readobjany!(io, tkey::TKey, refs)

The main entrypoint where streamers are parsed cached for later use. The `refs`
dictionary holds the streamers or parsed data which are reused when already
available.
"""
function readobjany!(io, tkey::TKey, refs)
    beg = position(io) - origin(tkey)
    bcnt = readtype(io, UInt32)
    if Int64(bcnt) & Const.kByteCountMask == 0 || Int64(bcnt) == Const.kNewClassTag
        # New class or 0 bytes
        version = 0
        start = 0
        tag = bcnt
        bcnt = 0
    else
        version = 1
        start = position(io) - origin(tkey)
        tag = readtype(io, UInt32)
    end

    if Int64(tag) & Const.kClassMask == 0
        # reference object
        if tag == 0
            return missing
        elseif tag == 1
            error("Returning parent is not implemented yet")
        elseif !haskey(refs, tag)
            # skipping
            seek(io, origin(tkey) + beg + bcnt + 4)
            return missing
        else
            return refs[tag]
        end

    elseif tag == Const.kNewClassTag
        cname = readtype(io, CString)
        streamer = getfield(@__MODULE__, Symbol(cname))

        if version > 0
            refs[start + Const.kMapOffset] = streamer
        else
            refs[length(refs) + 1] = streamer
        end

        obj = unpack(io, tkey, refs, streamer)

        if version > 0
            refs[beg + Const.kMapOffset] = obj
        else
            refs[length(refs) + 1] = obj
        end

        return obj
    else
        # reference class, new object
        ref = Int64(tag) & ~Const.kClassMask
        haskey(refs, ref) || error("Invalid class reference.")

        streamer = refs[ref]
        obj = unpack(io, tkey, refs, streamer)

        if version > 0
            refs[beg + Const.kMapOffset] = obj
        else
            refs[length(refs) + 1] = obj
        end

        return obj
    end
end


# Structures required to read streamers

struct TStreamerInfo
    fName
    fTitle
    fCheckSum
    fClassVersion
    fElements
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerInfo})
    preamble = Preamble(io, T)
    fName, fTitle = nametitle(io)
    fCheckSum = readtype(io, UInt32)
    fClassVersion = readtype(io, Int32)
    fElements = readobjany!(io, tkey, refs)
    endcheck(io, preamble)
    T(fName, fTitle, fCheckSum, fClassVersion, fElements)
end

struct TList
    preamble
    name
    size
    objects
end

Base.length(l::TList) = length(l.objects)


function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TList})
    preamble = Preamble(io, T)
    skiptobj(io)

    name = readtype(io, String)
    size = readtype(io, Int32)
    objects = []
    for i ∈ 1:size
        push!(objects, readobjany!(io, tkey, refs))
        skip(io, readtype(io, UInt8))
    end

    endcheck(io, preamble)
    TList(preamble, name, size, objects)
end


struct TObjArray
    name
    low
    elements
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TObjArray})
    preamble = Preamble(io, T)
    skiptobj(io)
    name = readtype(io, String)
    size = readtype(io, Int32)
    low = readtype(io, Int32)
    elements = [readobjany!(io, tkey, refs) for i in 1:size]
    endcheck(io, preamble)
    return TObjArray(name, low, elements)
end


abstract type AbstractTStreamerElement end

@premix @with_kw mutable struct TStreamerElementTemplate
    version
    fOffset
    fName
    fTitle
    fType
    fSize
    fArrayLength
    fArrayDim
    fMaxIndex
    fTypeName
    fXmin
    fXmax
    fFactor
end

@TStreamerElementTemplate mutable struct TStreamerElement end

@pour initparse begin
    fields = Dict{Symbol, Any}()
end

function parsefields!(io, fields, T::Type{TStreamerElement})
    preamble = Preamble(io, T)
    fields[:version] = preamble.version
    fields[:fOffset] = 0
    fields[:fName], fields[:fTitle] = nametitle(io)
    fields[:fType] = readtype(io, Int32)
    fields[:fSize] = readtype(io, Int32)
    fields[:fArrayLength] = readtype(io, Int32)
    fields[:fArrayDim] = readtype(io, Int32)

    n = preamble.version == 1 ? readtype(io, Int32) : 5
    fields[:fMaxIndex] = [readtype(io, Int32) for _ in 1:n]

    fields[:fTypeName] = readtype(io, String)

    if fields[:fType] == 11 && (fields[:fTypeName] == "Bool_t" || fields[:fTypeName] == "bool")
        fields[:fType] = 18
    end

    fields[:fXmin] = 0.0
    fields[:fXmax] = 0.0
    fields[:fFactor] = 0.0

    if preamble.version == 3
        fields[:fXmin] = readtype(io, Float64)
        fields[:fXmax] = readtype(io, Float64)
        fields[:fFactor] = readtype(io, Float64)
    end

    endcheck(io, preamble)
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerElement})
    @initparse
    parsefields!(io, fields, T)
    T(;fields...)
end


@TStreamerElementTemplate mutable struct TStreamerBase
    fBaseVersion
end

function parsefields!(io, fields, T::Type{TStreamerBase})
    preamble = Preamble(io, T)
    parsefields!(io, fields, TStreamerElement)
    fields[:fBaseVersion] = fields[:version] >= 2 ? readtype(io, Int32) : 0
    endcheck(io, preamble)
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerBase})
    @initparse
    parsefields!(io, fields, T)
    T(;fields...)
end


@TStreamerElementTemplate mutable struct TStreamerBasicType end

function parsefields!(io, fields, ::Type{TStreamerBasicType})
    parsefields!(io, fields, TStreamerElement)

    if Const.kOffsetL < fields[:fType] < Const.kOffsetP
        fields[:fType] -= Const.kOffsetP
    end
    basic = true
    if fields[:fType] ∈ (Const.kBool, Const.kUChar, Const.kChar)
        fields[:fSize] = 1
    elseif fields[:fType] in (Const.kUShort, Const.kShort)
        fields[:fSize] = 2
    elseif fields[:fType] in (Const.kBits, Const.kUInt, Const.kInt, Const.kCounter)
        fields[:fSize] = 4
    elseif fields[:fType] in (Const.kULong, Const.kULong64, Const.kLong, Const.kLong64)
        fields[:fSize] = 8
    elseif fields[:fType] in (Const.kFloat, Const.kFloat16)
        fields[:fSize] = 4
    elseif fields[:fType] in (Const.kDouble, Const.kDouble32)
        fields[:fSize] = 8
    elseif fields[:fType] == Const.kCharStar
        fields[:fSize] = sizeof(Int)
    else
        basic = false
    end

    if basic && fields[:fArrayLength] > 0
        fields[:fSize] *= fields[:fArrayLength]
    end

end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerBasicType})
    @initparse
    preamble = Preamble(io, T)
    parsefields!(io, fields, T)
    endcheck(io, preamble)
    T(;fields...)
end


@TStreamerElementTemplate mutable struct TStreamerBasicPointer
    fCountVersion
    fCountName
    fCountClass
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerBasicPointer})
    @initparse
    preamble = Preamble(io, T)
    parsefields!(io, fields, TStreamerElement)
    fields[:fCountVersion] = readtype(io, Int32)
    fields[:fCountName] = readtype(io, String)
    fields[:fCountClass] = readtype(io, String)
    endcheck(io, preamble)
    T(;fields...)
end

@TStreamerElementTemplate mutable struct TStreamerLoop
    fCountVersion
    fCountName
    fCountClass
end

components(::Type{TStreamerLoop}) = [TStreamerElement]

function parsefields!(io, fields, ::Type{TStreamerLoop})
    fields[:fCountVersion] = readtype(io, Int32)
    fields[:fCountName] = readtype(io, String)
    fields[:fCountClass] = readtype(io, String)
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerLoop})
    @initparse
    preamble = Preamble(io, T)
    for component in components(T)
        parsefields!(io, fields, component)
    end
    parsefields!(io, fields, T)
    endcheck(io, preamble)
    T(;fields...)
end

abstract type AbstractTStreamSTL end

@TStreamerElementTemplate mutable struct TStreamerSTL <: AbstractTStreamSTL
    fSTLtype
    fCtype
end

@TStreamerElementTemplate mutable struct TStreamerSTLstring <: AbstractTStreamSTL
    fSTLtype
    fCtype
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, ::Type{T}) where T <: AbstractTStreamSTL
    @initparse
    if T == TStreamerSTLstring
        wrapper_preamble = Preamble(io, T)
    end
    preamble = Preamble(io, T)
    parsefields!(io, fields, TStreamerElement)

    fields[:fSTLtype] = readtype(io, Int32)
    fields[:fCtype] = readtype(io, Int32)

    if fields[:fSTLtype] == Const.kSTLmultimap || fields[:fSTLtype] == Const.kSTLset
        if startswith(fields[:fTypeName], "std::set") || startswith(fields[:fTypeName], "set")
            fields[:fSTLtype] = Const.kSTLset
        elseif startswith(fields[:fTypeName], "std::multimap") || startswith(fields[:fTypeName], "multimap")
            fields[:fSTLtype] = Const.kSTLmultimap
        end
    end

    endcheck(io, preamble)
    if T == TStreamerSTLstring
        endcheck(io, wrapper_preamble)
    end
    T(;fields...)
end


const TObjString = String

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TObjString})
    preamble = Preamble(io, T)
    skiptobj(io)
    value = readtype(io, String)
    endcheck(io, preamble)
    T(value)
end


abstract type AbstractTStreamerObject end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, ::Type{T}) where T<:AbstractTStreamerObject
    @initparse
    preamble = Preamble(io, T)
    parsefields!(io, fields, TStreamerElement)
    endcheck(io, preamble)
    T(;fields...)
end

@TStreamerElementTemplate mutable struct TStreamerObject <: AbstractTStreamerObject end
@TStreamerElementTemplate mutable struct TStreamerObjectAny <: AbstractTStreamerObject end
@TStreamerElementTemplate mutable struct TStreamerObjectAnyPointer <: AbstractTStreamerObject end
@TStreamerElementTemplate mutable struct TStreamerObjectPointer <: AbstractTStreamerObject end
@TStreamerElementTemplate mutable struct TStreamerString <: AbstractTStreamerObject end



abstract type ROOTStreamedObject end

struct TObject <: ROOTStreamedObject end
parsefields!(io, fields, ::Type{TObject}) = skiptobj(io)

struct TString <: ROOTStreamedObject end
unpack(io, tkey::TKey, refs::Dict{Int32, Any}, ::Type{TString}) = readtype(io, String)

struct Undefined <: ROOTStreamedObject
    skipped_bytes
end

Base.show(io::IO, u::Undefined) = print(io, "$(typeof(u)) ($(u.skipped_bytes) bytes)")

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{Undefined})
    preamble = Preamble(io, T)
    bytes_to_skip = preamble.cnt - 6
    skip(io, bytes_to_skip)
    endcheck(io, preamble)
    Undefined(bytes_to_skip)
end

const TArrayD = Vector{Float64}
const TArrayI = Vector{Int32}

function readtype(io, T::Type{Vector{U}}) where U <: Union{Integer, AbstractFloat}
    size = readtype(io, eltype(T))
    [readtype(io, eltype(T)) for _ in 1:size]
end


@with_kw struct TNamed <: ROOTStreamedObject
    fName
    fTitle
end

function parsefields!(io, fields, T::Type{TNamed})
    preamble = Preamble(io, T)
    parsefields!(io, fields, TObject)
    fields[:fName] = readtype(io, String)
    fields[:fTitle] = readtype(io, String)
    endcheck(io, preamble)
end

@with_kw struct ROOT_3a3a_TIOFeatures <: ROOTStreamedObject
    fIOBits
end

function parsefields!(io, fields, T::Type{ROOT_3a3a_TIOFeatures})
    preamble = Preamble(io, T)
    skip(io, 4)
    fields[:fIOBits] = readtype(io, UInt8)
    endcheck(io, preamble)
end

# FIXME maybe this is unpack, rather than readtype?
function readtype(io, T::Type{ROOT_3a3a_TIOFeatures})
    @initparse
    parsefields!(io, fields, T)
    T(;fields...)
end


# FIXME the following stuff should be autogenerated

# FIXME this should be generated
@with_kw struct TAttLine <: ROOTStreamedObject
    fLineColor
    fLineStyle
    fLineWidth
end

function parsefields!(io, fields, T::Type{TAttLine})
    preamble = Preamble(io, T)
    fields[:fLineColor] = readtype(io, Int16)
    fields[:fLineStyle] = readtype(io, Int16)
    fields[:fLineWidth] = readtype(io, Int16)
    endcheck(io, preamble)
end

# FIXME this should be generated
@with_kw struct TAttFill <: ROOTStreamedObject
    fFillColor
    fFillStyle
end

function parsefields!(io, fields, T::Type{TAttFill})
    preamble = Preamble(io, T)
    fields[:fFillColor] = readtype(io, Int16)
    fields[:fFillStyle] = readtype(io, Int16)
    endcheck(io, preamble)
end

# FIXME this should be generated
@with_kw struct TAttMarker <: ROOTStreamedObject
    fMarkerColor
    fMarkerStyle
    fMarkerSize
end

function parsefields!(io, fields, T::Type{TAttMarker})
    preamble = Preamble(io, T)
    fields[:fMarkerColor] = readtype(io, Int16)
    fields[:fMarkerStyle] = readtype(io, Int16)
    fields[:fMarkerSize] = readtype(io, Float32)
    endcheck(io, preamble)
end

# FIXME this should be generated
@with_kw struct TLeaf
    # FIXME these two come from TNamed
    fName
    fTitle

    fLen
    fLenType
    fOffset
    fIsRange
    fIsUnsigned
    fLeafCount
end

function parsefields!(io, fields, ::Type{T}) where {T<:TLeaf}
    preamble = Preamble(io, T)
    parsefields!(io, fields, TNamed)
    fields[:fLen] = readtype(io, Int32)
    fields[:fLenType] = readtype(io, Int32)
    fields[:fOffset] = readtype(io, Int32)
    fields[:fIsRange] = readtype(io, Bool)
    fields[:fIsUnsigned] = readtype(io, Bool)
    fields[:fLeafCount] = readtype(io, UInt32)
    endcheck(io, preamble)
end

# FIXME this should be generated and inherited from TLeaf
@with_kw struct TLeafI
    # from TNamed
    fName
    fTitle

    # from TLeaf
    fLen
    fLenType
    fOffset
    fIsRange
    fIsUnsigned
    fLeafCount

    # own fields
    fMinimum
    fMaximum
end

function parsefields!(io, fields, T::Type{TLeafI})
    preamble = Preamble(io, T)
    parsefields!(io, fields, TLeaf)
    fields[:fMinimum] = readtype(io, Int32)
    fields[:fMaximum] = readtype(io, Int32)
    endcheck(io, preamble)
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TLeafI})
    @initparse
    parsefields!(io, fields, T)
    T(;fields...)
end

primitivetype(l::TLeafI) = l.fIsUnsigned ? UInt32 : Int32

# FIXME this should be generated and inherited from TLeaf
@with_kw struct TLeafF
    # from TNamed
    fName
    fTitle

    # from TLeaf
    fLen
    fLenType
    fOffset
    fIsRange
    fIsUnsigned
    fLeafCount

    # own fields
    fMinimum
    fMaximum
end

function parsefields!(io, fields, T::Type{TLeafF})
    preamble = Preamble(io, T)
    parsefields!(io, fields, TLeaf)
    fields[:fMinimum] = readtype(io, Float32)
    fields[:fMaximum] = readtype(io, Float32)
    endcheck(io, preamble)
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TLeafF})
    @initparse
    parsefields!(io, fields, T)
    T(;fields...)
end

primitivetype(l::TLeafF) = Float32

# FIXME this should be generated and inherited from TLeaf
@with_kw struct TLeafC
    # from TNamed
    fName
    fTitle

    # from TLeaf
    fLen
    fLenType
    fOffset
    fIsRange
    fIsUnsigned
    fLeafCount

    # own fields
    fMinimum
    fMaximum
end

function parsefields!(io, fields, ::Type{T}) where {T<:TLeafC}
    preamble = Preamble(io, T)
    parsefields!(io, fields, TLeaf)
    fields[:fMinimum] = readtype(io, Int32)
    fields[:fMaximum] = readtype(io, Int32)
    endcheck(io, preamble)
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, ::Type{T}) where {T<:TLeafC}
    @initparse
    parsefields!(io, fields, T)
    T(;fields...)
end

# FIXME this should be generated
@with_kw struct TBranch
    cursor::Cursor
    # from TNamed
    fName
    fTitle

    # from TAttFill
    fFillColor
    fFillStyle

    fCompress
    fBasketSize
    fEntryOffsetLen
    fWriteBasket
    fEntryNumber

    fIOFeatures

    fOffset
    fMaxBaskets
    fSplitLevel
    fEntries
    fFirstEntry
    fTotBytes
    fZipBytes

    fBranches
    fLeaves
    fBaskets
    fBasketBytes::Vector{Int64}
    fBasketEntry::Vector{Int64}
    fBasketSeek::Vector{Int64}
    fFileName
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, ::Type{T}) where {T<:TBranch}
    cursor = Cursor(position(io), io, refs)
    @initparse
    preamble = Preamble(io, T)
    parsefields!(io, fields, TNamed)
    parsefields!(io, fields, TAttFill)

    fields[:fCompress] = readtype(io, Int32)
    fields[:fBasketSize] = readtype(io, Int32)
    fields[:fEntryOffsetLen] = readtype(io, Int32)
    fields[:fWriteBasket] = readtype(io, Int32)
    fields[:fEntryNumber] = readtype(io, Int64)

    fields[:fIOFeatures] = readtype(io, ROOT_3a3a_TIOFeatures)

    fields[:fOffset] = readtype(io, Int32)
    fields[:fMaxBaskets] = readtype(io, UInt32)
    fields[:fSplitLevel] = readtype(io, Int32)
    fields[:fEntries] = readtype(io, Int64)
    fields[:fFirstEntry] = readtype(io, Int64)
    fields[:fTotBytes] = readtype(io, Int64)
    fields[:fZipBytes] = readtype(io, Int64)

    fields[:fBranches] = unpack(io, tkey, refs, TObjArray)
    fields[:fLeaves] = unpack(io, tkey, refs, TObjArray)
    fields[:fBaskets] = unpack(io, tkey, refs, TObjArray)
    # fields[:fBaskets] = unpack(io, tkey, refs, Undefined)
    speedbump = true  # FIXME speedbump?

    speedbump && skip(io, 1)

    fields[:fBasketBytes] = [readtype(io, Int32) for _ in 1:fields[:fMaxBaskets]]

    speedbump && skip(io, 1)

    # this is also called fBsketEvent, as far as I understood
    fields[:fBasketEntry] = [readtype(io, Int64) for _ in 1:fields[:fMaxBaskets]]

    speedbump && skip(io, 1)

    fields[:fBasketSeek] = [readtype(io, Int64) for _ in 1:fields[:fMaxBaskets]]
    fields[:fFileName] = readtype(io, String)

    endcheck(io, preamble)

    T(;cursor=cursor, fields...)
end


# FIXME preliminary TTree structure
@with_kw struct TTree
    # TNamed
    fName
    fTitle

    # TAttLine
    fLineColor
    fLineStyle
    fLineWidth

    # TAttFill
    fFillColor
    fFillStyle

    # TAttMarker
    fMarkerColor
    fMarkerStyle
    fMarkerSize

    fEntries
    fTotBytes
    fZipBytes
    fSavedBytes
    fFlushedBytes
    fWeight
    fTimerInterval
    fScanField
    fUpdate
    fDefaultEntryOffsetLen
    fNClusterRange
    fMaxEntries
    fMaxEntryLoop
    fMaxVirtualSize
    fAutoSave
    fAutoFlush
    fEstimate

    fClusterRangeEnd
    fClusterSize

    fIOFeatures

    fBranches
    fLeaves

    fAliases
    fIndexValues
    fIndex
    fTreeIndex
    fFriends
end

# FIXME preliminary TTree implementation
function TTree(io, tkey::TKey, refs)
    io = datastream(io, tkey)

    @initparse

    preamble = Preamble(io, Missing)

    parsefields!(io, fields, TNamed)

    parsefields!(io, fields, TAttLine)
    parsefields!(io, fields, TAttFill)
    parsefields!(io, fields, TAttMarker)

    fields[:fEntries] = readtype(io, Int64)
    fields[:fTotBytes] = readtype(io, Int64)
    fields[:fZipBytes] = readtype(io, Int64)
    fields[:fSavedBytes] = readtype(io, Int64)
    fields[:fFlushedBytes] = readtype(io, Int64)
    fields[:fWeight] = readtype(io, Float64)
    fields[:fTimerInterval] = readtype(io, Int32)
    fields[:fScanField] = readtype(io, Int32)
    fields[:fUpdate] = readtype(io, Int32)
    fields[:fDefaultEntryOffsetLen] = readtype(io, Int32)
    fields[:fNClusterRange] = readtype(io, UInt32)
    fields[:fMaxEntries] = readtype(io, Int64)
    fields[:fMaxEntryLoop] = readtype(io, Int64)
    fields[:fMaxVirtualSize] = readtype(io, Int64)
    fields[:fAutoSave] = readtype(io, Int64)
    fields[:fAutoFlush] = readtype(io, Int64)
    fields[:fEstimate] = readtype(io, Int64)

    # FIXME what about speedbumps??
    speedbump = true

    speedbump && skip(io, 1)
    fields[:fClusterRangeEnd] = [readtype(io, Int64) for _ in 1:fields[:fNClusterRange]]
    speedbump && skip(io, 1)
    fields[:fClusterSize] = [readtype(io, Int64) for _ in 1:fields[:fNClusterRange]]

    fields[:fIOFeatures] = readtype(io, ROOT_3a3a_TIOFeatures)

    fields[:fBranches] = unpack(io, tkey, refs, TObjArray)
    fields[:fLeaves] = unpack(io, tkey, refs, TObjArray)

    fields[:fAliases] = readobjany!(io, tkey, refs)
    fields[:fIndexValues] = readtype(io, TArrayD)
    fields[:fIndex] = readtype(io, TArrayI)
    fields[:fTreeIndex] = readobjany!(io, tkey, refs)
    fields[:fFriends] = readobjany!(io, tkey, refs)

    # uproot unpacks Undefined instances here, we cannot since
    # the Base.GenericIOBuffer{Array{UInt8,1}} from the compression
    # library throws an EOFError when we read more than available.
    # FIXME this needs to be checked though!
    while !eof(io)
        read(io, 1)
    end
    # unpack(io, tkey, refs, Undefined)
    # println(fields[:fBranches])

    endcheck(io, preamble)
    TTree(;fields...)
end

Base.keys(t::TTree) = [b.fName for b in t.fBranches.elements]

function getbranch(t::TTree, s::AbstractString)
    for branch in t.fBranches.elements
        if branch.fName == s
            return branch
        end
    end
    missing
end

function Base.getindex(t::TTree, s::AbstractString)
    getbranch(t, s)
end
