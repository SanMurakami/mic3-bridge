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

clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    "$repo_dir/tests/identity-test.cpp" -o "$repo_dir/.build/identity-test"
"$repo_dir/.build/identity-test"
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -fsanitize=address,undefined \
    -framework Foundation -framework AudioToolbox \
    "$repo_dir/tests/recorder-test.mm" -o "$repo_dir/.build/recorder-test"
"$repo_dir/.build/recorder-test"
clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    "$repo_dir/tests/telemetry-test.cpp" -o "$repo_dir/.build/telemetry-test"
"$repo_dir/.build/telemetry-test"
clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    "$repo_dir/tests/waveform-test.cpp" -o "$repo_dir/.build/waveform-test"
"$repo_dir/.build/waveform-test"
swiftc -O -warnings-as-errors "$repo_dir/app/TimelineData.swift" "$repo_dir/app/MeterState.swift" "$repo_dir/app/Snapshot.swift" "$repo_dir/tests/timeline-test.swift" -o "$repo_dir/.build/timeline-test"
"$repo_dir/.build/timeline-test"
clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    "$repo_dir/tests/control-queue-test.cpp" -o "$repo_dir/.build/control-queue-test"
"$repo_dir/.build/control-queue-test"
