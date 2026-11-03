"""Find the existing local demo dependencies; does not install packages."""
from pathlib import Path
import sys

WORKSPACE = Path(__file__).resolve().parents[2]
for candidate in (WORKSPACE / "mobile_v1/.deps312", WORKSPACE / "mobile_v1/.deps"):
    if candidate.is_dir():
        sys.path.insert(0, str(candidate))
        break
