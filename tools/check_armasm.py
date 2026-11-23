"""Compare godot ArmAsm output with capstone (independent decoder).

  python tools/check_armasm.py <dir>   # dir = output of godot/tests/test_armasm.gd (armasm.bin, armasm_expect.txt)
"""
import sys
from pathlib import Path

import capstone

BASE = 0x02200000


def main() -> int:
    d = Path(sys.argv[1])
    code = (d / "armasm.bin").read_bytes()
    exp = (d / "armasm_expect.txt").read_text().splitlines()
    md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)
    fails = 0
    for i, want in enumerate(exp):
        w = code[4 * i:4 * i + 4]
        ins = list(md.disasm(w, BASE + 4 * i))
        got = f"{ins[0].mnemonic} {ins[0].op_str}".strip() if ins else "(invalid)"
        ok = got == want.strip()
        fails += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {BASE + 4 * i:08x} {w.hex()}  {got:32s} {'' if ok else 'want ' + want}")
    print(f"{fails} failure(s) / {len(exp)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
