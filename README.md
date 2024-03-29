Simple git-mirror proxy tools
=============================

Set of executable scripts acting as a proxy between a
mirror git server and a master git server.

See the [INSTALL](INSTALL.md) file for installation and configuration instructions.

Installing on a mirror server these tools will have the effect of taking
precedence for the execution of the three git commands used server side
to implement a client fecth or a client push/archive. The only commands
executed on the git server side are:
- git-upload-pack (when the client does a git fetch or alike),
- git-upload-archive (when the client does a git archive),
- git-receive-pack (when the client does a git push or alike).
- git-lfs-authenticate (when the client request authentication to a LFS backend)

These three command are provided by this package and will act
as a proxy between the mirror git server and the master git server.

By default the proxy will server only read accesses, it can also be
configured in write mode and will serve write as write-through to the
master server being mirrored.

In the case of the upload commands (a git client fetch) , when the
repository exists on the mirror git server where these commands
are executed the mirror will serve the upload directly. Othewise
the upload will be executed remotely on the master git server.

In the case of the receive command (a git client push), when the
epository exists on the mirror git server and is not a mirrored
repository, the receive will be served directly, otherwise rhe
receive will be executed remotely on the master git server.

In order to transfer the execution to the master, a ssh connection is
established under the credentials defined in the configuration with
master_server, master_user and master_identity.

It means that these credentials must have read and write accesses
rights throuh the master git server authentification layer.

Actually it means that the identity used for the master git server
accesses will not be the one of the client actually doing the
connection to the mirror git server. This is generally not an
issue for ssh based git authentification layers such as gitolite
or other layers using ssh pub keys as authentication check.

Though, in order to avoid confusing authentification errore, the
master_user must be setup to have sufficient credentials to
cover the expected authentification of users that mean to connect
transparently to either the master server or the mirror server.

For git authentification layers such as gerrit, additional checks
may be done (such as the ssh login name must be associated with the
right ssh login key as found in the gerrit database). In these
cases this package may not be able to access the master server for
write and the write-through mode must be kept disabled. Then
the client must explicitly set the actual master server in the
commands or make an alias in the git configuration.

