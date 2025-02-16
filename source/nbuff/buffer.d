module nbuff.buffer;

import std.string;
import std.array;
import std.algorithm;
import std.conv;
import std.range;
import std.stdio;
import std.traits;
import std.format;
import core.exception;
import std.exception;
import std.range.primitives;
import std.experimental.logger;

import core.memory: GC;

private import std.experimental.allocator;
private import std.experimental.allocator.mallocator : Mallocator;

///
// network buffer
///

/// Range Empty exception
static immutable Exception RangeEmpty = new Exception("try to pop from empty Buffer"); // @suppress(dscanner.style.phobos_naming_convention) // @suppress(dscanner.style.phobos_naming_convention)
/// Requested index is out of range
static immutable Exception IndexOutOfRange = new Exception("Index out of range");
/// Buffer internal struct problem
static immutable Exception BufferError = new Exception("Buffer internal struct corrupted");

// goals
// 1 minomal data copy
// 2 Range interface
// 3 minimal footprint


public alias BufferChunk =       immutable(ubyte)[];
public alias BufferChunksArray = immutable(BufferChunk)[];

debug(nbuff) @safe @nogc nothrow
{
    import std.experimental.logger;
    package void safe_tracef(A...)(string f, scope A args, string file = __FILE__, int line = __LINE__) @safe @nogc nothrow
    {
        bool osx,ldc;
        version(OSX)
        {
            osx = true;
        }
        version(LDC)
        {
            ldc = true;
        }
        if (!osx || !ldc)
        {
            // this can fail on pair ldc2/osx, see https://github.com/ldc-developers/ldc/issues/3240
            import core.thread;
            () @trusted @nogc nothrow
            {
                try
                {
                    //debug(nbuff)writefln("[%x] %s:%d " ~ f, Thread.getThis().id(), file, line, args);
                }
                catch(Exception e)
                {
                    () @trusted @nogc nothrow
                    {
                        try
                        {
                            //debug(nbuff)errorf("[%x] %s:%d Exception: %s", Thread.getThis().id(), file, line, e);
                        }
                        catch
                        {
                        }
                    }();
                }
            }();
        }
    }    
}

debug(nbuff)
{
    void safe_printf(A...)(A a) @trusted
    {
        import core.stdc.stdio: printf;
        //printf(&a[0][0], a[1..$]);
    }
}

package static MemPool _mempool;
static this()
{
    for(int i=0;i<MemPool.IndexLimit;i++)
    {
        _mempool._poolSize[i] = 1024;
        _mempool._pools[i] = Mallocator.instance.makeArray!(ubyte[])(1024);
    }
}
private static bool in_exit;
static ~this()
{
    in_exit = true;
    for(int i=0;i<MemPool.IndexLimit;i++)
    {
        for(int j=0; j < _mempool._mark[i]; j++)
        {
            Mallocator.instance.dispose(_mempool._pools[i][j]);
        }
        _mempool._mark[i] = 0;
        Mallocator.instance.dispose(_mempool._pools[i]);
    }
}

alias allocator = Mallocator.instance;
static immutable Exception MemPoolException = new Exception("MemPoolException");
static immutable Exception NbuffError = new Exception("NbuffError");
struct MemPool
{
    // class MemPoolException: Exception
    // {
    //     this(string msg) @nogc @safe
    //     {
    //         super(msg);
    //     }
    // }

    import core.bitop;
    private
    {
        enum MinSize = 64;
        enum MaxSize = 64*1024;
        enum IndexLimit = bsr(MaxSize);
        enum MaxPoolWidth = 64*1024;
        alias ChunkInPool = ubyte[];
        alias Pool = ChunkInPool[];
        Pool[IndexLimit]    _pools;
        size_t[IndexLimit]  _poolSize;
        size_t[IndexLimit]  _mark;
    }
    ~this() @safe @nogc
    {
        for(int i=0;i<MemPool.IndexLimit;i++)
        {
            () @trusted {
                for(int j=0; j < _mark[i]; j++)
                {
                    allocator.deallocate(_pools[i][j]);
                }
                _mark[i] = 0;
                allocator.deallocate(_pools[i]);
            }();
        }
    }
    ChunkInPool alloc(size_t size) @nogc @safe
    {
        if ( size < MinSize )
        {
            size = MinSize;
        }
        if (size>MaxSize)
        {
            throw MemPoolException;
        }
        immutable i = bsr(size);
        immutable index = _mark[i];
        if (index == 0)
        {
            auto b = allocator.makeArray!(ubyte)(2<<i);
            debug(nbuff) safe_tracef("allocated %d new bytes(because pool[%d] empty) at %x", size, i, &b[0]);
            return b;
        }
        auto b = _pools[i][index-1];
        _mark[i]--;
        assert(_mark[i]>=0);
        debug(nbuff) safe_tracef("allocated chunk from pool %d size %d", i, size);
        return b;
    }
    void free(ChunkInPool c, size_t size) @nogc @trusted
    {
        if ( size < MinSize )
        {
            size = MinSize;
        }
        if (size>MaxSize)
        {
            throw MemPoolException;
        }
        if (in_exit)
        {
            // mem pool can be destroyed already
            allocator.deallocate(c);
            return;
        }
        immutable pool_index = bsr(size);
        immutable index = _mark[pool_index];
        if (index<_poolSize[pool_index])
        {
            _pools[pool_index][index] = c;
            _mark[pool_index]++;
            debug(nbuff) safe_tracef("freed to pool[%d], next position %d, size(%d)", pool_index, _mark[pool_index], c.length);
        }
        else if (_poolSize[pool_index] < MaxPoolWidth)
        {
            // double size
            debug(nbuff) safe_tracef("double pool %d from %d (requested index=%d)", pool_index, _poolSize[pool_index], index);
            auto ok = allocator.expandArray!(ubyte[])(_pools[pool_index], _poolSize[pool_index]);
            if ( !ok )
            {
                throw MemPoolException;
            }
            _poolSize[pool_index] *= 2;
            _pools[pool_index][index] = c;
            _mark[pool_index]++;
            debug(nbuff) safe_tracef("pool %d doubled to %d", pool_index, _poolSize[pool_index]);
        }
        else
        {
            allocator.deallocate(c);
        }
    }
}


@("MemPool")
@safe @nogc unittest
{
    MemPool __mempool;
    //globalLogLevel = LogLevel.info;
    for(int i=0;i<MemPool.IndexLimit;i++)
    {
        __mempool._poolSize[i] = 1024;
        __mempool._pools[i] = Mallocator.instance.makeArray!(ubyte[])(1024);
    }

    for(size_t size=128;size<=64*1024; size = size + size/2)
    {
        auto m = __mempool.alloc(size);
        __mempool.free(m, size);
    }

    for(size_t size=128;size<=64*1024; size = size + size/2)
    {
        auto m = __mempool.alloc(size);
        __mempool.free(m, size);
    }
    auto m = __mempool.alloc(128);
    copy("abcd".representation, m);
    __mempool.free(m, 128);
    ubyte[][64*1024] cip;
    for(int c=0;c<128;c++)
    {
        for(int i=0;i<64*1024;i++)
        {
            cip[i] = __mempool.alloc(i);
        }
        for(int i=0;i<64*1024;i++)
        {
            __mempool.free(cip[i],i);
        }
        for(int i=0;i<64*1024;i++)
        {
            cip[i] = __mempool.alloc(i);
        }
        for(int i=0;i<64*1024;i++)
        {
            __mempool.free(cip[i],i);
        }
    }
}

struct SmartPtr(T)
{
    private struct Impl
    {
        T       _object;
        int     _count;
        alias   _object this;
    }
    public
    {
        Impl*   _impl;
    }
    this(Args...)(auto ref Args args, string file = __FILE__, int line = __LINE__) @trusted
    {
        import std.functional: forward;
        //_impl = allocator.make!(Impl)(T(args),1);
        _impl = cast(typeof(_impl)) allocator.allocate(Impl.sizeof);
        _impl._count = 1;
        emplace(&_impl._object, forward!args);
        debug(nbuff) safe_tracef("emplaced", _count);
    }
    this(this)
    {
        if (_impl) inc;
    }
    string toString()
    {
        return "(rc: %d, object: %s)".format(_impl?_impl._count:0, _impl?_impl._object.to!string():"none");
    }
    void construct() @trusted
    {
        if (_impl) rel;
        _impl = cast(typeof(_impl)) allocator.allocate(Impl.sizeof);
        _impl._count = 1;
        emplace(&_impl._object);
        // _impl = allocator.make!(Impl)(T.init,1);
    }
    ~this()
    {
        if (_impl is null)
        {
            return;
        }
        if (dec == 0)
        {
            () @trusted {dispose(allocator, _impl);}();
        }
    }
    void opAssign(ref typeof(this) other, string file = __FILE__, int line = __LINE__)
    {
        if (_impl == other._impl)
        {
            return;
        }
        if (_impl)
        {
            rel;
        }
        _impl = other._impl;
        if (_impl)
        {
            inc;
        }
    }
    private void inc() @safe @nogc
    {
        _impl._count++;
    }
    private auto dec() @safe @nogc
    {
        return --_impl._count;
    }
    private void rel() @trusted
    {
        if ( _impl is null )
        {
            return;
        }
        if (dec == 0)
        {
            dispose(allocator, _impl);
        }
    }
    alias _impl this;
}

auto smart_ptr(T, Args...)(Args args)
{
    return SmartPtr!(T)(args);
}

@("smart_ptr")
@safe
@nogc
unittest
{
    struct S
    {
        int i;
        this(int v)
        {
            i = v;
        }
        void set(int v)
        {
            i = v;
        }
    }
    safe_tracef("test");
    auto ptr0 = smart_ptr!S(1);
    assert(ptr0._impl._count == 1);
    assert(ptr0.i == 1);
    ptr0.set(2);
    assert(ptr0.i == 2);
    SmartPtr!S ptr1;
    ptr1.construct();
    assert(ptr1._impl._count == 1);
    SmartPtr!S ptr2 = ptr0;
    assert(ptr0._impl._count == 2);
    ptr2 = ptr1;
    assert(ptr2._impl._count == 2);
}

struct UniquePtr(T)
{
    private struct Impl
    {
        T       _object;
        alias   _object this;
    }
    @disable this(this); // only move
    private
    {
        Impl*   _impl;
    }
    this(Args...)(auto ref Args args) @safe
    {
        auto v = T(args);
        _impl = allocator.make!(Impl)();
        swap(v, _impl._object);
    }
    ~this() @trusted @nogc
    {
        if ( _impl)
        {
            dispose(allocator, _impl);
            _impl = null;
        }
    }
    private void rel() @trusted
    {
        if ( _impl is null )
        {
            return;
        }
        dispose(allocator, _impl);
        _impl = null;
    }
    void release()
    {
        rel;
    }
    void borrow(ref typeof(this) other)
    {
        if ( _impl )
        {
            rel;
        }
        swap(_impl,other._impl);
    }
    bool isNull() @safe @nogc nothrow
    {
        return _impl is null;
    }
    auto opDispatch(string op, Args...)(Args args)
    {
        mixin("return _impl._object.%s;".format(op));
    }
    alias _impl this;
}

auto unique_ptr(T, Args...)(Args args)
{
    return UniquePtr!(T)(args);
}

@("unique_ptr")
@safe
@nogc
unittest
{
    static struct S
    {
        int i;
    }
    UniquePtr!S ptr0 = UniquePtr!S(1);
    assert(ptr0.i == 1);
    UniquePtr!S ptr1;
    ptr1.borrow(ptr0);
    assert(ptr1.i == 1);
    auto ptr2 = unique_ptr!S(2);
    assert(ptr2.i == 2);
    ptr2.release();
}

struct MutableMemoryChunk
{
    debug(nbuff) static int __id;
    private
    {
        ubyte[] _data;
        size_t  _size;
    }
    debug(nbuff) public
    {
        int     _id;
    }
    // @disable this(this);

    this(size_t s) @safe @nogc
    {
        if (s<=MemPool.MaxSize)
        {
            debug(nbuff) _id = __id++;
            debug(nbuff) tracef("alloc from pool %d\n", _id);
            _data = _mempool.alloc(s);
        }
        else
        {
            _data = allocator.makeArray!ubyte(s);
        }
        _size = s;
    }
    ~this() @safe @nogc
    {
        debug(nbuff) safe_tracef("destroy: %s, %s", _data, _size);
        if ( _size == 0 )
        {
            return;
        }
        if ( _size <= MemPool.MaxSize)
        {
            _mempool.free(_data, _size);
        }
        else
        {
            () @trusted {dispose(allocator, _data);}();
        }
    }
    private immutable(ubyte[]) consume() @system @nogc
    {
        auto v = assumeUnique(_data);
        _data = null;
        _size = 0;
        return v;
    }

    auto size() pure inout @safe @nogc nothrow
    {
        return _size;
    }
    auto data() pure inout @system @nogc nothrow
    {
        return _data;
    }
    alias _data this;
}

@("MutableMemoryChunk")
unittest
{
    import std.stdio;
    import std.array;
    {
        auto c = MutableMemoryChunk(16);
        auto data = c.data();
        auto size = c.size();
        data[0] = 1;
        data[1..5] = [2, 3, 4, 5];
        assert(c.data[0] == 1);
        ubyte[128] payload = 2;
        data = data ~ payload; // you can append but this do not change anything for c
        assert(c.data[0] == 1 && c.size() == size);
        //copy(payload.array, c.data); XXX check
        assert(c.data[0] == 1 && c.size() == size);
        auto v = c.consume();
        assert(equal(v[0..5], [1,2,3,4,5]));
        _mempool.free(cast(ubyte[])v, size);
    }
    {
        auto c = MutableMemoryChunk(16);
        auto data = c.data();
        auto size = c.size();
        data[0] = 1;
        data[1..5] = [2, 3, 4, 5];
        assert(c.data[0] == 1);
        ubyte[128] payload = 2;
        data = data ~ payload; // you can append but this do not change anything for c
        assert(c.data[0] == 1 && c.size() == size);
        //copy(payload.array, c.data); XXX check
        assert(c.data[0] == 1 && c.size() == size);
        auto v = c.consume();
        assert(equal(v[0..5], [1,2,3,4,5]));
        _mempool.free(cast(ubyte[])v, size);
    }
    auto mutmemptr = unique_ptr!MutableMemoryChunk(16);
    assert(mutmemptr.size==16);
}

struct ImmutableMemoryChunk
{
    debug(nbuff) public
    {
        int     _id = -1;
    }
    private
    {
        immutable(ubyte[]) _data;
        immutable size_t   _size;
    }

    @disable this(this);

    this(ref MutableMemoryChunk c) @trusted @nogc
    {
        // trusted because
        // 1. Chunk have disabled copy constructor so we have single copy of memory under chunk
        // 2. user can't change data location
        _size = c.size;
        _data = assumeUnique(c.consume());
        debug(nbuff) _id = c._id;
    }
    this(string s) @safe @nogc
    {
        () @trusted {
            GC.addRange(&this._data, _data.sizeof);
        }();
        _data = s.representation();
        _size = 0;
    }
    this(immutable(ubyte)[] s) @safe @nogc
    {
        () @trusted {
            GC.addRange(&this._data, _data.sizeof);
        }();
        _data = s;
        _size = 0;
    }
    ~this() @trusted @nogc
    {
        // trusted because ...see constructor
        if ( _data !is null && _size == 0)
        {
            GC.removeRange(&this._data);
        }
        if ( _data is null || _size == 0 )
        {
            return;
        }
        if (_size <= MemPool.MaxSize)
        {
            debug(nbuff) safe_printf("return mem to pool %d\n", _id);
            _mempool.free(cast(ubyte[])_data, _size);
        }
        else
        {
            debug(nbuff) safe_printf("disposing large buffer\n");
            dispose(allocator, _data.ptr);
        }
    }
    string toString()
    {
        return "[%(%0.2x,%)]".format(_data);
    }
    auto size() pure inout @safe @nogc nothrow
    {
        return _size;
    }
    auto data() pure inout @safe @nogc nothrow
    {
        return _data;
    }
    alias _data this;
}

@("ImmutableMemoryChunk")
unittest
{
    import std.traits;
    MutableMemoryChunk c = MutableMemoryChunk(16);
    c.data[0..8] = [0, 1, 2, 3, 4, 5, 6, 7];
    ImmutableMemoryChunk ic = ImmutableMemoryChunk(c);
    assert(equal(ic.data[0..8], [0, 1, 2, 3, 4, 5, 6, 7]));

    assert(!__traits(compiles, {ic._data[0] = 2;}));
    assert(!__traits(compiles, {ic._data ~= "123".representation;}));

    auto d = ic.data;
    assert(!__traits(compiles, {d[0] = 2;}));
    assert(!__traits(compiles, {d ~= "123".representation;}));
    c = MutableMemoryChunk(16);
    auto imc = SmartPtr!ImmutableMemoryChunk(c);
}

struct NbuffChunk
{

    private
    {
        size_t                          _beg, _end;
        SmartPtr!(ImmutableMemoryChunk) _memory;
    }
    // ~this() @trusted @nogc
    // {
    //     if (_memory)
    //     {
    //         debug(nbuff) printf("on ~NbuffChunk: %d\n", _memory._count);
    //         debug(nbuff) printf("on ~NbuffChunk: %s\n", toStringz(dump()));
    //     }
    // }
    this(ref UniquePtr!MutableMemoryChunk c, size_t l) @safe @nogc
    {
        _memory = SmartPtr!ImmutableMemoryChunk(c._impl._object);
        _end = l;
        c.release;
    }
    this(string s) @safe @nogc
    {
        _memory = SmartPtr!ImmutableMemoryChunk(s);
        _end = s.length;
    }
    this(immutable(ubyte)[] s) @safe @nogc
    {
        _memory = SmartPtr!ImmutableMemoryChunk(s);
        _end = s.length;
    }
    string dump() inout @safe
    {
        import std.range: chunks;
        import std.ascii;

        int p;
        string res = "▌%-72.72s▐\n".format("_beg=%d _end=%d _size=%d".format(_beg, _end,_memory._impl._size));
        foreach(c; chunks(_memory._impl._object[0.._end], 16))
        {
            res ~= "▌%5.5d ".format(p);
            foreach(s; c)
            {
                if (p == _beg)
                {
                    res ~= "▛%02.2x".format(s);
                }
                else
                {
                    res ~= " %02.2x".format(s);
                }
                p++;
            }
            if (p == _end)
            {
                res ~= "▟";
            }
            if (c.length < 16)
            {
                res ~= repeat("◦◦", (16 - c.length)).join(" ");
            }
            if ( p == _end && p % 16 == 0 )
            {
                res ~= " ";
            }
            else
            {
                res ~= "  ";
            }
            foreach(s; c)
            {
                if ( isPrintable(s) )
                {
                    res ~= "%c".format(cast(char)s);
                }
                else
                {
                    if (s == 13)
                    {
                        res ~= "⇦";
                    }
                    else if ( s == 10 )
                    {
                        res ~= "⇓";
                    }
                    else
                    {
                        res ~= ".";
                    }
                }
            }
            if (c.length < 16)
            {
                res ~= repeat("◦", (16 - c.length)).join();
            }
            res ~= "▐\n";
        }
        return res;
    }
    string toString() inout @trusted
    {
        if ( _memory._impl is null)
        {
            return null;
        }
        return cast(string)data().idup;
    }
    string toLower() @safe
    {
        // trusted as data do not leave scope
        return this.toString().toLower;
    }
    string toUpper() @safe
    {
        // trusted as data do not leave scope
        return this.toString.toUpper();
    }
    public auto size() pure inout nothrow @safe @nogc
    {
        return _memory._size;
    }
    public auto length() @safe @nogc inout
    {
        return _end - _beg;
    }
    public auto data() inout @system @nogc
    {
        return _memory._impl._object[_beg.._end];
    }
    void opAssign(T)(auto ref T other, string file = __FILE__, int line = __LINE__) @safe @nogc
    {
        if (this is other)
        {
            return;
        }
        _memory = other._memory;
        _beg = other._beg;
        _end = other._end;
    }

    auto opIndex(size_t index)
    {
        if (index >= _end - _beg)
        {
            throw NbuffError;
        }
        return _memory._impl._object[_beg + index];
    }
    auto opIndex()
    {
        return save();
    }
    NbuffChunk opSlice(size_t start, size_t end) @safe @nogc
    {
        assert(start<=length && end<=length);
        auto res = save();
        res._beg += start;
        res._end = res._beg + end - start;
        return res;
    }
    auto opEquals(const(ubyte)[] b)
    {
        return b == _memory._object[_beg.._end];
    }
    auto opDollar()
    {
        return _end - _beg;
    }
    bool empty() pure @nogc @safe
    {
        return _beg == _end;
    }
    auto front() @safe @nogc
    {
        return _memory._impl._object[_beg];
    }
    auto back() @safe @nogc
    {
        return _memory._impl._object[_end - 1];
    }
    void popFront() @safe @nogc
    {
        assert(_beg < _end);
        _beg++;
    }
    void popFrontN(size_t n) @safe @nogc
    {
        debug(nbuff) safe_tracef("popn %d of %d", n, length);
        assert(n <= length);
        _beg += n;
    }
    void popBack() @safe @nogc
    {
        assert(_beg < _end);
        _end--;
    }
    void popBackN(size_t n) @safe @nogc
    {
        assert(n <= length);
        _end -= length;
    }
    NbuffChunk save() @safe @nogc
    {
        NbuffChunk c;
        c._beg = _beg;
        c._end = _end;
        c._memory = _memory;
        return c;
    }
}

// class NbuffError: Exception
// {
//     this(string msg, string file = __FILE__, size_t line = __LINE__) @nogc @safe
//     {
//         super(msg, file, line);
//     }
// }
alias MutableNbuffChunk = UniquePtr!MutableMemoryChunk;
/// Smart buffer.
/// Usage scenario:
/// You are reading bulk newline delimited lines (or any other way structured data) from TCP socket and process it as soon as possible.
/// Every time you received something like:
///
/// 'line1\nline2\nli' <- note incomplete last line.
///
/// from network to your socket buffer you can process 'line1' and 'line2' and then you have keep whole buffer (or copy 
/// and save it incomplete part 'li') just because you have some incomplete data.
///
/// This leads to unnecessary allocations and data movement (if you choose to free old buffer and save incomplete part)
/// or memory wasting (if you choose to preallocate very large buffer and keep processed and incomplete data).
///
/// Nbuff solve this problem by using memory pool and smart pointers - it take memory chunks from pool for reading
/// from network(file, etc...), and authomatically return buffer to pool as soon as you processed all data in it and moved
/// 'processed' pointer forward.
/// 
/// So Nbuff looks like some "window" on the list of buffers, filled with network data, and as soon as buffer moves out of this
/// window and dereferenced it will be automatically returned to memory pool. Please note - there is no GC allocations, everything
/// is done usin malloc.
///
/// Here is sample of buffer lifecycle (see code or docs for exact function signatures):
/// Nbuff nbuff; - initialize nbuff structure.
/// buffer = Nbuff.get(bsize) - gives you non-copyable mutable buffer of size >= bsize
/// socket.read(buffer.data) - fill buffer with network data.
/// nbuff.append(buffer) - convert mutable non-copyable buffer to immutable shareable buffer and append it to nbuff
/// valuable_data = nbuff.data(0, 100); - get immutable view to first 100 bytes of nbuff (they can be non-continous)
/// nbuff.pop(100) - release fist 100 bytes of nbuff, marking them as "processed".
///     If there are any previously appended buffers which become unreferenced at this point, then they will be
///     returned to the pool.
/// When nbuff goes out of scope all its buffers will be returned to pool.
///
struct Nbuff
{
    private
    {
        enum ChunksPerPage = 8;
        struct Page
        {
            NbuffChunk[ChunksPerPage]   _chunks;
            Page*                       _next;
        }
        size_t  _length;
        size_t  _endChunkIndex;
        size_t  _begChunkIndex;
        Page    _pages;
    }

    invariant
    {
        assert(_endChunkIndex == _begChunkIndex || _length > 0, "%d, %d, length = %s".format(_begChunkIndex, _endChunkIndex, _length));
    }

    ///
    /// copy references to RC-data
    ///
    this(this) @nogc @safe
    {
        // copy only allocated pages
        Page* new_pages, last_new_page;
        auto p = _pages._next;
        while(p)
        {
            auto new_page = () @trusted {return allocator.make!Page();}();
            new_page._chunks = p._chunks;
            if ( new_pages is null)
            {
                new_pages = new_page;
                last_new_page = new_pages;
            }
            else
            {
                last_new_page._next = new_page;
                last_new_page = new_page;
            }
            p = p._next;
        }
        _pages._next = new_pages;
    }

    this(string s) @nogc @safe
    {
        append(s);
    }
    this(immutable(ubyte)[] s) @nogc @safe
    {
        auto c = NbuffChunk(s);
        append(c);
    }
    ///
    /// copy references to RC-data
    ///
    void opAssign(T)(auto ref T other) @safe @nogc
    {
        if ( other is this )
        {
            return;
        }
        // release everything `this` holds
        auto p = _pages._next;
        while(p)
        {
            auto next = p._next;
            () @trusted {dispose(allocator, p);}();
            p = next;
        }
        // copy info from other to this
        _length = other._length;
        _begChunkIndex = other._begChunkIndex;
        _endChunkIndex = other._endChunkIndex;
        _pages._chunks = other._pages._chunks;
        _pages._next = null;
        if (  empty || ( _begChunkIndex < ChunksPerPage && _endChunkIndex < ChunksPerPage))
        {
            return;
        }
        // copy only allocated pages
        Page* new_pages, last_new_page;
        p = other._pages._next;
        while(p)
        {
            auto new_page = () @trusted {return allocator.make!Page();}();
            //assert(!new_page);
            new_page._chunks = p._chunks;
            if ( new_pages is null)
            {
                new_pages = new_page;
                last_new_page = new_pages;
            }
            else
            {
                last_new_page._next = new_page;
                last_new_page = new_page;
            }
            p = p._next;
        }
        _pages._next = new_pages;
    }

    ///
    /// dispose all allocated pages and dec refs for any data
    ///
    ~this() @safe @nogc
    {
        auto p = _pages._next;
        while(p)
        {
            auto next = p._next;
            () @trusted {dispose(allocator, p);}();
            p = next;
        }
    }

    void clear() @nogc @safe
    {
        _length = 0;
        _begChunkIndex = _endChunkIndex = 0;
        auto p = _pages._next;
        while(p)
        {
            auto next = p._next;
            () @trusted {dispose(allocator, p);}();
            p = next;
        }
        _pages = Page();
    }

    string toString() @safe
    {
        return this.data.toString();
    }
    string dump() @safe
    {
        string[] res;
        res ~= "▛%s▜".format(repeat("▀",72).join());
        res ~= "▌%-72.72s▐".format("_length   = %d".format(_length));
        res ~= "▌%-72.72s▐".format("_begIndex = %d".format(_begChunkIndex));
        res ~= "▌%-72.72s▐".format("_endIndex = %d".format(_endChunkIndex));
        auto p = chunkIndexToPage(_begChunkIndex);
        auto chunkIndex = _begChunkIndex % ChunksPerPage;
        auto i = _begChunkIndex;
        while(i<_endChunkIndex)
        {
            res ~= "▌%-72.72s▐".format("chunk %d ".format(i));
            res ~= p._chunks[chunkIndex].dump()[0..$-1];
            i++;
            chunkIndex++;
            if (chunkIndex>=ChunksPerPage)
            {
                p = p._next;
                res ~= "▌%-72.72s▐".format("Page %x".format(p));
                chunkIndex = 0;
            }
        }
        res ~= "▙%s▟".format(repeat("▄",72).join());
        return res.join("\n");
    }

    static auto get(size_t size) @safe @nogc
    {
        // take memory from pool
        return MutableNbuffChunk(size);
    }

    bool empty() pure inout nothrow @safe @nogc
    {
        return _endChunkIndex == _begChunkIndex;
    }

    auto length() pure nothrow @nogc @safe inout
    {
        return _length;
    }

    void append(string s) @safe @nogc
    {
        debug(nbuff) safe_tracef("append NbuffChunk");
        if (s.length==0)
        {
            throw NbuffError;
        }
        _length += s.length;
        if ( _endChunkIndex < ChunksPerPage)
        {
            _pages._chunks[_endChunkIndex++] = NbuffChunk(s);
            return;
        }

        Page* last_page = &_pages;
        auto pi = _endChunkIndex - ChunksPerPage;
        debug(nbuff) safe_tracef("pi: %d", pi);
        debug(nbuff) safe_tracef("last_page.next = %x", last_page._next);
        while(pi >= ChunksPerPage)
        {
            last_page = last_page._next;
            pi -= ChunksPerPage;
        }
        assert(0 <= pi && pi < ChunksPerPage );
        debug(nbuff) safe_tracef("last_page.next = %x, pi=%d", last_page._next, pi);
        if (last_page._next is null)
        {
            // have to create new page
            debug(nbuff) safe_tracef("create new page");
            last_page._next = allocator.make!Page();
        }
        last_page._next._chunks[pi] = NbuffChunk(s);
        _endChunkIndex++;
    }

    void append(ref UniquePtr!(MutableMemoryChunk) c, size_t l) @safe @nogc
    {
        debug(nbuff) safe_tracef("append NbuffChunk");
        if (l==0)
        {
            throw NbuffError;
        }
        _length += l;
        if ( _endChunkIndex < ChunksPerPage)
        {
            // just convert it to immutable chunk and store it
            _pages._chunks[_endChunkIndex++] = NbuffChunk(c,l);
            return;
        }
        // go to last page and store chunk there
        Page* last_page = &_pages;
        auto pi = _endChunkIndex - ChunksPerPage;
        debug(nbuff) safe_tracef("pi: %d", pi);
        debug(nbuff) safe_tracef("last_page.next = %x", last_page._next);
        while(pi >= ChunksPerPage)
        {
            last_page = last_page._next;
            pi -= ChunksPerPage;
        }
        assert(0 <= pi && pi < ChunksPerPage );
        debug(nbuff) safe_tracef("last_page.next = %x, pi=%d", last_page._next, pi);
        if (last_page._next is null)
        {
            // have to create new page
            debug(nbuff) safe_tracef("create new page");
            last_page._next = allocator.make!Page();
        }
        last_page._next._chunks[pi] = NbuffChunk(c,l);
        _endChunkIndex++;
    }

    void append(ref NbuffChunk source) @safe @nogc
    {
        append(source, 0, source.length);
    }
    /// append some part of other nbuff
    void append(ref NbuffChunk source, size_t pos, size_t len) @safe @nogc
    {
        if (len==0)
        {
            throw NbuffError;
        }
        _length += len;
        if ( _endChunkIndex < ChunksPerPage)
        {
            _pages._chunks[_endChunkIndex]._memory = source._memory;
            _pages._chunks[_endChunkIndex]._beg = source._beg + pos;
            _pages._chunks[_endChunkIndex]._end = source._beg + pos + len;
            _endChunkIndex++;
            return;
        }
        Page* last_page = &_pages;
        auto pi = _endChunkIndex - ChunksPerPage;
        debug(nbuff) safe_tracef("pi: %d", pi);
        debug(nbuff) safe_tracef("last_page.next = %x", last_page._next);
        while(pi >= ChunksPerPage)
        {
            last_page = last_page._next;
            pi -= ChunksPerPage;
        }
        assert(0 <= pi && pi < ChunksPerPage );
        debug(nbuff) safe_tracef("last_page.next = %x, pi=%d", last_page._next, pi);
        if (last_page._next is null)
        {
            // have to create new page
            debug(nbuff) safe_tracef("create new page");
            last_page._next = allocator.make!Page();
        }
        last_page._next._chunks[pi] = source;
        last_page._next._chunks[pi]._beg += pos;
        last_page._next._chunks[pi]._end = last_page._next._chunks[pi]._beg+len;
        _endChunkIndex++;
    }
    /// return first stored chunk
    auto frontChunk() @safe @nogc
    {
        if ( empty )
        {
            assert(0, "You are looking front chunk in empty Nbuff");
        }
        Page *p = chunkIndexToPage(_begChunkIndex);
        int   i = _begChunkIndex % ChunksPerPage;
        return p._chunks[i];
    }
    /// throw away first chunk
    void popChunk() @safe @nogc
    {
        if ( empty )
        {
            assert(0, "You are trying to pop chunk from empty Nbuff");
        }
        if ( _begChunkIndex < ChunksPerPage)
        {
            _length -= _pages._chunks[_begChunkIndex].length;
            _pages._chunks[_begChunkIndex++] = NbuffChunk();
            return;
        }

        Page* last_page = &_pages;
        debug(nbuff) safe_tracef("popping chunk %d", _begChunkIndex);
        auto pi = _begChunkIndex - ChunksPerPage;
        while(pi >= ChunksPerPage)
        {
            last_page = last_page._next;
            pi -= ChunksPerPage;
        }
        debug(nbuff) safe_tracef("popping chunk  - on page index = %d", pi);
        assert(0 <= pi && pi < ChunksPerPage );
        _length -= _pages._chunks[pi].length;
        last_page._next._chunks[pi] = NbuffChunk();
        _begChunkIndex++;
        if (empty)
        {
            debug(nbuff) safe_tracef("nbuff become empty");
            // _endChunkIndex = _begChunkIndex = 0;
            clear();
            return;
        }
        if (pi == ChunksPerPage - 1)
        {
            // we popped last chunk on page - it is completely free
            auto pageToDispose = last_page._next;
            debug(nbuff) safe_tracef("last chunk were popped from this page and nbuff is not empty, lp: %x, ptd: %x", last_page, pageToDispose);
            last_page._next = pageToDispose._next;
            () @trusted {dispose(allocator, pageToDispose);}();
            // adjust indexes
            _begChunkIndex -= ChunksPerPage;
            _endChunkIndex -= ChunksPerPage;
        }
    }
    /// pop n bytes from nbuff
    void pop(long n=1) @safe @nogc
    {
        assert(n <= _length);
        if (n == _length)
        {
            clear();
            return;
        }
        auto  toPop = n;
        while(toPop > 0)
        {
            if ( empty )
            {
                assert(0, "You are trying to pop chunk from empty Nbuff");
            }

            auto page = chunkIndexToPage(_begChunkIndex);
            auto index = _begChunkIndex % ChunksPerPage;
            page._chunks[index]._beg++;
            _length--;
            toPop--;
            assert(_length >= 0);
            if (page._chunks[index]._beg == page._chunks[index]._end)
            {
                // empty
                debug(nbuff) tracef("dispose chunk %d", index);
                page._chunks[index] = NbuffChunk();
                if ( index == ChunksPerPage - 1 && _begChunkIndex>=ChunksPerPage) // last chunk on page is free
                {
                    // release page
                    debug(nbuff) tracef("dispose page");
                    auto page_prev = chunkIndexToPage(_begChunkIndex - ChunksPerPage);
                    page_prev._next = page._next;
                    () @trusted {dispose(allocator, page);}();
                    _begChunkIndex++;
                    _begChunkIndex -= ChunksPerPage;
                    _endChunkIndex -= ChunksPerPage;
                }
                else
                {
                    _begChunkIndex++;
                    debug(nbuff) tracef("new _begChunkIndex %d", _begChunkIndex);
                }
            }
        }
    }

    private auto chunkIndexToPage(ulong index) pure inout @safe @nogc
    {
        auto skipPages = index / ChunksPerPage;
        auto p = &_pages;
        while(skipPages>0)
        {
            p = p._next;
            skipPages--;
        }
        return p;
    }
    ///
    /// return immutable continuous view to [beg, end] of this nbuff.
    /// Data copy:
    ///  We can avoid data copy if [beg, end] lies within single stored immutable chunk. Then we just return ref to this chunk
    ///  We can't avoid data copy if [beg, end] span several chunks. Then we have to join them.
    /// 
    NbuffChunk data(size_t beg, size_t end) @safe
    {
        if (beg>end)
        {
            throw NbuffError;
        }
        if (end>_length)
        {
            throw NbuffError;
        }
        if (beg == end || _length == 0)
        {
            return NbuffChunk();
        }
        auto bytesToSkip = beg;
        auto bytesToCopy = end-beg;
        auto page = chunkIndexToPage(_begChunkIndex);
        auto chunkIndex = _begChunkIndex % ChunksPerPage;
        size_t position;
        debug(nbuff) safe_tracef("bytesToSkip: %d", bytesToSkip);
        while(bytesToSkip>0)
        {
            auto chunk = &page._chunks[chunkIndex];
            debug(nbuff) safe_tracef("check chunk: [%s..%s](%d)",
                chunk._beg, chunk._end, chunk.length);

            if (bytesToSkip>=chunk.length)
            {
                // just skip this chunk
                debug(nbuff) safe_tracef("skip it");
                bytesToSkip -= chunk.length;
                chunkIndex++;
                if (chunkIndex == ChunksPerPage)
                {
                    page = page._next;
                    chunkIndex = 0;
                    continue;
                }
            }
            else
            {
                debug(nbuff) safe_tracef("start from it");
                position = bytesToSkip;
                bytesToSkip = 0;
                break;
            }
        }
        debug(nbuff) safe_tracef("start index = %d, position = %d", chunkIndex, position);
        assert(page !is null);
        assert(chunkIndex < ChunksPerPage);
        if ( page._chunks[chunkIndex]._beg + position + bytesToCopy <= page._chunks[chunkIndex]._end )
        {
            debug(nbuff) safe_tracef("return ref to single chunk");
            // return reference to this chunk only
            NbuffChunk res = page._chunks[chunkIndex];
            res._beg += position;
            res._end = res._beg + bytesToCopy;
            return res;
        }
        
        // otherwise join chunks
        auto mc = Nbuff.get(bytesToCopy);
        size_t bytesCopied = 0;
        while(bytesToCopy>0)
        {
            auto from = page._chunks[chunkIndex]._beg + position;
            auto to = page._chunks[chunkIndex]._end;
            auto tc = min(bytesToCopy, to - from);
            debug(nbuff) safe_tracef("from: %d, to: %d, tocopy=%d", from, to, tc);
            mc._impl._object[bytesCopied..bytesCopied+tc] = page._chunks[chunkIndex]._memory._object[from..from+tc];
            bytesCopied += tc;
            chunkIndex++;
            bytesToCopy -= tc;
            position = 0;
            if (chunkIndex>=ChunksPerPage)
            {
                chunkIndex -= ChunksPerPage;
                page = page._next;
            }
        }
        return NbuffChunk(mc, bytesCopied);
    }
    ///
    /// return immutable continuous view to this whole nbuff.
    /// Data copy:
    ///  We can avoid data copy if this nbuff store single immutable chunk. Then we just return ref to this chunk
    ///  We can't avoid data copy if nbuff span several chunks. Then we have to join them.
    /// 
    NbuffChunk data() @safe @nogc
    {
        if (_length==0)
        {
            return NbuffChunk();
        }
        // ubyte[] result = new ubyte[](_length);
        auto skipPages = _begChunkIndex / ChunksPerPage;
        int  bi = cast(int)_begChunkIndex, ei = cast(int)_endChunkIndex;
        Page* p = &_pages;
        auto toCopyChunks = ei - bi;
        int toCopyBytes = cast(int)_length;
        int bytesCopied = 0;
        while(skipPages>0)
        {
            bi -= ChunksPerPage;
            ei -= ChunksPerPage;
            p = p._next;
            skipPages--;
        }
        if(ei == bi + 1)
        {
            // there is only chunk in buffer, we can return it
            return p._chunks[bi];
        }
        assert(bi>=0 && ei>0);
        auto mc = Nbuff.get(_length);
        while(toCopyChunks>0 && toCopyBytes>0)
        {
            auto from = p._chunks[bi]._beg;
            auto to = p._chunks[bi]._end;
            auto tc = to - from;
            mc._impl._object[bytesCopied..bytesCopied+tc] = p._chunks[bi]._memory._object[from..to];
            bytesCopied += tc;
            bi++;
            toCopyBytes -= tc;
            toCopyChunks--;
            if (bi>=ChunksPerPage)
            {
                bi -= ChunksPerPage;
                ei -= ChunksPerPage;
                p = p._next;
            }
        }
        return NbuffChunk(mc, _length);
    }
    ///
    /// return non-contiguous vie to slice of this nbuff.
    /// Data copy: none
    ///
    Nbuff opSlice(size_t start, size_t end) @nogc @safe
    {
        //debug(nbuff) tracef("slice %d..%d", start, end);
        if (start>end)
        {
            throw NbuffError;
        }
        if (end>_length)
        {
            throw NbuffError;
        }
        if (start==end)
        {
            return Nbuff();
        }
        auto bytesToSkip = start;
        auto bytesToCopy = end-start;
        auto page = chunkIndexToPage(_begChunkIndex);
        auto chunkIndex = _begChunkIndex % ChunksPerPage;
        size_t position;// = page._chunks[chunkIndex]._beg;
        // debug(nbuff) tracef("start index = %d", chunkIndex);
        // debug(nbuff) tracef("bytesToSkip = %d", bytesToSkip);
        // debug(nbuff) tracef("bytesToCopy = %d", bytesToCopy);
        while(bytesToSkip>0)
        {
            auto chunk = &page._chunks[chunkIndex];
            //debug(nbuff) tracef("check chunk: [%s..%s](%d)",
            //    chunk._beg, chunk._end, chunk.length);

            if (bytesToSkip>=chunk.length)
            {
                // just skip this chunk
                bytesToSkip -= chunk.length;
                chunkIndex++;
                if (chunkIndex == ChunksPerPage)
                {
                    page = page._next;
                    chunkIndex = 0;
                    continue;
                }
            }
            else
            {
                position = bytesToSkip;
                bytesToSkip = 0;
                break;
            }
        }
        assert(page !is null);
        assert(chunkIndex < ChunksPerPage);
        Nbuff result = Nbuff();
        /// copy references
        while(bytesToCopy>0)
        {
            auto l = min(bytesToCopy, page._chunks[chunkIndex]._end - position - page._chunks[chunkIndex]._beg);
            result.append(page._chunks[chunkIndex], position, l);
            bytesToCopy -= l;
            position = 0;
            chunkIndex++;
            if (chunkIndex == ChunksPerPage)
            {
                page = page._next;
                chunkIndex = 0;
            }
        }
        return result;
    }

    auto opDollar()
    {
        return _length;
    }
    bool opEquals(string other) pure const @safe @nogc
    {
        return this == other.representation;
    }
    bool opEquals(const ubyte[] other) pure const @safe @nogc
    {
        if (other.length != length)
        {
            return false;
        }
        return countUntil(other) == 0;
    }
    bool opEquals(this R)(auto ref R other) pure @safe @nogc
    {
        if (this is other)
        {
            return true;
        }
        if (_length != other._length)
        {
            return false;
        }
        // real comparison
        bool equals = true;
        size_t to_compare = _length;
        Page* page_this = chunkIndexToPage(_begChunkIndex);
        Page* page_other = other.chunkIndexToPage(other._begChunkIndex);
        size_t chunk_index_this = _begChunkIndex;
        size_t chunk_index_other = other._begChunkIndex;
        size_t position_this = 0;
        size_t position_other = 0;
        while(equals && to_compare>0)
        {
            auto i_this  = chunk_index_this % ChunksPerPage;
            auto i_other = chunk_index_other % ChunksPerPage;
            auto chunk_t = &page_this._chunks[i_this];
            auto chunk_o = &page_other._chunks[i_other];
            assert(position_this < chunk_t._end);
            assert(position_other < chunk_o._end);
            auto l_t = chunk_t._end - chunk_t._beg - position_this;
            auto l_o = chunk_o._end - chunk_o._beg - position_other;
            auto l_c = min(l_t, l_o, to_compare);
            debug(nbuff) safe_tracef("compare %s and %s",
                chunk_t._memory._data[chunk_t._beg + position_this..chunk_t._beg + position_this+l_c],
                chunk_o._memory._data[chunk_o._beg + position_other..chunk_o._beg + position_other+l_c]);
            equals = equal(chunk_t._memory._data[chunk_t._beg + position_this..chunk_t._beg + position_this+l_c],
                           chunk_o._memory._data[chunk_o._beg + position_other..chunk_o._beg + position_other+l_c]);
            position_this += l_c;
            position_other += l_c;
            if (l_c == l_t)
            {
                position_this = 0;
                chunk_index_this++;
                i_this++;
                if (i_this == ChunksPerPage)
                {
                    page_this = page_this._next;
                }
            }
            if (l_c == l_o)
            {
                position_other = 0;
                chunk_index_other++;
                i_other++;
                if (i_other == ChunksPerPage)
                {
                    page_other = page_other._next;
                }
            }
            debug(nbuff) safe_tracef("compared %d bytes: %s", l_c, equals);
            to_compare -= l_c;
        }
        return equals;
    }

    auto opIndex(size_t i) @safe @nogc inout
    {
        if ( i >= _length)
        {
            throw NbuffError;
        }
        auto page = chunkIndexToPage(_begChunkIndex);
        long chunkIndex = _begChunkIndex;
        while(i >= 0)
        {
            auto ci = chunkIndex % ChunksPerPage;
            auto chunk = &page._chunks[ci];
            if (chunk.length > i)
            {
                return chunk._memory._impl._object[chunk._beg + i];
            }
            i -= chunk.length;
            chunkIndex++;
            if (ci+1 == ChunksPerPage)
            {
                page = page._next;
            }
        }
        assert(0, "Index larger that length?");
    }
    Nbuff[3] findSplitOn(string s, size_t start_from = 0) @safe @nogc
    {
        return findSplitOn(s.representation, start_from);
    }
    Nbuff[3] findSplitOn(immutable(ubyte)[] b, size_t start_from = 0) @safe @nogc
    {
        Nbuff[3] result;
        int s = countUntil(b, start_from);
        if (s>=0)
        {
            result[0] = this[0..s];
            result[1] = this[s..s+b.length];
            result[2] = this[s+b.length..$];
        }
        return result;
    }
    bool beginsWith(const ubyte[] b) @safe @nogc
    {
        if ( length < b.length )
        {
            return false;
        }
        return data()[0..b.length] == b;
    }
    bool beginsWith(string b) @safe @nogc
    {
        if ( length < b.length )
        {
            return false;
        }
        return data()[0..b.length] == b.representation;
    }

    int countUntil(const(ubyte)[] b, size_t start_from = 0) pure inout @safe @nogc
    {
        if (b.length == 0)
        {
            throw NbuffError;
        }
        if (_length == 0)
        {
            return -1;
        }
        if (start_from >= _length)
        {
            throw NbuffError;
        }
        if (start_from == -1 || _length == 0)
        {
            return -1;
        }
        int index = 0; // index is position at which we test pattern 
        // skip start_from
        auto page = chunkIndexToPage(_begChunkIndex);
        long chunkIndex = _begChunkIndex;
        auto ci = chunkIndex % ChunksPerPage; // ci - index of the chunk on current page
        auto chunk = &page._chunks[ci];
        while(start_from > 0) // skip requested number of bytes
        {
            if (chunk.length > start_from)
            {
                break;
            }
            index += chunk.length;
            start_from -= chunk.length;
            chunkIndex++;
            ci++;
            if (ci == ChunksPerPage)
            {
                page = page._next;
                ci = 0;
            }
            chunk = &page._chunks[ci];
        }
        // start_from can be > 0 if index points inside chunk
        index += start_from;
        auto position_this = start_from; // position_this - offset in Nbuff chunk we looking at
        auto position_needle = 0;        // position_needlse - offset inside pattern

        debug(nbuff) safe_tracef("Start search from chunk index: %s, position: %s", chunkIndex, position_this);
        immutable needle_length = b.length;
        while(index + needle_length <= _length)
        {
            size_t to_compare = needle_length;
            debug(nbuff) safe_tracef("test from this[%s]=%02x, compare len=%d", index, this[index], to_compare);
            // all 'local' variables used as we might overlap chunk
            auto local_chunkIndex = chunkIndex;
            auto local_position_this = position_this;
            auto local_position_needle = position_needle;
            auto local_ci = ci;
            auto local_chunk = chunk;
            auto local_page = page;
            while(to_compare>0)
            {
                auto c_l = min(to_compare, local_chunk.length-local_position_this); // we can comapre only until the end of the chunk
                immutable equals = equal(
                    local_chunk._memory._data[local_chunk._beg+local_position_this..local_chunk._beg+local_position_this+c_l],
                    b[local_position_needle..local_position_needle+c_l]
                );
                if (!equals)
                {
                    break;
                }
                local_position_this += c_l;
                local_position_needle += c_l;
                to_compare -= c_l;
                if ( to_compare == 0)
                {
                    break;
                }
                if (local_position_this==chunk.length)
                {
                    debug(nbuff) safe_tracef("continue on next chunk");
                    local_position_this = 0;
                    local_chunkIndex++;
                    if (local_chunkIndex == _endChunkIndex)
                    {
                        break;
                    }
                    local_ci++;
                    if (local_ci==ChunksPerPage)
                    {
                        debug(nbuff) safe_tracef("continue on next page");
                        local_ci = 0;
                        local_page = local_page._next;
                    }
                    local_chunk = &local_page._chunks[local_ci];
                }
                
            }
            if (to_compare == 0)
            {
                debug(nbuff) safe_tracef("return %d", index);
                return index;
            }
            index++;
            debug(nbuff) safe_tracef("start from next position %d", index);
            position_this++;
            position_needle = 0;
            if ( position_this == chunk.length)
            {
                // switch to next chunk
                debug(nbuff) safe_tracef("next chunk");
                position_this = 0;
                chunkIndex++;
                if (chunkIndex == _endChunkIndex)
                {
                    return -1;
                }
                ci++;
                if (ci == ChunksPerPage)
                {
                    debug(nbuff) safe_tracef("and next page");
                    page = page._next;
                    ci = 0;
                }
                chunk = &page._chunks[ci];
            }
        }
        return -1;
    }
    version(Posix)
    {
        import core.sys.posix.sys.uio: iovec;
        /// build iovec from this nbuff
        /// Paramenter v - ref to array of iovec structs
        /// n - size of array (must be >0)
        /// Return number of actually filled entries;
        int toIoVec(iovec* v, int n) @system
        {
            assert(n>0);
            if (empty)
            {
                return 0;
            }
            int vi = 0;
            auto skipPages = _begChunkIndex / ChunksPerPage;
            int  bi = cast(int)_begChunkIndex, ei = cast(int)_endChunkIndex;
            Page* p = &_pages;
            while(skipPages > 0)
            {
                bi -= ChunksPerPage;
                ei -= ChunksPerPage;
                p = p._next;
                skipPages--;
            }

            // fill no more than n and no more than we have chunks
            int i = bi, j = 0;
            for(; j < n && i<ei; j++)
            {
                auto beg = p._chunks[i]._beg;
                void* base = cast(void*)p._chunks[i]._memory._impl._object.ptr + beg;
                v[j].iov_base = base;
                v[j].iov_len  = p._chunks[i].length;
                i++;
                if (i == ChunksPerPage)
                {
                    i -= ChunksPerPage;
                    ei -= ChunksPerPage;
                    p = p._next;
                }
            }
            return j;
        }
    }
}


@("NbuffChunk")
@safe
unittest
{
    import std.range.primitives;
    static assert(isInputRange!NbuffChunk);
    static assert(isForwardRange!NbuffChunk);
    static assert(isBidirectionalRange!NbuffChunk);
    static assert(hasLength!NbuffChunk);
    static assert(is(typeof(lvalueOf!NbuffChunk[1]) == ElementType!NbuffChunk));
    static assert(isRandomAccessRange!NbuffChunk);
    auto c = NbuffChunk("abcd");
    assert(equal(c, "abcd"));
    assert(c == "abcd".representation);
    assert(equal(c[1..3], "bc"));
    assert(c[1..3][0] == 'b');
    assert(c[1..3][$-1] == 'c');
}

@("Nbuff0")
@nogc
unittest
{
    import std.string;
    import std.stdio;
    Nbuff b;
    auto d = b;
    auto chunk = Nbuff.get(512);
    copy("Abc".representation, chunk.data);
    b.append(chunk, 3);
    chunk = Nbuff.get(16);
    copy("Def".representation, chunk.data);
    b.append(chunk, 3);
    d = b;
}

@("Nbuff1")
@nogc
unittest
{
    import std.string;
    {
        Nbuff b;
        auto chunk = Nbuff.get(11);
        copy("Abc".representation, chunk.data);
        b.append(chunk, 3);
    }
    {
        Nbuff b;
        auto chunk = Nbuff.get(11);
        copy("Abc".representation, chunk.data);
        b.append(chunk, 3);
    }
    Nbuff b;
    auto d = b;
    auto chunk = Nbuff.get(512);
    copy("Def".representation, chunk.data);
    b.append(chunk, 3);
    b.popChunk();
}

@("Nbuff2")
unittest
{
    Nbuff b;
    for(int i=1; i <= 2*Nbuff.ChunksPerPage + 1; i++)
    {
        auto chunk = Nbuff.get(64);
        b.append(chunk, i);
    }
    for(int i=0;i<2*Nbuff.ChunksPerPage; i++)
    {
        b.popChunk();
    }
    b.popChunk();
    Nbuff c;
    c = b;
}

@("Nbuff3")
unittest
{
    Nbuff b;
    auto chunk = Nbuff.get(16);
    copy("Hello".representation, chunk.data);
    b.append(chunk, 5);
    chunk = Nbuff.get(16);
    copy(",".representation, chunk.data);
    b.append(chunk, 1);
    chunk = Nbuff.get(16);
    copy(" world!".representation, chunk.data);
    b.append(chunk, 7);
    auto d = b.data();
    assert(equal(d, "Hello, world!".representation));
    assert(d[0] == 'H');
    assert(d[$-1] == '!');
}

@("Nbuff4")
unittest
{
    Nbuff b;
    for(int i=0; i<32; i++)
    {
        string s = "%s,".format(i);
        auto chunk = Nbuff.get(16);
        copy(s.representation, chunk.data);
        b.append(chunk, s.length);
    }
    assert(equal(b.data, "0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,"));
}

@("Nbuff5")
unittest
{
    Nbuff b;
    for(int i=0; i<32; i++)
    {
        string s = "%s,".format(i);
        auto chunk = Nbuff.get(16);
        copy(s.representation, chunk.data);
        b.append(chunk, s.length);
    }
    assert(b.length == 86);
    b.pop();
    assert(equal(b.data, ",1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,"));
    b.pop();
    assert(equal(b.data, "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,"));
    b.pop(2);
    assert(equal(b.data, "2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,"));
    b.pop(34);
    assert(equal(b.data, "16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,"));
    b.pop(48);
    assert(b.length == 0, "b.length=%d".format(b.length));
}

@("Nbuff6")
unittest
{
    Nbuff b, d;
    for(int i=0; i<32; i++)
    {
        string s = "%s,".format(i);
        auto chunk = Nbuff.get(16);
        copy(s.representation, chunk.data);
        b.append(chunk, s.length);
    }
    b.pop();
    assert(equal(b.data, ",1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,"));
    {
        auto c = b[2..8]; // ",2,3,4"
        assert(equal(",2,3,4", c.data));
        d = c;
    }
    b.clear();
    for(int i=0; i<99; i++)
    {
        string s = "%02d,".format(i);
        auto chunk = Nbuff.get(16);
        copy(s.representation, chunk.data);
        b.append(chunk, s.length);
    }
    auto c = b[45..96];
    assert(equal(c.data, "15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,"));
}
@("Nbuff7")
unittest
{
    globalLogLevel = LogLevel.info;
    Nbuff b;
    for(int i=0; i<32; i++)
    {
        string s = "%s,".format(i);
        auto chunk = Nbuff.get(16);
        copy(s.representation, chunk.data);
        b.append(chunk, s.length);
    }
    auto c = b[0..$];
    assert(b==c);
    auto d = b[0..10];
    auto e = b[1..11];
    assert(d != e);
    Nbuff f, g;
    f.append("abc");
    g.append("bc");
    assert(f[1..$] == g);
    f.pop();
    assert(f == g);
    f.popChunk();
    assert(f.length == 0);
    // mix string and chunk appends
    f.append("Length: ");
    auto chunk = Nbuff.get(16);
    copy("100\n".representation, chunk.data);
    f.append(chunk, 4);
    g.clear();
    g.append("L");
    g.append("ength: 100\n");
    globalLogLevel = LogLevel.trace;
    assert(f == g);
    //
    assert(f[0] == 'L');
    assert(g[1] == 'e');
    assert(g[11] == '\n');
}
@("Nbuff8")
unittest
{
    Nbuff b;
    b.append("012");
    b.append("345");
    b.append("678");
    assert(b.countUntil("01".representation, 0)==0);
    assert(b.countUntil("12".representation, 0)==1);
    assert(b.countUntil("23".representation, 0)==2);
    assert(b.countUntil("23".representation, 2)==2);
    assert(b.countUntil("345".representation, 2)==3);
    assert(b.countUntil("345".representation, 3)==3);
    assert(b.countUntil("23456".representation,0) == 2);
    b.clear();
    for(int i=0;i<100;i++)
    {
        b.append("%d".format(i));
    }
    assert(b.countUntil("10".representation) == 10);
    assert(b.countUntil("90919".representation) == 170);
    assert(b.countUntil("99".representation, 170) == 188);
    for(int skip=0; skip<=170; skip++)
    {
        assert(b.countUntil("90919".representation, skip) == 170);
    }
}
@("Nbuff9")
unittest
{
    globalLogLevel = LogLevel.info;
    Nbuff b, line;
    b.append("\na\nbb\n");
    auto c = b.countUntil("\n".representation);
    b = b[c+1..$];
    assert(b.data == "a\nbb\n".representation);
    c = b.countUntil("\n".representation);
    line = b[0..c];
    assert(line.data == "a".representation);

    b = b[c+1..$];
    assert(b.data == "bb\n".representation);
    c = b.countUntil("\n".representation);
    b = b[c+1..$];
    b.append("ccc\nrest");
    c = b.countUntil("\n".representation);
    b = b[c+1..$];
    c = b.countUntil("\n".representation);
}

@("Nbuff10")
unittest
{
    auto c = UniquePtr!MutableMemoryChunk(64);
    c.data[0] = 1;
    auto n = NbuffChunk("abc");
}

@("Nbuff11")
unittest
{
    globalLogLevel = LogLevel.info;
    // init from string
    auto b = Nbuff("abc");
    assert(b.length == 3);
    assert(b.data.data == NbuffChunk("abc"));
    b.pop();
    NbuffChunk c = b.data(0,1);
    assert(c.data == "b");
    c = b.data(1,2);
    assert(c.data == "c");
    b = Nbuff("abc");
    b.append("def");
    b.append("ghi");
    c = b.data(4,6);
    assert(c.data == "ef");
    c = b.data(2,4);
    assert(c.data == "cd");
    c = b.data(2,7);
    assert(c.data == "cdefg");
}

version(Posix)
{
    @("iovec")
    unittest
    {
        import core.sys.posix.sys.uio: iovec;
        Nbuff b;
        iovec[64] iov64;
        // fill nbuff
        for(int k=0;k<32;k++)
        {
            b.append("%s\n".format(k));
        }
        // pop 15 chunks (so we will cross page boundary)
        iota(15).each!(_ => b.popChunk());
        auto i = b.toIoVec(&iov64[0], 64);
        assert(i == 17);
        for(int k=0;k<i;k++)
        {
            int j = k + 15;
            assert("%s\n".format(j) == cast(string)iov64[k].iov_base[0..iov64[k].iov_len]);
            //writef("%s:%s", j, cast(string)iov64[k].iov_base[0..iov64[k].iov_len]);
        }

    }
}