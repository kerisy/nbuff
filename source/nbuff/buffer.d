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

/// Network buffer (collected from network data chunks)
struct Buffer { // @suppress(dscanner.suspicious.incomplete_operator_overloading)

  package:
//    alias Chunk = BufferChunk;
    size_t              _length;
    BufferChunksArray   _chunks;
    size_t              _pos;       // offset from beginning, always points inside first chunk
    long                _end_pos;   // offset of the _length in the last chunk

  public:
    /// build from string
    this(string s) pure @safe nothrow {
        _chunks = [s.representation];
        _length = s.length;
        _end_pos = _length;
    }

    /// build from chunk
    this(BufferChunk s) pure @safe nothrow {
        _chunks = [s];
        _length = s.length;
        _end_pos = _length;
    }
    /// build from other buffer slice
    this(in Buffer other, size_t m, size_t n) pure @safe {
        // produce slice view m..n
        if ( n == m ) {
            return;
        }

        enforce(m < n && n <=other._length, "wrong m or n");
        assert(other._pos < other._chunks[0].length);

        m += other._pos;
        n += other._pos;

        _length = n - m;
        n = n - m;

        if ( other._chunks.length == 1 ) {
            // special frequent usecase
            // no loops
            _chunks = [other._chunks[0][m .. m+n]];
            _end_pos = n;
            return;
        }

        ulong i;
        while( m > other._chunks[i].length ) {
            m -= other._chunks[i].length;
            i++;
        }

        BufferChunksArray content;

        auto to_copy = min(n, other._chunks[i].length - m);
        if ( to_copy > 0 ) {
            content ~= other._chunks[i][m..m+to_copy];
        }
        i++;
        n -= to_copy;
        while(n > 0) {
            to_copy = min(n, other._chunks[i].length);
            if ( n > to_copy ) {
                content ~= other._chunks[i];
            }
            else {
                content ~= other._chunks[i][0..to_copy];
            }
            n -= to_copy;
            i++;
        }
        _end_pos = to_copy;
        _chunks = content;
    }
    /// construct from other buffer slice
    this(in Buffer other, size_t m, size_t n) pure @safe immutable {
        // produce slice view m..n
        if ( n == m ) {
            return;
        }

        BufferChunksArray  content;

        enforce(m < n && n <=other.length, "wrong m or n");
        assert(other._pos < other._chunks[0].length);
        m += other._pos;
        n += other._pos;

        _length = n - m;
        n = n - m;

        ulong i;
        while( m > other._chunks[i].length ) {
            m -= other._chunks[i].length;
            i++;
        }
        auto to_copy = min(n, other._chunks[i].length - m);
        if ( to_copy > 0 ) {
            content ~= other._chunks[i][m..m+to_copy];
            //_end_pos = to_copy;
        }
        i++;
        n -= to_copy;
        while(n > 0) {
            to_copy = min(n, other._chunks[i].length);
            if ( n > to_copy ) {
                content ~= other._chunks[i];
            }
            else {
                content ~= other._chunks[i][0..to_copy];
            }
            n -= to_copy;
            i++;
        }
        _end_pos = to_copy;
        _chunks = content;
    }

    /// if Buffer is empty?
    bool empty() const pure @safe @nogc nothrow {
        return _length == 0;
    }

    alias put = append;
    /// append data chunk to buffer
    auto append(in string s) pure @safe nothrow {
        if (s.length == 0 ) {
            return;
        }
        BufferChunk chunk = s.representation;
        if ( _chunks.length > 0 && _end_pos < _chunks[$-1].length ) {
            // we have to copy chunks with last chunk trimmed
            _chunks = _chunks[0..$-1] ~ _chunks[$-1][0.._end_pos];
        }
        _chunks ~= chunk;
        _length += chunk.length;
        _end_pos = s.length;
    }
    /// append chunk
    auto append(in BufferChunk s) pure @safe nothrow {
        if (s.length == 0 ) {
            return;
        }
        if ( _chunks.length > 0 && _end_pos < _chunks[$-1].length ) {
            // we have to copy chunks with last chunk trimmed
            _chunks = _chunks[0..$-1] ~ _chunks[$-1][0.._end_pos];
        }
        _chunks ~= s;
        _length += s.length;
        _end_pos = s.length;
    }

    /// length in bytes
    @property size_t length() const pure @safe @nogc nothrow {
        return _length;
    }

    /// opDollar - $
    @property auto opDollar() const pure @safe @nogc nothrow {
        return _length;
    }

    /// build slice over buffer
    Buffer opSlice(size_t m, size_t n) const pure @safe {
        if ( this._length==0 || m == n ) {
            return Buffer();
        }
        return Buffer(this, m, n);
    }
    /// opIndex
    @property ubyte opIndex(size_t n) const pure @safe @nogc nothrow {
        if ( n >= _length ) {
            return _chunks[$][0];
        }
        n += _pos;
        if ( _chunks.length == 1 ) {
            return _chunks[0][n];
        }
        foreach(ref b; _chunks) {
            immutable l = b.length;
            if ( n < l ) {
                return b[n];
            }
            n -= l;
        }
        // XXX
        // this is a way to have @nogc, while throwing RangeError
        // in case of wrong n value (n>=_length)
        return _chunks[$][0];
    }

    auto opEquals(T)(in T other) const pure @safe @nogc nothrow if (isSomeString!T) {
        if (other.length != _length ) {
            return false;
        }
        size_t m;
        immutable last_chunk = _chunks.length;
        if (_chunks.length == 1) {
            // single chunk
            return _chunks[0][_pos.._end_pos] == other;
        }
        foreach(i, ref c; _chunks) {
            size_t a, b;
            if ( i == 0 ) {
                a = _pos;
            }
            if ( i == last_chunk ) {
                b = _end_pos;
            } else {
                b = c.length;
            }
            auto cmp_len = b - a;
            if ( c[a..b] != other[m..m+cmp_len] ) {
                return false;
            }
            m += cmp_len;
        }
        return true;
    }

    /// save (for range ops)
    @property auto save() pure @safe @nogc nothrow {
        return this;
    }

    alias front = frontByte;
    alias popFront = popFrontByte;
    /// return front byte
    @property ubyte frontByte() const pure @safe @nogc nothrow {
        assert(_pos < _chunks[0].length);
        return _chunks[0][_pos];
    }

    /// pop front byte
    @property void popFrontByte() pure @safe @nogc {
        assert(_pos < _chunks[0].length);
        if ( _length == 0 ) {
            throw RangeEmpty;
        }
        _pos++;
        _length--;
        if ( _pos >= _chunks[0].length ) {
            _pos = 0;
            _chunks = _chunks[1..$];
        }
    }

    /// return front data chunk
    BufferChunk frontChunk() const pure @safe @nogc nothrow {
        return _chunks[0][_pos..$];
    }

    /// pop first chunk
    void popFrontChunk() pure @nogc @safe {
        assert(_pos < _chunks[0].length);
        if ( _length == 0 ) {
            throw RangeEmpty;
        }
        _length -= _chunks[0].length - _pos;
        _pos = 0;
        _chunks = _chunks[1..$];
    }

    alias back = backByte;
    /// value of last byte
    @property ubyte backByte() const pure @nogc @safe nothrow {
        return _chunks[$-1][_end_pos - 1];
    }
    /// pop last byte
    @property void popBack() pure @safe @nogc {
        if ( _length == 0 ) {
            throw RangeEmpty;
        }
        if ( _end_pos > _chunks[$-1].length) {
            throw BufferError;
        }
        _length--;
        _end_pos--;
        if ( _end_pos == 0 && _length > 0) {
            _chunks.popBack;
            _end_pos = _chunks[$-1].length;
        }
    }

    ///
    /// Return array of buffer chunks, all chunks length adjusted
    //
    BufferChunksArray dataChunks() const pure @safe nothrow {
        BufferChunksArray res;
        if ( _length == 0 ) {
            return res;
        }
        immutable last_chunk = _chunks.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
        foreach(i,ref c; _chunks) {
            long a,b = c.length;
            if ( i == 0 ) {
                a = _pos;
            }
            if ( i == last_chunk ) {
                b = _end_pos;
            }
            res ~= c[a..b];
        }
        return res;
    }
    /// collect data chunks in contigouos buffer
    BufferChunk data() const pure @trusted {
        if ( _length == 0 ) {
            return BufferChunk.init;
        }
        if ( _chunks.length == 1 ) {
            return _chunks[0][_pos.._end_pos];
        }
        assert(_pos < _chunks[0].length);
        ubyte[] r = new ubyte[this.length];
        uint d = 0;
        size_t p = _pos;
        foreach(ref c; _chunks[0..$-1]) {
            r[d..d+c.length-p] = c[p..$];
            d += c.length-p;
            p = 0;
        }
        auto c = _chunks[$-1];
        r[d..$] = c[p.._end_pos];
        return assumeUnique(r);
    }
    /// split buffer on single-byte separator
    Buffer[] splitOn(ubyte sep) const pure @safe {
        Buffer[] res;
        Buffer a = this;
        Buffer b = this.find(sep);
        while( b.length ) {
            auto al = a.length;
            auto bl = b.length;
            res ~= a[0..al-bl];
            b.popFront;
            a = b;
            b = b.find(sep);
        }
        res ~= a;
        return res;
    }
    /// index of s
    ptrdiff_t indexOf(string s) const pure @safe {
        if ( s.length == 0 || s.length > _length ) {
            return -1;
        }

        Buffer haystack = this;
        ubyte b = s.representation[0];
        while( haystack.length > 0 ) {
            auto r = haystack.find(b);
            if ( r.length < s.length ) {
                return -1;
            }
            if ( s.length == 1 || r[1..s.length] == s[1..$]) {
                return _length - r.length;
            }
            haystack = r;
            haystack.popFront;
        }
        return -1;
    }
    /// canFind string?
    bool canFindString(string s) const pure @safe {
        return indexOf(s) >= 0;
    }
    private bool cmp(size_t pos, const(ubyte)[] other) const @safe {
        if ( pos + other.length > _length ) {
            return false;
        }
        if (_chunks.length == 1) {
            // single chunk
            return _chunks[0][pos .. pos + other.length] == other;
        }
        int i;
        while (pos >= _chunks[i].length) {
            pos -= _chunks[i].length;
            i++;
        }
        size_t compare_pos, compare_len = other.length;
        size_t a = pos;
        foreach (ref c; _chunks[i..$]) {
            size_t to_compare = min(compare_len, c.length - a);
            if (c[a..a+to_compare] != other[compare_pos .. compare_pos+to_compare]) {
                return false;
            }
            a = 0;
            compare_len -= to_compare;
            compare_pos += to_compare;
            if ( compare_len == 0 ) {
                return true;
            }
        }
        return true;
    }

    /// starting from pos count until buffer 'b'
    long countUntil(size_t pos, const(ubyte)[] b) const @safe {
        if (b.length == 0) {
            throw RangeEmpty;
        }
        if (pos == -1) {
            return -1;
        }
        if (_chunks.length == 0)
            return -1;

        immutable needleLen = b.length;

        while ( pos < _length - needleLen + 1 ) {
            if ( cmp(pos, b) ) {
                return pos;
            }
            pos++;
        }
        return -1;
    }
    /// find on char using predicate
    Buffer find(alias pred="a==b")(char needle) const pure @safe {
        return find!pred(cast(ubyte)needle);
    }
    /// find on ubyte using predicate
    Buffer find(alias pred="a==b")(ubyte needle) const pure @safe {
        immutable chunk_last = _chunks.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
        long chunk_pos = 0;
        foreach (i,ref c; _chunks) {
            long a,b;
            if (i == 0) {
                a = _pos;
            }
            if (i == chunk_last) {
                b = _end_pos;
            } else {
                b = c.length;
            }
            immutable f = c[a..b].find!pred(needle);

            if ( f.length > 0) {
                auto p = b - f.length;
                return this[chunk_pos-_pos+p..$];
            }
            else {
                chunk_pos += c.length;
            }
        }
        return Buffer();
    }
    /// find and split buffer
    Buffer[] findSplitOn(immutable(ubyte)[] b) const @safe {
        immutable i = countUntil(0, b);
        if ( i == -1 ) {
            return new Buffer[](3);
        }
        Buffer[] f;
        f ~= this[0..i];
        f ~= Buffer(b);
        f ~= this[i+b.length..this.length];
        return f;
    }
    // _Range range() const pure @safe @nogc nothrow {
    //     return _Range(this);
    // }
    string toString() const @safe {
        return cast(string)data();
    }
    /// cast to string
    string opCast(string)() const {
        return toString();
    }
    /// print some buffer internal info
    void describe() const @safe {
        writefln("leng: %d", _length);
        writefln("_pos: %d", _pos);
        writefln("_end: %d", _end_pos);
        writefln("chunks: %d", _chunks.length);
        foreach(ref c; _chunks) {
            writefln("%d bytes: %s", c.length, cast(string)c[0..min(10, c.length)]);
        }
    }
}

unittest {
    info("Test buffer");
    static assert(isInputRange!Buffer);
    static assert(isForwardRange!Buffer);
    static assert(hasLength!Buffer);
    static assert(hasSlicing!Buffer);
    static assert(isBidirectionalRange!Buffer);
    static assert(isRandomAccessRange!Buffer);
    auto b = Buffer();
    b.append("abc");
    b.append("def".representation);
    b.append("123");
    assert(equal(b.data(), "abcdef123"));
    assert(b == "abcdef123");

    auto bi = immutable Buffer("abc");
    assert(equal(bi.data(), "abc"));
    Buffer c = b;
    assert(cast(string)c.data() == "abcdef123");
    assert(c.length == 9);
    assert(c._chunks.length == 3);
    // update B do not affect C
    b.append("ghi");
    assert(cast(string)c.data() == "abcdef123");
    // test slices
    immutable Buffer di  = b[1..5];
    //immutable Buffer dii = di[1..2];
    // +di+
    // |bc|
    // |de|
    // +--+
    assert(cast(string)di.data == "bcde");

    b = Buffer("a\nb");
    assert(b.findSplitOn("\n".representation) == ["a", "\n", "b"]);
    b = Buffer();
    b.append("a");
    b.append("\n");
    b.append("b");
    assert(b.findSplitOn("\n".representation) == ["a", "\n", "b"]);
    b = Buffer();
    b.append("abc");
    b.append("def");
    b.append("ghi");
    assert(b.findSplitOn("cdefg".representation) == ["ab","cdefg", "hi"]);
    b = Buffer("012");
    b.append("345");
    b.popFrontByte();
    assert(equal(b.data, "12345"));
    assert(equal(b[1..$-1].data, "234"));
    b.popFrontByte();
    assert(equal(b.data, "2345"));
    b.popFrontByte();
    assert(equal(b.data, "345"));
    b.popFrontByte();
    assert(equal(b.data, "45"));
    b = Buffer("012");
    b.append("345");
    auto bb = b;
    b.popFrontByte();
    assert(b[0]=='1');
    assert(b[$-1]=='5');
    assert(b.back == '5');
    assertThrown!RangeError(b[$]=='5');
    assert(equal(b[1..$-1], "234"));
    b.popFrontChunk();
    assert(equal(b.data, "345"));
    assert(b[0]=='3');
    assert(b[$-1]=='5');
    assert(equal(b[1..$-1], "4"));
    assert(equal(bb, "012345"));
    b.popFrontChunk();
    assertThrown!RangeError(b.popFrontChunk());
    bb = Buffer();
    bb.append("0123");
    bb.append("45".representation);
    bb.popFront();
    bb.popBack();
    assert(bb.front == '1');
    assert(bb[0] == '1');
    assert(bb.back == '4');
    assert(bb[$-1] == '4');
    assert(bb.data == "1234");
    assert(bb.length == 4);
    assertThrown!RangeError(bb[5]==0);
    bb.popFront();
    bb.popBack();
    assert(bb.front == '2');
    assert(bb.back == '3');
    assert(bb.data == "23");
    assert(bb.length == 2);
    bb.popFront();
    bb.popBack();
    assert(bb.length == 0);

    bb = Buffer();
    bb.append("0123");
    bb.append("45");
    bb.popBack();
    bb.append("abc");
    assert(bb.back == 'c');
    assert(bb.length == 8);
    assert(bb == "01234abc");
    bb = Buffer();
    bb.append("0123");
    bb.append("4");
    bb.popBack();
    bb.append("abc");
    assert(bb.back == 'c');
    assert(bb.length == 7);
    assert(bb == "0123abc");
    bb = Buffer();
    bb.append("0123");
    bb.append("");
    bb.popBack();
    bb.append("abc");
    assert(bb.back == 'c');
    assert(bb.length == 6);
    assert(bb == "012abc");

    bb = Buffer();
    bb.append("0123".representation);
    bb.popFront();
    bb.popBack();
    assert(bb.front == '1');
    assert(bb.back == '2');
    assert(bb.length == 2);
    assert(equal(bb, "12"));
    assert(!bb.canFind('0'));
    assert(equal(bb.find('0'), ""));    // internal, fast
    assert(!bb.canFind('0'));
    assert(equal(bb.find('0'), ""));    // internal, fast
    assert(bb.canFind('1'));
    assert(equal(bb.find('1'), "12"));    // internal, fast
    assert(!bb.canFind('3'));
    assert(equal(find(bb, '3'), ""));   // use InputRange, slow

    bb.append("3");
    assert(bb.back == '3');
    assert(bb.length == 3);
    assert(equal(bb, "123"));
    assert(bb[0..$] == "123");
    assert(bb[$-1] == '3');
    assert(equal(bb.find('0'), ""));    // internal, fast
    assert(!bb.canFind('0'));
    assert(equal(bb.find('1'), "123"));    // internal, fast
    assert(bb.canFind('3'));
    assert(equal(bb.find('3'), "3"));  // internal method, fast
    assert(equal(find(bb, '3'), "3")); // use InputRange, slow

    bb = Buffer();
    bb.append("0");
    bb.append("1");
    bb.append("2");
    bb.append("3");
    assert(equal(bb.retro, "3210"));

    bb.popFront();
    bb.popBack();
    assert(bb.front == '1');
    assert(bb.back == '2');
    assert(bb.length == 2);
    assert(equal(bb, "12"));
    assert(!bb.canFind('0'));
    assert(equal(bb.find('0'), ""));    // internal, fast
    assert(!bb.canFind('0'));
    assert(equal(bb.find('0'), ""));    // internal, fast
    assert(bb.canFind('1'));
    assert(equal(bb.find('1'), "12"));    // internal, fast
    assert(!bb.canFind('3'));
    assert(equal(find(bb, '3'), ""));   // use InputRange, slow

    bb.append("3");
    assert(bb.back == '3');
    assert(bb.length == 3);
    assert(equal(bb, "123"));
    assert(bb[0..$] == "123");
    assert(bb[$-1] == '3');
    assert(equal(bb.find('0'), ""));    // internal, fast
    assert(!bb.canFind('0'));
    assert(equal(bb.find('1'), "123"));    // internal, fast
    assert(bb.canFind('3'));
    assert(equal(bb.find('3'), "3"));  // internal method, fast
    assert(equal(find(bb, '3'), "3")); // use InputRange, slow

    bb = Buffer();
    bb.append("aaa\n");
    bb.append("bbb\n");
    bb.append("ccc\n");
    assert(equal(splitter(bb, '\n').array[0], "aaa"));
    bb = Buffer();
    bb.append("0\naaa\n");
    bb.append("bbb\n");
    bb.popFront;
    bb.popFront;
    assert(equal(splitter(bb, '\n').array[0], "aaa"));

    bb = Buffer();
    bb.append("0\naaa\n");
    bb.append("bbb\n\n");
    bb.append("ccc\n1");
    bb.popFrontN(2);
    bb.popBackN(2);
    assert(bb.indexOf("aaa") ==  0);
    assert(bb.indexOf("bbb") ==  4);
    assert(bb.indexOf("0")   == -1);
    assert(bb.indexOf("1")   == -1);
    assert(equal(bb.splitOn('\n'), ["aaa", "bbb", "", "ccc"]));
    bb = Buffer();
    bb.append("0\naaa\nbbb\n\nccc\n1");
    bb.popFrontN(2);
    bb.popBackN(2);
    assert(equal(bb.splitOn('\n'), ["aaa", "bbb", "", "ccc"]));

    bb = Buffer();
    bb.append("aaa\nbbb\n\nccc\n");
    assert(bb.canFindString("\n\n"));
    assert(!bb.canFindString("\na\n"));
    bb = Buffer();
    bb.append("aaa\nbbb\n");
    bb.append("\nccc\n");
    assert(bb.canFindString("\n\n"));
    assert(!bb.canFindString("\na\n"));
    bb = Buffer();
    bb.append("aaa\r\nbbb\r\n\r\nddd");
    assert(bb.indexOf("\r\n\r\n") == 8);
    assert(!bb.canFindString("\na\n"));

}

@safe unittest {
    Buffer httpMessage = Buffer();
    httpMessage.append("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r");
    httpMessage.append("\n");
    httpMessage.append("Conte");
    httpMessage.append("nt-Length: 4\r\n");
    httpMessage.append("\r\n");
    httpMessage.append("body");

    writeln(httpMessage.splitOn('\n').map!"a.toString.strip");
}