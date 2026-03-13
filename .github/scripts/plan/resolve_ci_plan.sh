#!/usr/bin/env bash
# Thin wrapper: delegates to the Python ci_plan package.

set -euo pipefail

python3 -c "import sys; assert sys.version_info >= (3,12), f'Python 3.12+ required, got {sys.version}'"
python3 -m ci_plan
