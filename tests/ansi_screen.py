#!/usr/bin/env python3
"""Replay captured terminal output and print the resulting screen.

Used by tests/test_wizard.sh to assert that the TUI redraws its menu in place:
the raw byte stream contains one copy of the prompt per redraw, so only a
cursor-aware replay can tell "redrawn in place" from "scrolled down".

Supported escapes: CSI n A/B/C/D, CSI K, CSI m (ignored), CR, LF, BS.
"""
import re
import sys

CSI = re.compile(r"\x1b\[([0-9;]*)([A-Za-z])")


class Screen:
    def __init__(self):
        self.rows = [""]
        self.row = 0
        self.col = 0
        self.saved = None

    def _ensure(self, row):
        while len(self.rows) <= row:
            self.rows.append("")

    def _put(self, ch):
        self._ensure(self.row)
        line = self.rows[self.row].ljust(self.col + len(ch))
        self.rows[self.row] = line[: self.col] + ch + line[self.col + len(ch):]
        self.col += len(ch)

    def feed(self, text):
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\x1b":
                m = CSI.match(text, i)
                if m:
                    arg, cmd = m.group(1), m.group(2)
                    n = int(arg) if arg.isdigit() else 1
                    if cmd == "A":
                        self.row = max(0, self.row - n)
                    elif cmd == "B":
                        self.row += n
                        self._ensure(self.row)
                    elif cmd == "C":
                        self.col += n
                    elif cmd == "D":
                        self.col = max(0, self.col - n)
                    elif cmd == "K":
                        self._ensure(self.row)
                        self.rows[self.row] = self.rows[self.row][: self.col]
                    elif cmd == "J":
                        # erase from the cursor to the end of the screen
                        self._ensure(self.row)
                        self.rows[self.row] = self.rows[self.row][: self.col]
                        del self.rows[self.row + 1:]
                    elif cmd == "s":
                        self.saved = (self.row, self.col)
                    elif cmd == "u":
                        if self.saved is not None:
                            self.row, self.col = self.saved
                    # 'm' (colors) and anything else is ignored
                    i = m.end()
                    continue
                i += 1
                continue
            if ch == "\r":
                self.col = 0
            elif ch == "\n":
                # the pty runs with ONLCR, so a newline also returns the cursor
                self.col = 0
                self.row += 1
                self._ensure(self.row)
            elif ch == "\b":
                self.col = max(0, self.col - 1)
            else:
                self._put(ch)
            i += 1


def main():
    # pty output can interleave writes and split a multibyte character
    data = sys.stdin.buffer.read().decode("utf-8", "replace")
    screen = Screen()
    screen.feed(data)
    lines = [line.rstrip() for line in screen.rows]
    if "--count" in sys.argv:
        needle = sys.argv[sys.argv.index("--count") + 1]
        print(sum(1 for line in lines if needle in line))
        return
    print("\n".join(lines))


if __name__ == "__main__":
    main()
