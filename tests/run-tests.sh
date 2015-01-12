#!/usr/bin/env bash
#
# Copyright (c) STMicroelectronics 2014
#
# This file is part of git-mirror.
#
# git-mirror is free software: you can redistribute it and/or modify 8
# it under the terms of the GNU General Public License v2.0
# as published by the Free Software Foundation
#
# git-mirror is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of 13
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# v2.0 along with git-mirror. If not, see <http://www.gnu.org/licenses/>.
#

set -eu
set -o pipefail

dirname=$(dirname "$0")

declare -i failed
failed=0
for test in $dirname/test-*.sh; do
    echo "TESTS: executing test: $test..."
    res=0
    $test || res=$?
    [ $res = 0 ] || failed=$((failed + 1))
done

[ $failed != 0 ] || echo "SUCCESS: all test scripts passed"
[ $failed = 0 ] || echo "FAILURE: $failed test scripts failed"
[ $failed = 0 ] || exit 1
