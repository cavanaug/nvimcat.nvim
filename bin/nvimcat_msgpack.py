"""Minimal msgpack encode/decode for Neovim RPC (stdlib only)."""
from __future__ import annotations

import struct
from typing import Any


class NeedMoreData(Exception):
    pass


def pack(obj: Any) -> bytes:
    if obj is None:
        return b"\xc0"
    if obj is False:
        return b"\xc2"
    if obj is True:
        return b"\xc3"
    if isinstance(obj, int):
        if 0 <= obj <= 127:
            return bytes([obj])
        if -32 <= obj < 0:
            return bytes([obj & 0xFF])
        if 0 <= obj <= 0xFF:
            return b"\xcc" + bytes([obj])
        if 0 <= obj <= 0xFFFF:
            return b"\xcd" + struct.pack(">H", obj)
        if 0 <= obj <= 0xFFFFFFFF:
            return b"\xce" + struct.pack(">I", obj)
        if -128 <= obj <= 127:
            return b"\xd0" + struct.pack("b", obj)
        if -32768 <= obj <= 32767:
            return b"\xd1" + struct.pack(">h", obj)
        if -2147483648 <= obj <= 2147483647:
            return b"\xd2" + struct.pack(">i", obj)
        return b"\xd3" + struct.pack(">q", obj)
    if isinstance(obj, float):
        return b"\xcb" + struct.pack(">d", obj)
    if isinstance(obj, (bytes, bytearray, memoryview)):
        b = bytes(obj)
        ln = len(b)
        if ln <= 0xFF:
            return b"\xc4" + bytes([ln]) + b
        if ln <= 0xFFFF:
            return b"\xc5" + struct.pack(">H", ln) + b
        return b"\xc6" + struct.pack(">I", ln) + b
    if isinstance(obj, str):
        b = obj.encode("utf-8")
        ln = len(b)
        if ln <= 31:
            return bytes([0xA0 + ln]) + b
        if ln <= 0xFF:
            return b"\xd9" + bytes([ln]) + b
        if ln <= 0xFFFF:
            return b"\xda" + struct.pack(">H", ln) + b
        return b"\xdb" + struct.pack(">I", ln) + b
    if isinstance(obj, (list, tuple)):
        n = len(obj)
        if n <= 15:
            out = bytes([0x90 + n])
        elif n <= 0xFFFF:
            out = b"\xdc" + struct.pack(">H", n)
        else:
            out = b"\xdd" + struct.pack(">I", n)
        return out + b"".join(pack(x) for x in obj)
    if isinstance(obj, dict):
        n = len(obj)
        if n <= 15:
            out = bytes([0x80 + n])
        elif n <= 0xFFFF:
            out = b"\xde" + struct.pack(">H", n)
        else:
            out = b"\xdf" + struct.pack(">I", n)
        for k, v in obj.items():
            out += pack(k) + pack(v)
        return out
    if isinstance(obj, Ext):
        return _pack_ext(obj.code, obj.data)
    raise TypeError(f"cannot pack {type(obj)!r}")


class Ext:
    """Opaque msgpack extension (Neovim Buffer/Window/etc.)."""

    __slots__ = ("code", "data")

    def __init__(self, code: int, data: bytes) -> None:
        self.code = code
        self.data = data


def _pack_ext(code: int, data: bytes) -> bytes:
    ln = len(data)
    if ln == 1:
        return b"\xd4" + struct.pack("b", code) + data
    if ln == 2:
        return b"\xd5" + struct.pack("b", code) + data
    if ln == 4:
        return b"\xd6" + struct.pack("b", code) + data
    if ln == 8:
        return b"\xd7" + struct.pack("b", code) + data
    if ln == 16:
        return b"\xd8" + struct.pack("b", code) + data
    if ln <= 0xFF:
        return b"\xc7" + bytes([ln]) + struct.pack("b", code) + data
    if ln <= 0xFFFF:
        return b"\xc8" + struct.pack(">H", ln) + struct.pack("b", code) + data
    return b"\xc9" + struct.pack(">I", ln) + struct.pack("b", code) + data


class Unpacker:
    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes) -> None:
        self._buf.extend(data)

    def unpack(self) -> Any:
        if not self._buf:
            raise NeedMoreData
        val, n = _unpack_one(memoryview(self._buf), 0)
        del self._buf[:n]
        return val


def _unpack_one(buf: memoryview, pos: int) -> tuple[Any, int]:
    if pos >= len(buf):
        raise NeedMoreData
    b0 = buf[pos]
    if b0 <= 0x7F:  # positive fixint
        return b0, pos + 1
    if 0xE0 <= b0 <= 0xFF:  # negative fixint
        return struct.unpack("b", bytes([b0]))[0], pos + 1
    if b0 == 0xC0:
        return None, pos + 1
    if b0 == 0xC2:
        return False, pos + 1
    if b0 == 0xC3:
        return True, pos + 1
    if 0xA0 <= b0 <= 0xBF:  # fixstr
        ln = b0 - 0xA0
        end = pos + 1 + ln
        if end > len(buf):
            raise NeedMoreData
        return bytes(buf[pos + 1 : end]).decode("utf-8"), end
    if 0x90 <= b0 <= 0x9F:  # fixarray
        n = b0 - 0x90
        return _unpack_array(buf, pos + 1, n)
    if 0x80 <= b0 <= 0x8F:  # fixmap
        n = b0 - 0x80
        return _unpack_map(buf, pos + 1, n)
    if b0 == 0xCC:
        if pos + 2 > len(buf):
            raise NeedMoreData
        return buf[pos + 1], pos + 2
    if b0 == 0xCD:
        if pos + 3 > len(buf):
            raise NeedMoreData
        return struct.unpack(">H", buf[pos + 1 : pos + 3])[0], pos + 3
    if b0 == 0xCE:
        if pos + 5 > len(buf):
            raise NeedMoreData
        return struct.unpack(">I", buf[pos + 1 : pos + 5])[0], pos + 5
    if b0 == 0xCF:
        if pos + 9 > len(buf):
            raise NeedMoreData
        return struct.unpack(">Q", buf[pos + 1 : pos + 9])[0], pos + 9
    if b0 == 0xD0:
        if pos + 2 > len(buf):
            raise NeedMoreData
        return struct.unpack("b", buf[pos + 1 : pos + 2])[0], pos + 2
    if b0 == 0xD1:
        if pos + 3 > len(buf):
            raise NeedMoreData
        return struct.unpack(">h", buf[pos + 1 : pos + 3])[0], pos + 3
    if b0 == 0xD2:
        if pos + 5 > len(buf):
            raise NeedMoreData
        return struct.unpack(">i", buf[pos + 1 : pos + 5])[0], pos + 5
    if b0 == 0xD3:
        if pos + 9 > len(buf):
            raise NeedMoreData
        return struct.unpack(">q", buf[pos + 1 : pos + 9])[0], pos + 9
    if b0 == 0xCA:
        if pos + 5 > len(buf):
            raise NeedMoreData
        return struct.unpack(">f", buf[pos + 1 : pos + 5])[0], pos + 5
    if b0 == 0xCB:
        if pos + 9 > len(buf):
            raise NeedMoreData
        return struct.unpack(">d", buf[pos + 1 : pos + 9])[0], pos + 9
    if b0 == 0xD9:
        if pos + 2 > len(buf):
            raise NeedMoreData
        ln = buf[pos + 1]
        end = pos + 2 + ln
        if end > len(buf):
            raise NeedMoreData
        return bytes(buf[pos + 2 : end]).decode("utf-8"), end
    if b0 == 0xDA:
        if pos + 3 > len(buf):
            raise NeedMoreData
        ln = struct.unpack(">H", buf[pos + 1 : pos + 3])[0]
        end = pos + 3 + ln
        if end > len(buf):
            raise NeedMoreData
        return bytes(buf[pos + 3 : end]).decode("utf-8"), end
    if b0 == 0xDB:
        if pos + 5 > len(buf):
            raise NeedMoreData
        ln = struct.unpack(">I", buf[pos + 1 : pos + 5])[0]
        end = pos + 5 + ln
        if end > len(buf):
            raise NeedMoreData
        return bytes(buf[pos + 5 : end]).decode("utf-8"), end
    if b0 == 0xC4:
        if pos + 2 > len(buf):
            raise NeedMoreData
        ln = buf[pos + 1]
        end = pos + 2 + ln
        if end > len(buf):
            raise NeedMoreData
        return bytes(buf[pos + 2 : end]), end
    if b0 == 0xC5:
        if pos + 3 > len(buf):
            raise NeedMoreData
        ln = struct.unpack(">H", buf[pos + 1 : pos + 3])[0]
        end = pos + 3 + ln
        if end > len(buf):
            raise NeedMoreData
        return bytes(buf[pos + 3 : end]), end
    if b0 == 0xC6:
        if pos + 5 > len(buf):
            raise NeedMoreData
        ln = struct.unpack(">I", buf[pos + 1 : pos + 5])[0]
        end = pos + 5 + ln
        if end > len(buf):
            raise NeedMoreData
        return bytes(buf[pos + 5 : end]), end
    if b0 == 0xDC:
        if pos + 3 > len(buf):
            raise NeedMoreData
        n = struct.unpack(">H", buf[pos + 1 : pos + 3])[0]
        return _unpack_array(buf, pos + 3, n)
    if b0 == 0xDD:
        if pos + 5 > len(buf):
            raise NeedMoreData
        n = struct.unpack(">I", buf[pos + 1 : pos + 5])[0]
        return _unpack_array(buf, pos + 5, n)
    if b0 == 0xDE:
        if pos + 3 > len(buf):
            raise NeedMoreData
        n = struct.unpack(">H", buf[pos + 1 : pos + 3])[0]
        return _unpack_map(buf, pos + 3, n)
    if b0 == 0xDF:
        if pos + 5 > len(buf):
            raise NeedMoreData
        n = struct.unpack(">I", buf[pos + 1 : pos + 5])[0]
        return _unpack_map(buf, pos + 5, n)
    if b0 in (0xD4, 0xD5, 0xD6, 0xD7, 0xD8):
        sizes = {0xD4: 1, 0xD5: 2, 0xD6: 4, 0xD7: 8, 0xD8: 16}
        ln = sizes[b0]
        end = pos + 2 + ln
        if end > len(buf):
            raise NeedMoreData
        code = struct.unpack("b", buf[pos + 1 : pos + 2])[0]
        return Ext(code, bytes(buf[pos + 2 : end])), end
    if b0 == 0xC7:
        if pos + 3 > len(buf):
            raise NeedMoreData
        ln = buf[pos + 1]
        end = pos + 3 + ln
        if end > len(buf):
            raise NeedMoreData
        code = struct.unpack("b", buf[pos + 2 : pos + 3])[0]
        return Ext(code, bytes(buf[pos + 3 : end])), end
    if b0 == 0xC8:
        if pos + 4 > len(buf):
            raise NeedMoreData
        ln = struct.unpack(">H", buf[pos + 1 : pos + 3])[0]
        end = pos + 4 + ln
        if end > len(buf):
            raise NeedMoreData
        code = struct.unpack("b", buf[pos + 3 : pos + 4])[0]
        return Ext(code, bytes(buf[pos + 4 : end])), end
    if b0 == 0xC9:
        if pos + 6 > len(buf):
            raise NeedMoreData
        ln = struct.unpack(">I", buf[pos + 1 : pos + 5])[0]
        end = pos + 6 + ln
        if end > len(buf):
            raise NeedMoreData
        code = struct.unpack("b", buf[pos + 5 : pos + 6])[0]
        return Ext(code, bytes(buf[pos + 6 : end])), end
    raise ValueError(f"unknown msgpack byte 0x{b0:02x} at {pos}")


def _unpack_array(buf: memoryview, pos: int, n: int) -> tuple[list[Any], int]:
    out: list[Any] = []
    for _ in range(n):
        val, pos = _unpack_one(buf, pos)
        out.append(val)
    return out, pos


def _unpack_map(buf: memoryview, pos: int, n: int) -> tuple[dict[Any, Any], int]:
    out: dict[Any, Any] = {}
    for _ in range(n):
        key, pos = _unpack_one(buf, pos)
        val, pos = _unpack_one(buf, pos)
        out[key] = val
    return out, pos


if __name__ == "__main__":
    samples = [
        None,
        True,
        False,
        42,
        -1,
        1.5,
        "hi",
        b"\x00\xff",
        [1, "a"],
        {"k": [True, None]},
    ]
    u = Unpacker()
    for obj in samples:
        u.feed(pack(obj))
        assert u.unpack() == obj
    for ln in (1, 2, 4, 8, 16, 32):
        ext = Ext(-1, bytes(ln))
        u.feed(pack(ext))
        got = u.unpack()
        assert isinstance(got, Ext) and got.code == ext.code and got.data == ext.data
    print("OK msgpack")
