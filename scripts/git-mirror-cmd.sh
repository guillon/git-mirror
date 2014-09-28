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

#
# Usage: get usage with git-mirror -h
#
# Ref to INSTALL file for installation and configuration.
#
# Implements a proxy for git upload/receive
# commands executed on a host serving git.
# If an upload command is executed:
# - either git-upload-pack or git-upload-archive
# - if the repo exists locally, it is served directly
#   otherwise the upload is redirected to the master
#
# If a receive command is executed:
# - a git-receive-pack
# - if the repo exists locally and is a mirror, the
#   receive is redirected to the master
#   otherwise the receive is done locally
#
# The access rigths are controlled by the upper
# transport layers and thus accesses to the host
# maintaining the mirrors and executing these scripts
# must be maintained corectly w.r.t. what is expected
# on the master.
# Then actual accesses on the master (read or write)
# are done by the single master_user, which must have
# read/write rights on the master server for all the
# repositories possibly accesed through the mirror.
#

set -eu
set -o pipefail

# Force clean environment
export PATH=/usr/bin:/bin
export LD_LIBRARY_PATH=

declare real_base="$(basename "$(readlink -f "$0")" .sh)"
declare base="$(basename "$0" .sh)"
declare dir="$(dirname "$0")"
declare full_host="$(hostname -f)"
declare tmpdir=""
declare tmpdir2=""
function cleanup() {
    local exit_code=$?
    trap - INT TERM QUIT EXIT
    [ ! -d "${tmpdir:-}" ] || rm -rf "$tmpdir"
    [ ! -d "${tmpdir2:-}" ] || rm -rf "$tmpdir2"
    exit $exit_code
}
trap cleanup INT TERM QUIT EXIT
tmpdir="$(mktemp -d)"

# Usage
function usage() {
    cat <<EOF
Usage for git-mirror-cmd:

The git-mirror-cmd should not be called directly when installed
on a mirror git server.

Actually the git-upload/receive commands are links to this scripts
and will act as a proxy between the git client and the master git server.

When called directly, the only available functionalities are this help
screen and the version information:

  git-mirror-cmd -v|--version : get version
  git-mirror-cmd -h|--help : this usage screen

EOF
}

# Version
function version() {
    local sha1
    sha1=$(sha1sum $0 | cut -f1 -d' ')
    echo "$base version $VERSION [sha1:$sha1]"
}

# Globals
declare -r VERSION="v0.5"

# Root dir and configuration files
declare root_dir
declare cfgfile
declare logfile

# Configuration and defaults
declare master_user=""
declare -r default_master_user=""
declare master_server=""
declare -r default_master_server=""
declare master_identity=""
declare -r default_master_identity=""
declare ssh=""
declare -r default_ssh="/usr/bin/ssh"
declare ssh_opts=""
declare -r default_ssh_opts=""
declare git=""
declare -r default_git="/usr/bin/git"
declare git_receive_pack="" # will default to $git-receive-pack
declare git_upload_pack=""  # will default to $git-upload-pack
declare git_upload_archive="" # will default to $git-upload-archive
declare write_enabled=""
declare -r default_write_enabled="false"
declare read_enabled=""
declare -r default_read_enabled="true"
declare local_base=""
declare -r default_local_base=""
declare local_repos="" # will default to $local_base or $root_dir
declare remote_repos=""
declare -r default_remote_repos=""
declare auto_update=""
declare -r default_auto_update="false"
declare auto_create=""
declare -r default_auto_create="false"
declare debug=""
declare -r default_debug="false"

# Log to logfile
function log() {
    local message="$1"
    [ "$debug" = "true" ] || return 0
    mkdir -p "$(dirname "$logfile")"
    echo "[$(date +'%Y-%m-%d-%T')] $real_base: $$: $base: $message" >> "$logfile"
}

# Fatal error reported to the remote client
function fatal() {
    local message="$1"
    log "ERROR: $message"
    echo "fatal: remote: $full_host: $real_base: $base: $message" >&2
    exit 1
}

# Read configuration fro cfgfile
function read_config() {
    [ -f "$cfgfile" ] || fatal "no mirror configuration file found"
    git config -f "$cfgfile" -l >/dev/null
    cp "$cfgfile" "$tmpdir/config"
    master_user="$(git config -f "$tmpdir/config" git-mirror.master-user || echo "$default_master_user")"
    master_server="$(git config -f "$tmpdir/config" git-mirror.master-server || echo "$default_master_server")"
    master_identity="$(git config -f "$tmpdir/config" --path git-mirror.master-identity || echo "$default_master_identity")"
    ssh="$(git config -f "$tmpdir/config" --path git-mirror.ssh || echo "$default_ssh")"
    ssh_opts="$(git config -f "$tmpdir/config" git-mirror.ssh-opts || echo "$default_ssh_opts")"
    git="$(git config -f "$tmpdir/config" --path git-mirror.git || echo "$default_git")"
    git_receive_pack="$(git config -f "$tmpdir/config" --path git-mirror.git-receive-pack || echo "$git-receive-pack")"
    git_upload_pack="$(git config -f "$tmpdir/config" --path git-mirror.git-upload-pack || echo "$git-upload-pack")"
    git_upload_archive="$(git config -f "$tmpdir/config" --path git-mirror.git-upload-archive || echo "$git-upload-archive")"
    write_enabled="$(git config -f "$tmpdir/config" --bool git-mirror.write-enabled || echo "$default_write_enabled")"
    read_enabled="$(git config -f "$tmpdir/config" --bool git-mirror.read-enabled || echo "$default_read_enabled")"
    local_base="$(git config -f "$tmpdir/config" --path git-mirror.local-base || echo "$default_local_base")"
    local_repos="$(git config -f "$tmpdir/config" --path git-mirror.local-repos || echo "$local_base")"
    local_repos="${local_repos:-$root_dir}"
    remote_repos="$(git config -f "$tmpdir/config" --path git-mirror.remote-repos || echo "$default_remote_repos")"
    auto_update="$(git config -f "$tmpdir/config" --bool git-mirror.auto-update || echo "$default_auto_update")"
    auto_create="$(git config -f "$tmpdir/config" --bool git-mirror.auto-create || echo "$default_auto_create")"
    debug="$(git config -f "$tmpdir/config" --bool git-mirror.debug || echo "$default_debug")"
}

# Get the expanded dir parameter from the
# upload/receive commands
# Always returns an absolute path
function get_dir_param {
    while [ $# -gt 1 ]; do shift; done
    local dir="${1-}"
    # Optionally prune quotes around dir
    dir="${dir#\'}"
    dir="${dir%\'}"
    # git supports expansion of ~, but
    # we ignore it, assume same as root dir
    dir="${dir#~}"
    [ "${dir::1}" = "/" ] || dir="/$dir"
    echo "${dir%.git}.git"
}

# Get the base repo name from the client path.
# Pruning the local_base prefix if any.
# Returned base_path is always absolute.
function get_base_path {
    local client_path="${1?}"
    local base_path="$client_path"
    [ "${base_path::1}" = "/" ] || base_path="/$base_path"
    [ "$local_base" = "" ] || base_path="${base_path#$local_base}"
    [ "${base_path::1}" = "/" ] || base_path="/$base_path"
    echo "$base_path"
}

# Get the remote directory from the base path
# Returned remote dir is always absolute.
function get_remote_dir {
    local base_path="${1?}"
    local remote_dir
    remote_dir="$remote_repos$base_path"
    [ "${remote_dir::1}" = "/" ] || remote_dir="/$remote_dir"
    echo "$remote_dir"
}

# Get the local directory from the base path
# Returned local dir is always absolute
function get_local_dir {
    local base_path="${1?}"
    local local_dir
    local_dir="$local_repos$base_path"
    [ "${local_dir::1}" = "/" ] || local_dir="/$local_dir"
    echo "$local_dir"
}

# Check that configuration is valid
function check_config() {
    # Check debug first as otherwise fatal error can't be logged correctly
    [ "$debug" != "" ] || fatal "debug not defined"
    [ "$debug" = "true" -o "$debug" = "false" ] || fatal "debug not in true|false: $debug"
    [ "$master_user" != "" ] || fatal "master_user not defined"
    [ "$master_server" != "" ] || fatal "master_server not defined"
    [ "$master_identity" != "" ] || fatal "master_identity not defined"
    [ -f "$master_identity" ] || fatal "master_identity not readable: $master_identity"
    [ "$ssh" != "" ] || fatal "ssh not defined"
    [ -x "$ssh" ] || fatal "could not exec ssh: $ssh"
    [ "$git" != "" ] || fatal "git not defined"
    [ -x "$git" ] || fatal "could not exec git: $git"
    [ "$git_receive_pack" != "" ] || fatal "git_receive_pack not defined"
    [ -x "$git_receive_pack" ] || fatal "could not exec git_receive_pack: $git_receive_pack"
    [ "$git_upload_pack" != "" ] || fatal "git_upload_pack not defined"
    [ -x "$git_upload_pack" ] || fatal "could not exec git_upload_pack: $git_upload_pack"
    [ "$git_upload_archive" != "" ] || fatal "git_upload_archive not defined"
    [ -x "$git_upload_archive" ] || fatal "could not exec git_upload_archive: $git_upload_archive"
    [ "$write_enabled" != "" ] || fatal "write_enabled not defined"
    [ "$write_enabled" = "true" -o "$write_enabled" = "false" ] || fatal "write_enabled not in true|false: $write_enabled"
    [ "$read_enabled" != "" ] || fatal "read_enabled not defined"
    [ "$read_enabled" = "true" -o "$read_enabled" = "false" ] || fatal "read_enabled not in true|false: $read_enabled"
    [ "$auto_update" != "" ] || fatal "auto_update not defined"
    [ "$auto_update" = "true" -o "$auto_update" = "false" ] || fatal "auto_update not in true|false: $autp_update"
    [ "$auto_create" != "" ] || fatal "auto_create not defined"
    [ "$auto_create" = "true" -o "$auto_create" = "false" ] || fatal "auto_create not in true|false: $autp_update"
}

function mk_git_ssh() {
    local git_ssh="$tmpdir/git-ssh"
    if [ ! -x "$git_ssh" ]; then
	cat > "$git_ssh" <<EOF
#!/bin/sh
exec $ssh $ssh_opts -i "$master_identity" \${1+"\$@"}
EOF
	chmod u+x "$git_ssh"
    fi
    echo "$git_ssh"
}

# Create empty mirror of remote in repo_dir
# The implemetation has to be atomic for
# enforcing concurrency.
function mirror_create() {
    local repo_dir="${1?}"
    local remote="${2?}"
    local repo_basedir="${repo_dir#$local_repos/}"
    local repo_base="$(basename "$repo_basedir")"
    local repo_parent="$(dirname "$repo_basedir")"
    mkdir -p "$local_repos"
    # Restrict access to mirror user only
    chmod 700 "$local_repos"
    # Availability test
    [ -d "$local_repos/$repo_basedir" ] && return 0
    tmpdir2=$(mktemp --tmpdir="$local_repos" -d)
    mkdir -p "$tmpdir2/$repo_base"
    GIT_DIR="$tmpdir2/$repo_base" git init --bare >/dev/null
    GIT_DIR="$tmpdir2/$repo_base" git config --local remote.origin.url "$remote"
    GIT_DIR="$tmpdir2/$repo_base" git config --local remote.origin.mirror true
    GIT_DIR="$tmpdir2/$repo_base" git config --local remote.origin.fetch "+refs/*:refs/*"
    # Check if repo is accessible, otherwise ignore
    GIT_DIR="$tmpdir2/$repo_base" git ls-remote origin >/dev/null 2>&1 || return 0
    mkdir -p "$local_repos/$repo_parent"
    # Atomic creation of repository
    mv -t "$local_repos/$repo_parent" "$tmpdir2/$repo_base" 2>/dev/null || true
}

# Update mirror from source.
# Git supports safe-failure on concurrent updates.
# Thus it is safe to simply run and ignore errors
# for enforcing concurrency.
function mirror_update() {
    local repo_dir="${1?}"
    local remote
    local git_ssh
    [ -d "$repo_dir" ] || return 0
    git_ssh=$(mk_git_ssh)
    remote=$(GIT_DIR="$repo_dir" git config remote.origin.url)
    log "INFO: exec: env GIT_DIR=$repo_dir GIT_SSH=$git_ssh git fetch origin"
    GIT_DIR="$repo_dir" GIT_SSH="$git_ssh" git fetch origin >/dev/null 2>&1 || true
}

# Acts as a proxy for receive_pack
# The master_user must have write access to
# the master_server to which the receive_pack
# is redirected.
function mirror_receive() {
    local cmd="${1?}"
    shift

    read_config
    check_config
    log "INFO: eval: $cmd $*"
    local client_path="$(get_dir_param "$@")"
    [ "$client_path" != "" ] || fatal "can't find dir parameter"
    local base_path="$(get_base_path "$client_path")"
    local remote_dir="$(get_remote_dir "$base_path")"
    local local_dir="$(get_local_dir "$base_path")"
    log "INFO: client: $client_path , local: $local_dir , remote: $remote_dir"
    local is_mirror
    local is_local
    if [ -d "$local_dir" ]; then
	is_mirror="$(git config -f "$local_dir/config" --bool remote.origin.mirror 2>/dev/null || echo false)"
	is_local=true
    else
	is_mirror=false
	is_local=false
    fi
    if [ "$is_local" = true -a "$is_mirror" = false ]; then
	log "INFO: repository exists locally and has mirror = false. Serving receive from mirror"
	log "INFO: exec: $git_receive_pack '$local_dir'"
	"$git_receive_pack" "$local_dir"
    else
	log "INFO: repository does not exist locally or has mirror = true. Serving receive from master"
	if [ "$write_enabled" = "false" ]; then
	    log "INFO: mirror receive disabled (write_enabled == false). Aborting master receive"
	    fatal "mirror is not setup to allow write to master, write aborted"
	fi
	log "INFO: exec: $ssh $ssh_opts -i$master_identity $master_user@$master_server git-receive-pack '$remote_dir'"
	"$ssh" $ssh_opts -i"$master_identity" "$master_user@$master_server" git-receive-pack "'$remote_dir'"
    fi
}

# Acts as a proxy for upload_pack/archive
# The master_user must have read access to
# the master_server to which the the upload
# is redirected.
function mirror_upload() {
    local cmd="${1?}"
    shift

    read_config
    check_config
    log "INFO: eval: $cmd $*"
    local client_path="$(get_dir_param "$@")"
    [ "$client_path" != "" ] || fatal "can't find dir parameter"
    local base_path="$(get_base_path "$client_path")"
    local remote_dir="$(get_remote_dir "$base_path")"
    local local_dir="$(get_local_dir "$base_path")"
    log "INFO: client: $client_path , local: $local_dir , remote: $remote_dir"
    local is_mirror
    local is_local
    if [ ! -d "$local_dir" -a "$auto_update" = true -a "$auto_create" = true ]; then
	log "INFO: repository does not exist and auto_create = true. Attempting mirror creation"
	if [ "$read_enabled" = "false" ]; then
	    log "INFO: mirror upload disabled (read_enabled == false). Aborting mirror creation"
	    fatal "mirror is not setup to allow read of mirrored master repositories, read aborted"
	fi
	mirror_create "$local_dir" "ssh://$master_user@$master_server$remote_dir"
    fi
    if [ -d "$local_dir" ]; then
	is_local=true
	is_mirror="$(git config -f "$local_dir/config" --bool remote.origin.mirror 2>/dev/null || echo false)"
    else
	is_local=false
	is_mirror=false
    fi
    [ "$cmd" = "git-upload-pack" ] && local_cmd="$git_upload_pack"
    [ "$cmd" = "git-upload-archive" ] && local_cmd="$git_upload_archive"
    if [ "$is_local" = true -a "$is_mirror" = false ]; then
	log "INFO: repository exists locally and has mirror = false. Serving upload of local repository from mirror"
	log "INFO: exec: $local_cmd '$local_dir'"
	"$local_cmd" "$local_dir"
    elif [ "$is_local" = true -a "$is_mirror" = true ]; then
	log "INFO: repository exists locally and has mirror = true. Serving upload of mirrored repository from mirror (assume up to date)"
	if [ "$read_enabled" = "false" ]; then
	    log "INFO: mirror upload disabled (read_enabled == false). Aborting mirror upload"
	    fatal "mirror is not setup to allow read of mirrored master repositories, read aborted"
	fi
	[ "$auto_update" = true ] && log "INFO: auto updating mirror"
	[ "$auto_update" = true ] && mirror_update "$local_dir"
	log "INFO: exec: $local_cmd '$local_dir'"
	"$local_cmd" "$local_dir"
    else
	log "INFO: repository does not exist locally. Serving upload of master repository from master"
	if [ "$read_enabled" = "false" ]; then
	    log "INFO: mirror upload disabled (read_enabled == false). Aborting master upload"
	    fatal "mirror is not setup to allow read of master repositories, read aborted"
	fi
	log "INFO: exec: $ssh $ssh_opts -i$master_identity $master_user@$master_server $cmd '$remote_dir'"
	"$ssh" $ssh_opts -i"$master_identity" "$master_user"@"$master_server" "$cmd" "'$remote_dir'"
    fi
}

# Direct call to git-mirror-cmd
function mirror_cmd() {
    case "${1-}" in
        -h|--help) \
            usage ;;
        -v|--version) \
            version ;;
        *) \
            echo "$base: error: unexpected use. Get usage with $base --help." >&2
            exit 1 ;;
    esac
}

#
# Main processing
#
root_dir="${GIT_MIRROR_ROOT:-$HOME}"
cfgfile="$root_dir/.git-mirror/config"
logfile="$root_dir/.git-mirror/git-mirror.log"

if [ "${SSH_ORIGINAL_COMMAND+true}" = true ]; then
    # Get commands and arguments if called from a SSH force command
    set -- $SSH_ORIGINAL_COMMAND
    [ -n "${1:-}" ] || fatal "invalid ssh command: $SSH_ORIGIN_COMMAND"
    base=$(basename "$1")
    shift
fi

case "$base" in
    git-receive-pack) mirror_receive "$base" "$@" ;;
    git-upload-pack) mirror_upload "$base" "$@" ;;
    git-upload-archive) mirror_upload "$base" "$@" ;;
    git-mirror-cmd) mirror_cmd "$@" ;;
    *) fatal "unexpected base for $real_base: $base" ;;
esac
