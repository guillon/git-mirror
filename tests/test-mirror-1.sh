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
basename=$(basename "$0" .sh)
dirname=$(dirname "$0")

# Parameters
ROOT_DIR="${ROOT_DIR-$dirname/..}"  # Optional src root dir (for path to git-mirror)
ROOT_DIR=$(readlink -e "$ROOT_DIR")
KEEPTEST="${KEEPTEST-false}" # Set to true for keeping temporary test dir
[ "$KEEPTEST" = false ] || KEEPTEST=true

function cleanup() {
    local code=$?
    [ "${testdir-}" = "" -o $KEEPTEST = true ] || rm -rf "$testdir"
    exit $code
}

declare -i failed
failed=0
[ "$KEEPTEST" = true ] || testdir="$(mktemp -d)"
[ "$KEEPTEST" != true ] || testdir="$basename.dir"
[ "$KEEPTEST" != true ] || rm -rf "$testdir"
[ "$KEEPTEST" != true ] || mkdir -p "$testdir"

function init_ref_git()
{
    local ref_git="$1"
    mkdir -p "$ref_git"
    pushd "$ref_git" >/dev/null
    git init -q --bare
    popd >/dev/null
}

function populate_ref_git()
{
    local ref_git="$1"
    local work_git="$2"
    mkdir -p "$work_git"
    pushd "$work_git" >/dev/null
    git init -q
    git remote add origin "$ref_git"
    echo "This is a test reference git" > README
    git add README
    git commit -q -m 'This is a test commit'
    git push -q origin master 2>/dev/null
    popd >/dev/null
}

function init_git_mirror()
{
    local home_dir="$1"
    local references_dir="$2"
    local mirrors_dir="$3"
    mkdir -p "$home_dir"
    pushd "$home_dir" >/dev/null
    mkdir -p .git-mirror
    cat >.git-mirror/config <<EOF
[git-mirror]
    master-server=localhost
    master-user=$USER
    master-identity=~/.ssh/id_rsa
    remote-repos = $references_dir
    local-repos = $mirrors_dir
    local-base = /$UNIQUE_TEST_BASE
    debug = true
    auto-update = true
    auto-create = true
EOF
    popd >/dev/null
}

function check_pass()
{
    local res=0
    "$@" 2>&1 | sed "s!^!    !" || res=$?
    [ $res != 0 ] || echo "PASS: $basename:" "$@"
    [ $res = 0 ] || echo "FAIL: $basename:" "$@"
    [ $res = 0 ] || failed=$((failed + 1))
}

function check_fail()
{
    local res=0
    "$@" 2>&1 | sed "s!^!    !" || res=$?
    [ $res = 0 ] || echo "PASS: $basename: xfail:" "$@"
    [ $res != 0 ] || echo "FAIL: $basename: xfail:" "$@"
    [ $res != 0 ] || failed=$((failed + 1))
}

pushd "$testdir" >/dev/null

# Some locations for the test
references_dir=$PWD/references
mirrors_dir=$PWD/mirrors
working_dir=$PWD/working
users_dir=$PWD/users
git_mirror_dir=$PWD/git-mirror

# Need to set upload command for tests
UPLOAD_CMD="env GIT_MIRROR_ROOT=$git_mirror_dir $ROOT_DIR/bin/git-upload-pack"

# Need to define a unique test base for the test
UNIQUE_TEST_BASE="git-mirror-test-$$"

# Remote repos base URL (will go though mirror)
REPOS_BASE="ssh://$USER@localhost/$UNIQUE_TEST_BASE"

init_ref_git $references_dir/test-1.git
populate_ref_git $references_dir/test-1.git $working_dir/test-1
init_git_mirror $git_mirror_dir $references_dir $mirrors_dir

#
# Actual tests
#
mkdir -p users
pushd users >/dev/null

echo "TEST: $basename: Testing of local ssh connection, pre-requisite for the test (must pass)..."
check_pass ssh $USER@localhost /bin/true

echo "TEST: $basename: Testing initial clone with auto create (must pass)..."
check_pass git clone -u "$UPLOAD_CMD" $REPOS_BASE/test-1 test-1.1

echo "TEST: $basename: Testing second clone with auto update (must pass)..."
check_pass git clone -u "$UPLOAD_CMD" $REPOS_BASE/test-1 test-1.2

echo "TEST: $basename: Testing of non existent master repository (must fail)..."
check_fail git clone -u "$UPLOAD_CMD"$REPOS_BASE/test-2 test2.1

echo "TEST: $basename: Testing update of remotly removed master repository, servers from mirror as of now (must pass)..."
rm -rf $references_dir/test-1.git
check_pass git clone -u "$UPLOAD_CMD" $REPOS_BASE/test-1 test1.3

popd >/dev/null
popd >/dev/null

[ $failed != 0 ] || echo "SUCCESS: $basename: all tests passed"
[ $failed = 0 ] || echo "FAILURE: $basename: some tests failed"
[ $failed = 0 ] || exit 1
