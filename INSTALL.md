Installation of git-mirror proxy tools
======================================

The basic principle is to install the tools such that
when the mirror server is accessed through ssh for git commands
the git-upload-pack/archive and git-receive-pack are executed
in place of the standard /usr/bin/git-upload-pack|archive (for read
from the repositories) and /usr/bin/git-receive-pack (for write to
the repositories).

For the integration with gitolite v2.x, see the related section below.

Installation of tools
=====================

On the server that stores mirrored gits,
install the tools under the account that runs the mirror
side git layer and set the PATH to point to the tools in first place.

IMPORTANT: it is mandatory to have the path to
git-mirror/bin first in PATH as it contains executables
that will replace the standard git executables stored
in /usr/bin.

Install with::

    user@mirror$ cd $HOME
    user@mirror$ git clone git@github.com:guillon/git-mirror.git git-mirror
    user@mirror$ # create ~/.git-mirror/config (see below) with at least:
    user@mirror$ cat > ~/.git-mirror/config <<EOF
    [git-mirror]
        master-server=<master_server>     # for instance git.server.com
        master-user=<master_user>         # for instance gitolite
        master-identity = ~/.ssh/id_rsa   # the pub key for user on git.server.com
    EOF
    user@mirror$ cat "PATH=$HOME/git-mirror/bin:$PATH" >>.bashrc 

With this setup the mirror will be served through the git-mirror commands
that act as a proxy for read request. It will not activate the proxy for write
requests, see the configuration below to do so.

NOTE: this example assumes a bash login shell, for other shells use
either ~/.cshrc, ~/.tcshrc or other profile which is executed through
a ssh login.

IMPORTANT: verify that a the ssh to this account actually have
git-upload-pack taken from this location::

    client@host$ ssh mirror which git-upload-pack
/home/user/git-mirror/bin/git-upload-pack

If it is not the case, setup your shell startup scripts to
do so.

NOTE: if the user running git-mirror is also running for instance
a gitolite layer, it may not be possible to test the ssh connection
as above.


Configuring the mirror proxy
============================

Configure your mirror master by adding a ~/.git-mirror/config file.

In paticular master-* values are mandatory::

    $ cat $HOME/.git-mirror/config
    [git-mirror]
        master-server=<master_server>  # for instance git.server.com
        master-user=<master_user>      # for instance gitolite
        master-identity=<patch to key file pair> # for instance ~/.ssh/id_rsa
        #debug = false        # true enables logs (default: false)
        #enable-read = true   # false blocks reads to master (default: true)
        #enable-write = false # false blocks writes to master (default: false)
        #local-base = ~/repositories # if set remove this prefix from client path (default: empty)

The debug parameter is used have logs output in ~/.git-mirror/git-mirror.log
when some issue occurs, do not let it activated for a while as you may fill-up
the mirror user home dir.

The enable-read parameter is true by default (i.e. read only proxy), if for
some reason you want to block read accesses to the master_server, set it to
false.

The enable-write parameter is false by default. Set it to true to activate the
proxy write-through to the master_server. In this proxy write-through mode,
the writes to the mirror when targeting a mirrored repository will be
redirected as writes to the master_server.

Testing the mirror proxy
========================

Test your mirror by fetching from the mirror instead of the master_server.

Assume that you have a repository myrepo on the master_server:
ssh://master_user@master_server/myrepo

You have to handle the mirroring of this repository by some way with git
clone/git remote update. The git-mirror proxy script do not update the
mirror itself as of now. This must be done independently with a crontab
or alike.

Assume thus that the myrepo is mirrored on your mirror server at
ssh://mirror_user@mirror/myrepo.

Do for instance a clone of myrepo with::

    $ git clone ssh://mirror_user@mirror/myrepo

This will actually not do more than expected, i.e. just fetch from the
mirrored repository on the mirror server.

Then, do for instance a clone of a non mirrored repo nomirrorrepo::

    $ git clone ssh://mirror_user@mirror/nomirrorrepo

This will actually clone from the master_server as this repo does not exists
on the mirror server.


Integration with gitolite
=========================

If the git-mirror proxy tools are integrated under a gitolite
authentication layer, one need first to apply a patch to
gitolite in order to add a Pass-Through (P) specification in
the gitolite credentials.

The patch is located in contrib/gitolite/patches-g2 and applies
to gitolite v2.x version only. No integration with gitolite v3.x
was done yet.

Either apply the patches into the sources before gitolite install::

    $ cd ~/gitolite
    $ cat ~/git-mirror/contrib/gitolite/patches-g2/* | patch -N -p1

Or install the patches onto the installed gitolite scripts if already
deployed (take care of the -p2 option then)::

    $ cd ~/bin
    $ cat ~/git-mirror/contrib/gitolite/patches-g2/* | patch -N -p2

Then, install the git-mirror tools as described above. In the case
of gitolite integration, do not care for the PATH setting as the
GIT_PATH variable in the gitolite configuration will do the job.

Though in the .git-mirror/config explicitly set the local-base to
the same vale as the GL_REPO_BASE under gitolite, thus generally one
may have a configuration such as::

    $ cat $HOME/.git-mirror/config
    [git-mirror]
        master-server=<master_server>  # for instance git.server.com
        master-user=<master_user>      # for instance gitolite
        master-identity=<patch to key file pair> # for instance ~/.ssh/id_rsa
        local-base = ~/repositories    # path to gitolite repositories

Then in the ~/.gitolite.rc set the following variables values:

    $GL_WILDREPOS = 1; # allows wild repos for P or C access
    ...
    $GIT_PATH = $ENV{HOME} . "/git-mirror/bin"; # Force path to git-mirror first

Last, in order to allow a delegation of gitolite to the git-mirror
proxy tools, one may modify for instance the gitolite configuration as
usual through the gitolite-admin push, with for instance::

    repo    gitolite-admin
        RW+     =   guillon

    repo    testing
        RW+     =   @all

    repo    [a-zA-Z_].*
        P       = @all

Note the last repo specification, which actually stands for:
for any other repo matching the regexp (actually all repo names here)
set P(ass-through) to @all.

This will thus have the effect of delegating the management of the
repository to the git-mirror proxy even when the repository does not
exists locally.

Note that you still have to configure the ~/.
