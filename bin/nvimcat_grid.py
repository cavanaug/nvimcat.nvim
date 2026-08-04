"""Line-grid buffer + truecolor ANSI renderer for Neovim embed UI events."""
from __future__ import annotations

from typing import Any

Cell = tuple[str, int]


class Grid:
    """Accumulates UI grid_line / hl_attr_define state; emits ANSI on flush."""

    def __init__(self) -> None:
        self._hl: dict[int, dict[str, Any]] = {}
        self._width: dict[int, int] = {}
        self._height: dict[int, int] = {}
        self._rows: dict[int, list[list[tuple[str, int]]]] = {}

    def resize(self, height: int, width: int, grid: int = 1) -> None:
        """Resize grid (rows, cols). Same as grid_resize."""
        self.apply_grid_resize(grid, width, height)

    def apply_grid_resize(self, grid: int, width: int, height: int) -> None:
        self._width[grid] = width
        self._height[grid] = height
        rows = self._rows.setdefault(grid, [])
        while len(rows) < height:
            rows.append([(" ", 0)] * width)
        del rows[height:]
        for r in range(height):
            row = rows[r]
            if len(row) < width:
                row.extend([(" ", 0)] * (width - len(row)))
            elif len(row) > width:
                del row[width:]
            rows[r] = row

    def apply_hl_attr_define(
        self,
        hl_id: int,
        rgb_attrs: dict[str, Any],
        _cterm_attrs: dict[str, Any],
        _info: dict[str, Any],
    ) -> None:
        attrs: dict[str, Any] = {}
        if "foreground" in rgb_attrs:
            attrs["fg"] = int(rgb_attrs["foreground"])
        if "background" in rgb_attrs:
            attrs["bg"] = int(rgb_attrs["background"])
        for key in ("bold", "italic", "underline", "reverse"):
            if rgb_attrs.get(key):
                attrs[key] = True
        self._hl[hl_id] = attrs

    def apply_grid_line(
        self,
        grid: int,
        row: int,
        col_start: int,
        cells: list[list[Any]],
        _wrap: bool,
    ) -> None:
        if grid not in self._width:
            return
        width = self._width[grid]
        rows = self._rows.setdefault(grid, [])
        while len(rows) <= row:
            rows.append([(" ", 0)] * width)
        line = list(rows[row])
        if len(line) < width:
            line.extend([(" ", 0)] * (width - len(line)))
        col = col_start
        last_hl_id = 0
        for cell in cells:
            text = str(cell[0])
            if len(cell) > 1:
                last_hl_id = int(cell[1])
            hl_id = last_hl_id
            repeat = int(cell[2]) if len(cell) > 2 else 1
            for _ in range(repeat):
                if not text:
                    if col >= width:
                        break
                    line[col] = ("", hl_id)
                    col += 1
                    continue
                for ch in text:
                    if col >= width:
                        break
                    line[col] = (ch, hl_id)
                    col += 1
        rows[row] = line

    def apply_grid_clear(self, grid: int) -> None:
        if grid not in self._width:
            return
        w, h = self._width[grid], self._height.get(grid, 0)
        self._rows[grid] = [[(" ", 0)] * w for _ in range(h)]

    def apply_grid_destroy(self, grid: int) -> None:
        self._rows.pop(grid, None)
        self._width.pop(grid, None)
        self._height.pop(grid, None)

    def _sgr(self, hl_id: int, *, reset: bool = False) -> bytes:
        attrs = self._hl.get(hl_id, {})
        parts: list[str] = []
        if reset:
            parts.append("0")
        if attrs.get("bold"):
            parts.append("1")
        if attrs.get("italic"):
            parts.append("3")
        if attrs.get("underline"):
            parts.append("4")
        if attrs.get("reverse"):
            parts.append("7")
        if "fg" in attrs:
            c = attrs["fg"]
            parts.append(f"38;2;{(c >> 16) & 0xFF};{(c >> 8) & 0xFF};{c & 0xFF}")
        if "bg" in attrs:
            c = attrs["bg"]
            parts.append(f"48;2;{(c >> 16) & 0xFF};{(c >> 8) & 0xFF};{c & 0xFF}")
        if not parts or (reset and len(parts) == 1):
            return b"\x1b[0m"
        return f"\x1b[{';'.join(parts)}m".encode()

    def _row_to_ansi(self, row: list[tuple[str, int]]) -> bytes:
        trimmed = list(row)
        while trimmed and trimmed[-1][0] == " " and trimmed[-1][1] == 0:
            trimmed.pop()
        out = bytearray()
        cur_hl: int | None = None
        buf = bytearray()
        for ch, hl_id in trimmed:
            if hl_id != cur_hl:
                if buf:
                    out.extend(buf)
                    buf.clear()
                if hl_id == 0:
                    out.extend(b"\x1b[0m")
                else:
                    out.extend(self._sgr(hl_id, reset=cur_hl is not None))
                cur_hl = hl_id
            buf.extend(ch.encode("utf-8"))
        if buf:
            out.extend(buf)
        if out and cur_hl != 0:
            out.extend(b"\x1b[0m")
        return bytes(out)

    def to_ansi(self, grid: int = 1) -> bytes:
        rows = self._rows.get(grid, [])
        lines = [self._row_to_ansi(row) for row in rows]
        while lines and lines[-1] in (b"", b"\x1b[0m"):
            lines.pop()
        return b"\n".join(lines) + (b"\n" if lines else b"")


if __name__ == "__main__":
    g = Grid()
    g.resize(1, 5)
    g.apply_hl_attr_define(1, {"foreground": 0xFF0000, "bold": True}, {}, {})
    g.apply_grid_line(1, 0, 0, [["Hi", 1], ["!", 1]], False)
    out = g.to_ansi()
    assert b"Hi" in out and b"255;0;0" in out
    print("OK grid")
