##############################################################################
##
## Sorting
##
##############################################################################

#########################################
## Permutation & Ordering types/functions
#########################################
# Sorting in Julia works through Orderings, where each ordering is a type
# which defines a comparison function lt(o::Ord, a, b).

# UserColOrdering: user ordering of a column; this is just a convenience container
#                  which allows a user to specify column specific orderings
#                  with "order(column, rev=true,...)"

type UserColOrdering{T<:ColumnIndex}
    col::T
    kwargs
end

# This is exported, and lets a user define orderings for a particular column
order{T<:ColumnIndex}(col::T; kwargs...) = UserColOrdering{T}(col, kwargs)

# Allow getting the column even if it is not wrapped in a UserColOrdering
_getcol(o::UserColOrdering) = o.col
_getcol(x) = x

###
# Get an Ordering for a single column
###
function ordering(col_ord::UserColOrdering, lt::Function, by::Function, rev::Bool, order::Ordering)
    for (k,v) in col_ord.kwargs
        if     k == :lt;    lt    = v
        elseif k == :by;    by    = v
        elseif k == :rev;   rev   = v
        elseif k == :order; order = v
        else
            error("Unknown keyword argument: ", string(k))
        end
    end

    ord(lt,by,rev,order)
end

ordering(col::ColumnIndex, lt::Function, by::Function, rev::Bool, order::Ordering) =
             ord(lt,by,rev,order)

# DFPerm: defines a permutation on a particular DataFrame, using
#         a single ordering (O<:Ordering) or a list of column orderings
#         (O<:AbstractVector{Ordering}), one per DataFrame column
#
#         If a user only specifies a few columns, the DataFrame
#         contained in the DFPerm only contains those columns, and
#         the permutation induced by this ordering is used to
#         sort the original (presumably larger) DataFrame

type DFPerm{O<:Union(Ordering, AbstractVector), DF<:AbstractDataFrame} <: Ordering
    ord::O
    df::DF
end

function DFPerm{O<:Ordering}(ords::AbstractVector{O}, df::AbstractDataFrame)
    if length(ords) != ncol(df)
        error("DFPerm: number of column orderings does not equal the number of DataFrame columns")
    end
    DFPerm{AbstractVector{O}, typeof(df)}(ords, df)
end

DFPerm{O<:Ordering}(o::O, df::AbstractDataFrame) = DFPerm{O,typeof(df)}(o,df)

# For sorting, a and b are row indices (first two lt definitions)
# For issorted, the default row iterator returns DataFrameRows instead,
# so two more lt function is defined below
function Base.Sort.lt{V<:AbstractVector}(o::DFPerm{V}, a, b)
    for i = 1:ncol(o.df)
        if lt(o.ord[i], o.df[a,i], o.df[b,i])
            return true
        end
        if lt(o.ord[i], o.df[b,i], o.df[a,i])
            return false
        end
    end
    false
end

function Base.Sort.lt{O<:Ordering}(o::DFPerm{O}, a, b)
    for i = 1:ncol(o.df)
        if lt(o.ord, o.df[a,i], o.df[b,i])
            return true
        end
        if lt(o.ord, o.df[b,i], o.df[a,i])
            return false
        end
    end
    false
end

function Base.Sort.lt{V<:AbstractVector}(o::DFPerm{V}, a::DataFrameRow, b::DataFrameRow)
    for i = 1:ncol(o.df)
        if lt(o.ord[i], a[i], b[i])
            return true
        end
        if lt(o.ord[i], b[i], a[i])
            return false
        end
    end
    false
end

function Base.Sort.lt{O<:Ordering}(o::DFPerm{O}, a::DataFrameRow, b::DataFrameRow)
    for i = 1:ncol(o.df)
        if lt(o.ord, a[i], b[i])
            return true
        end
        if lt(o.ord, b[i], a[i])
            return false
        end
    end
    false
end

###
# Get an Ordering for a DataFrame
###

################
## Case 1: no columns requested, so sort by all columns using requested order
################
## Case 1a: single order
######
ordering(df::AbstractDataFrame, lt::Function, by::Function, rev::Bool, order::Ordering) =
    DFPerm(ord(lt, by, rev, order), df)

######
## Case 1b: lt, by, rev, and order are Arrays
######
function ordering(df::AbstractDataFrame, lt::AbstractVector{Function}, by::AbstractVector{Function}, rev::AbstractVector{Bool}, order::AbstractVector)
    if !(length(lt) == length(by) == length(rev) == length(order) == size(df,2))
        throw(ArgumentError("Orderings must be specified for all DataFrame columns"))
    end
    DFPerm([ord(_lt, _by, _rev, _order) for (_lt, _by, _rev, _order) in zip(lt, by, rev, order)], df)
end

################
## Case 2:  Return a regular permutation when there's only one column
################
## Case 2a: The column is given directly
######
ordering(df::AbstractDataFrame, col::ColumnIndex, lt::Function, by::Function, rev::Bool, order::Ordering) =
    Perm(ord(lt, by, rev, order), df[col])

######
## Case 2b: The column is given as a UserColOrdering
######
ordering(df::AbstractDataFrame, col_ord::UserColOrdering, lt::Function, by::Function, rev::Bool, order::Ordering) =
    Perm(ordering(col_ord, lt, by, rev, order), df[col_ord.col])

################
## Case 3:  General case: cols is an iterable of a combination of ColumnIndexes and UserColOrderings
################
## Case 3a: None of lt, by, rev, or order is an Array
######
function ordering(df::AbstractDataFrame, cols::AbstractVector, lt::Function, by::Function, rev::Bool, order::Ordering)

    if length(cols) == 0
        return ordering(df, lt, by, rev, order)
    end

    if length(cols) == 1
        return ordering(df, cols[1], lt, by, rev, order)
    end

    # Collect per-column ordering info

    ords = Ordering[]
    newcols = Int[]

    for col in cols
        push!(ords, ordering(col, lt, by, rev, order))
        push!(newcols, index(df)[(_getcol(col))])
    end

    # Simplify ordering when all orderings are the same
    if all([ords[i] == ords[1] for i = 2:length(ords)])
        return DFPerm(ords[1], df[newcols])
    end

    return DFPerm(ords, df[newcols])
end

######
# Case 3b: cols, lt, by, rev, and order are all arrays
######
function ordering(df::AbstractDataFrame, cols::AbstractVector,
                  lt::AbstractVector{Function}, by::AbstractVector{Function}, rev::AbstractVector{Bool}, order::AbstractVector)

    if !(length(lt) == length(by) == length(rev) == length(order))
        throw(ArgumentError("All ordering arguments must be 1 or the same length."))
    end

    if length(cols) == 0
        return ordering(df, lt, by, rev, order)
    end

    if length(lt) != length(cols)
        throw(ArgumentError("All ordering arguments must be 1 or the same length as the number of columns requested."))
    end

    if length(cols) == 1
        return ordering(df, cols[1], lt[1], by[1], rev[1], order[1])
    end

    # Collect per-column ordering info

    ords = Ordering[]
    newcols = Int[]

    for i in 1:length(cols)
        push!(ords, ordering(cols[i], lt[i], by[i], rev[i], order[i]))
        push!(newcols, index(df)[(_getcol(cols[i]))])
    end

    # Simplify ordering when all orderings are the same
    if all([ords[i] == ords[1] for i = 2:length(ords)])
        return DFPerm(ords[1], df[newcols])
    end

    return DFPerm(ords, df[newcols])
end

######
## At least one of lt, by, rev, or order is an array or tuple, so expand all to arrays
######
function ordering(df::AbstractDataFrame, cols::AbstractVector, lt, by, rev, order)
    to_array(src::AbstractVector, dims) = src
    to_array(src::Tuple, dims) = [src...]
    to_array(src, dims) = fill(src, dims)

    dims = length(cols) > 0 ? length(cols) : size(df,2)
    ordering(df, cols,
             to_array(lt, dims),
             to_array(by, dims),
             to_array(rev, dims),
             to_array(order, dims))
end

#### Convert cols from tuple to Array, if necessary
ordering(df::AbstractDataFrame, cols::Tuple, args...) = ordering(df, [cols...], args...)


###########################
# Default sorting algorithm
###########################

# TimSort is fast for data with structure, but only if the DataFrame is large enough
# TODO: 8192 is informed but somewhat arbitrary

defalg(df::AbstractDataFrame) = size(df, 1) < 8192 ? Sort.MergeSort : SortingAlgorithms.TimSort

# For DataFrames, we can choose the algorithm based on the column type and requested ordering
function defalg{T<:Real}(df::AbstractDataFrame, ::Type{T}, o::Ordering)
    # If we're sorting a single numerical column in forward or reverse,
    # RadixSort will generally be the fastest stable sort
    if isbits(T) && sizeof(T) <= 8 && (o==Order.Forward || o==Order.Reverse)
        SortingAlgorithms.RadixSort
    else
        defalg(df)
    end
end
defalg(df::AbstractDataFrame,        ::Type,          o::Ordering) = defalg(df)
defalg(df::AbstractDataFrame, col    ::ColumnIndex,   o::Ordering) = defalg(df, eltype(df[col]), o)
defalg(df::AbstractDataFrame, col_ord::UserColOrdering, o::Ordering) = defalg(df, col_ord.col, o)
defalg(df::AbstractDataFrame, cols,                   o::Ordering) = defalg(df)

function defalg(df::AbstractDataFrame, o::Ordering; alg=nothing, cols=[])
    alg != nothing && return alg
    defalg(df, cols, o)
end

########################
## Actual sort functions
########################

issorted(df::AbstractDataFrame; cols={}, lt=isless, by=identity, rev=false, order=Forward) =
    issorted(eachrow(df), ordering(df, cols, lt, by, rev, order))

# sort!, sort, and sortperm functions

for s in {:sort!, :sort, :sortperm}
    @eval begin
        function $s(df::AbstractDataFrame; cols={}, alg=nothing,
                    lt=isless, by=identity, rev=false, order=Forward)
            ord = ordering(df, cols, lt, by, rev, order)
            _alg = defalg(df, ord; alg=alg, cols=cols)
            $s(df, _alg, ord)
        end
    end
end

function Base.sort!(df::AbstractDataFrame, a::Base.Sort.Algorithm, o::Base.Sort.Ordering)
    p = sortperm(df, a, o)
    pp = similar(p)
    for col in df.columns
        copy!(pp,p)
        Base.permute!!(col, pp)
    end
    df
end

sort    (df::AbstractDataFrame, a::Algorithm, o::Ordering) = df[sortperm(df, a, o),:]
sortperm(df::AbstractDataFrame, a::Algorithm, o::Union(Perm,DFPerm)) = sort!([1:size(df, 1)], a, o)
sortperm(df::AbstractDataFrame, a::Algorithm, o::Ordering) = sortperm(df, a, DFPerm(o,df))

# Extras to speed up sorting
sortperm{V}(d::AbstractDataFrame, a::Algorithm, o::FastPerm{Sort.ForwardOrdering,V}) = sortperm(o.vec)
sortperm{V}(d::AbstractDataFrame, a::Algorithm, o::FastPerm{Sort.ReverseOrdering,V}) = reverse(sortperm(o.vec))

## Deprecated; remove after julia v0.3 is released (or sooner)

typealias ColIndexVec Union(AbstractVector{Integer}, AbstractVector{ASCIIString}, AbstractVector{UTF8String}, AbstractVector{Symbol})

@deprecate sort!(df::AbstractDataFrame, o::Ordering)  sort!(df,order=o)
@deprecate sort(df::AbstractDataFrame, o::Ordering)  sort(df,order=o)
@deprecate sortperm(df::AbstractDataFrame, o::Ordering)  sortperm(df, order=o)

@deprecate sortby!(df::AbstractDataFrame, by::Function)  sort!(df,by=by)

@deprecate sortby!(df::AbstractDataFrame, col ::ColumnIndex, o::Ordering)  sort!(df,cols=col,order=o)
@deprecate sortby!(df::AbstractDataFrame, col ::ColumnIndex)               sort!(df,cols=col)
@deprecate sortby!(df::AbstractDataFrame, cols::ColIndexVec, o::Ordering)  sort!(df,cols=cols,order=o)
@deprecate sortby!(df::AbstractDataFrame, cols::ColIndexVec)               sort!(df,cols=cols)
@deprecate sortby(df::AbstractDataFrame, col ::ColumnIndex, o::Ordering)  sort(df,cols=col,order=o)
@deprecate sortby(df::AbstractDataFrame, col ::ColumnIndex)               sort(df,cols=col)
@deprecate sortby(df::AbstractDataFrame, cols::ColIndexVec, o::Ordering)  sort(df,cols=cols,order=o)
@deprecate sortby(df::AbstractDataFrame, cols::ColIndexVec)               sort(df,cols=cols)

#@deprecate sort!   {O<:Ordering}(df::AbstractDataFrame, ::Type{O})    sort!   (df, order=O())
#@deprecate sort    {O<:Ordering}(df::AbstractDataFrame, ::Type{O})    sort    (df, order=O())
#@deprecate sortperm{O<:Ordering}(df::AbstractDataFrame, ::Type{O})    sortperm(df, order=O())

#@deprecate sortby!{O<:Ordering}(df::AbstractDataFrame, col::ColumnIndex, ::Type{O})                   sort!(df,col=col,order=O())
#@deprecate sortby!{O<:Ordering}(df::AbstractDataFrame, cols::ColIndexVec, ::Type{O})                  sort!(df,cols=cols,order=O())
#@deprecate sortby!{O<:Ordering}(df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray{O})        sort!(df,DFPerm(o, df[cols]))
#@deprecate sortby {O<:Ordering}(df::AbstractDataFrame, col::ColumnIndex, ::Type{O})                   sort (df,col=col,order=O())
#@deprecate sortby {O<:Ordering}(df::AbstractDataFrame, cols::ColIndexVec, ::Type{O})                  sort (df,cols=cols,order=O())
#@deprecate sortby {O<:Ordering}(df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray{O})        sort (df,DFPerm(o, df[cols]))

#@deprecate sortby!             (df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray{DataType}) sort!(df,DFPerm(Ordering[O() for O in o], df[cols]))
#           sortby!             (df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray)           sortby!(df,cols,DataType[ot for ot in o])
#           sortby!             (df::AbstractDataFrame, col_ord::AbstractArray{Tuple}) = ((cols,o) = zip(col_ord...); sortby!(df, [cols...], [o...]))
#@deprecate sortby              (df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray{DataType}) sort (df,DFPerm(Ordering[O() for O in o], df[cols]))
#           sortby              (df::AbstractDataFrame, cols::ColIndexVec, o::AbstractArray)           sortby!(df,cols,DataType[ot for ot in o])
#           sortby              (df::AbstractDataFrame, col_ord::AbstractArray{Tuple}) = ((cols,o) = zip(col_ord...); sortby!(df, [cols...], [o...]))
