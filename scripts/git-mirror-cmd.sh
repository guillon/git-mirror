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

declare real_base="$(basename "$(readlink -f "$0")" .sh)"
declare base="$(basename "$0" .sh)"
declare dir="$(dirname "$0")"
declare full_host="$(hostname -f)"
declare tmpdir=""
function cleanup() {
    local exit_code=$?
    trap - INT TERM QUIT EXIT
    [ ! -d "${tmpdir}" ] || rm -rf "$tmpdir"
    exit $exit_code
}
trap cleanup INT TERM QUIT EXIT

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
declare -r VERSION="v0.2"
declare -r cfgfile="$HOME/.git-mirror/config"
declare -r logfile="$HOME/.git-mirror/git-mirror.log"

# Configuration and defaults
declare master_user=""
declare -r default_master_user=""
declare master_server=""
declare -r default_master_server=""
declare master_identity=""
declare -r default_master_identity=""
declare ssh=""
declare -r default_ssh="ssh"
declare ssh_opts=""
declare -r default_ssh_opts=""
declare git_receive_pack=""
declare -r default_git_receive_pack="/usr/bin/git-receive-pack"
declare git_upload_pack=""
declare -r default_git_upload_pack="/usr/bin/git-upload-pack"
declare git_upload_archive=""
declare -r default_git_upload_archive="/usr/bin/git-upload-archive"
declare write_enabled=""
declare -r default_write_enabled="false"
declare read_enabled=""
declare -r default_read_enabled="true"
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
    echo "fatal: remote $full_host: $real_base: $base: $message" >&2
    exit 1
}

# Read configuration fro cfgfile
function read_config() {
    [ -f "$cfgfile" ] || return 0
    git config -f "$cfgfile" -l >/dev/null
    tmpdir="$(mktemp -d)"
    cp "$cfgfile" "$tmpdir/config"
    master_user="$(git config -f "$tmpdir/config" git-mirror.master-user || echo "$default_master_user")"
    master_server="$(git config -f "$tmpdir/config" git-mirror.master-server || echo "$default_master_server")"
    master_identity="$(git config -f "$tmpdir/config" --path git-mirror.master-identity || echo "$default_master_identity")"
    ssh="$(git config -f "$tmpdir/config" --path git-mirror.ssh || echo "$default_ssh")"
    ssh_opts="$(git config -f "$tmpdir/config" git-mirror.ssh-opts || echo "$default_ssh_opts")"
    git_receive_pack="$(git config -f "$tmpdir/config" --path git-mirror.git-receive-pack || echo "$default_git_receive_pack")"
    git_upload_pack="$(git config -f "$tmpdir/config" --path git-mirror.git-upload-pack || echo "$default_git_upload_pack")"
    git_upload_archive="$(git config -f "$tmpdir/config" --path git-mirror.git-upload-archive || echo "$default_git_upload_archive")"
    write_enabled="$(git config -f "$tmpdir/config" --bool git-mirror.write-enabled || echo "$default_write_enabled")"
    read_enabled="$(git config -f "$tmpdir/config" --bool git-mirror.read-enabled || echo "$default_read_enabled")"
    debug="$(git config -f "$tmpdir/config" --bool git-mirror.debug || echo "$default_debug")"
    rm -rf "$tmpdir"
}

# Get the expanded dir parameter from the
# upload/receive commands
function get_dir_param {
    while [ $# -gt 1 ]; do shift; done
    local dir="${1-}"
    [ "$dir" != "" ] || return 0
    # git supports expansion of ~/
    [ "${dir::2}" = "~/" ] && dir="$HOME/${dir:2}"
    echo "${dir%.git}.git"
}

# Check that configuration is valid
function check_config() {
    # Check debug first as otherwise fatal error can't be logged correctly
    [ "$debug" != "" ] || fatal "debug not defined"
    [ "$debug" = "true" -o "$debug" = "false" ] || "debug not in true|false: $debug"
    [ "$master_user" != "" ] || fatal "master_user not defined"
    [ "$master_server" != "" ] || fatal "master_server not defined"
    [ "$master_identity" != "" ] || fatal "master_identity not defined"
    [ -f "$master_identity" ] || fatal "master_identity not readable: $master_identity"
    [ "$ssh" != "" ] || fatal "ssh not defined"
    [ "$(which "$ssh" 2>/dev/null)" != "" ] || fatal "could not exec ssh: $ssh"
    [ "$git_receive_pack" != "" ] || fatal "git_receive_pack not defined"
    [ -x "$git_receive_pack" ] || fatal "could not exec git_receive_pack: $git_receive_pack"
    [ "$git_upload_pack" != "" ] || fatal "git_upload_pack not defined"
    [ -x "$git_upload_pack" ] || fatal "could not exec git_upload_pack: $git_upload_pack"
    [ "$git_upload_archive" != "" ] || fatal "git_upload_archive not defined"
    [ -x "$git_upload_archive" ] || fatal "could not exec git_upload_archive: $git_upload_archive"
    [ "$write_enabled" != "" ] || "write_enabled not defined"
    [ "$write_enabled" = "true" -o "$write_enabled" = "false" ] || "write_enabled not in true|false: $write_enabled"
    [ "$read_enabled" != "" ] || "read_enabled not defined"
    [ "$read_enabled" = "true" -o "$read_enabled" = "false" ] || "read_enabled not in true|false: $read_enabled"
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
    local dir="$(get_dir_param "$@")"
    [ "$dir" != "" ] || fatal "can't find dir parameter"
    local is_mirror
    local is_local
    if [ -d "$dir" ]; then
	is_mirror="$(git config -f "$dir/config" --bool remote.origin.mirror 2>/dev/null || echo false)"
	is_local=true
    else
	is_mirror=false
	is_local=false
    fi
    if [ "$is_local" = true -a "$is_mirror" = false ]; then
	log "INFO: repository exists locally and has mirror = false. Serving receive from mirror"
	log "INFO: exec: $git_receive_pack $*"
	exec "$git_receive_pack" "$@"
    else
	log "INFO: repository does not exist locally or has mirror = true. Serving receive from master"
	if [ "$write_enabled" = "false" ]; then
	    log "INFO: mirror receive disabled (write_enabled == false). Aborting master receive"
	    fatal "mirror is not setup to allow write to master, write aborted"
	fi
	log "INFO: exec: $ssh $ssh_opts -i$master_identity $master_user@$master_server git-receive-pack $*"
	exec "$ssh" $ssh_opts -i"$master_identity" "$master_user"@"$master_server" git-receive-pack "$@"
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
    local dir="$(get_dir_param "$@")"
    [ "$dir" != "" ] || fatal "can't find dir parameter"
    local is_mirror
    local is_local
    if [ -d "$dir" ]; then
	is_local=true
	is_mirror="$(git config -f "$dir/config" --bool remote.origin.mirror 2>/dev/null || echo false)"
    else
	is_local=false
	is_mirror=false
    fi
    [ "$cmd" = "git-upload-pack" ] && local_cmd="$git_upload_pack"
    [ "$cmd" = "git-upload-archive" ] && local_cmd="$git_upload_archive"
    if [ "$is_local" = true -a "$is_mirror" = false ]; then
	log "INFO: repository exists locally and has mirror = false. Serving upload of local repository from mirror"
	log "INFO: exec: $local_cmd $*"
	exec "$local_cmd" "$@"
    elif [ "$is_local" = true -a "$is_mirror" = true ]; then
	log "repository exists locally and  has mirror = true. Serving upload of mirrored repository from mirror (assume up to date)"
	if [ "$read_enabled" = "false" ]; then
	    log "INFO: mirror upload disabled (read_enabled == false). Aborting mirror upload"
	    fatal "mirror is not setup to allow read of mirrored master repositories, read aborted"
	fi
	log "INFO: exec: $local_cmd $*"
	exec "$local_cmd" "$@"
    else
	log "INFO: repository does not exist locally. Serving upload of master repository from master"
	if [ "$read_enabled" = "false" ]; then
	    log "INFO: mirror upload disabled (read_enabled == false). Aborting master upload"
	    fatal "mirror is not setup to allow read of master repositories, read aborted"
	fi
	log "INFO: exec: $ssh $ssh_opts -i$master_identity $master_user@$master_server $cmd $*"
	exec "$ssh" $ssh_opts -i"$master_identity" "$master_user"@"$master_server" "$cmd" "$@"
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
case "$base" in
    git-receive-pack) mirror_receive "$base" "$@" ;;
    git-upload-pack) mirror_upload "$base" "$@" ;;
    git-upload-archive) mirror_upload "$base" "$@" ;;
    git-mirror-cmd) mirror_cmd "$@" ;;
    *) fatal "unexpected base for $real_base: $base" ;;
esac
