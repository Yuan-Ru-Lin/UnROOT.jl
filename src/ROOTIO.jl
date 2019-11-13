module ROOTIO

using StaticArrays

struct TKey{T<:Integer}
    identifier::SVector{4, UInt8}  # Root file identifier ("root")
    fVersion::Int32               # File format version
    fBEGIN::Int32                 # Pointer to first data record
    fEND::T                       # Pointer to first free word at the EOF
    fSeekFree::T                  # Pointer to FREE data record
    fNbytesFree::Int32            # Number of bytes in FREE data record
    nfree::Int32                  # Number of free data records
    fNbytesName::Int32            # Number of bytes in TNamed at creation time
    fUnits::UInt8                 # Number of bytes for file pointers
    fCompress::Int32              # Compression level and algorithm
    fSeekInfo::T                  # Pointer to TStreamerInfo record
    fNbytesInfo::Int32            # Number of bytes in TStreamerInfo record
    fUUID::SVector{18, UInt8}      # Universal Unique ID
end

end # module
