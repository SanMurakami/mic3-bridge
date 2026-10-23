#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$repo_dir/.build"
clang -std=c11 -Wall -Wextra -Werror -fblocks -fsanitize=address,undefined \
    -framework CoreAudio -framework CoreFoundation \
    "$repo_dir/tests/driver-test.c" -o "$repo_dir/.build/driver-test"
"$repo_dir/.build/driver-test"
clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    "$repo_dir/tests/resolver-test.cpp" -o "$repo_dir/.build/resolver-test"
"$repo_dir/.build/resolver-test"
