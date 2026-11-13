# Deployment behavior

This document describes the intended deployment contract and the boundaries of
the current engine. CLI, manifest, and Nix helper interfaces are experimental;
framework modules are not implemented yet.

## Current implementation

The Zig engine accepts an explicit list of source files and relative destination
paths, one existing destination root, and an existing private state directory.
The roots must be disjoint and on the same filesystem. Missing parent directories
beneath the destination root are installed within the journaled transaction.
The Nix application wrapper initializes the two roots outside that transaction;
those roots are not owned or removed by the engine.

The private state directory belongs exclusively to one imprynt state. It holds
the lock, committed state, journal, staged contents, and retained originals.
Do not use an ordinary directory containing other applications' files for it,
edit its contents, or delete it to work around a recovery error. Root paths are
recorded in state, so changing a root symlink does not silently relocate ownership.

File fingerprints include SHA-256 contents and POSIX permission bits. Desired
permissions are explicit (internally defaulting to 0644); ownership, ACLs,
extended attributes, and timestamps are not managed. A missing previously
managed file currently produces a conflict rather than being recreated.

## Ownership and conflicts

Ownership is per deployed file, including files generated from input trees.
Unrelated manual files survive updates and reconciliation to an empty declaration.
There is no directory-ownership mode in the initial scope.

Compare actual managed files with the last committed state before updating or
removing them. Unexpected existing files and externally changed managed files
are conflicts, even when an unmanaged file matches the desired contents.
Initially, conflicts are errors, without backup or overwrite policies. The
planner collects preflight conflicts and returns no executable actions when
any conflict exists. Preparation may write private staging files, but preflight
failure does not change managed destinations.

Record directories created by imprynt and remove them only when no longer
needed and empty. Existing directories are not adopted. Staged directories are
identified by inode and installed without replacement after journal publication.
Rollback uses the same identity checks and removes only empty directories. An
unneeded directory containing manual files stays recorded for later cleanup;
a directory replaced outside imprynt is no longer owned. Inode reuse after
external deletion is not a general concurrent-mutation safety guarantee.

## Paths and generation

The build-time generator enumerates input trees into an explicit per-file
manifest. The runtime engine does not understand fonts or the framework invoking
it. Consumers own lifecycle integration; generated file lists need not be read
back into Nix evaluation.

Follow source symlinks to materialize regular files. Tree generation rejects
broken links, directory cycles, and non-regular files. Extension filtering is
optional and case-insensitive; selected files retain relative paths. The runtime
follows individual source links through the operating system and rejects
non-regular source files.

Destination roots are explicit. Resolve and record their locations, allowing
a root itself to be a symlink. Open parent components beneath the root without
following symlinks; unexpected destination symlinks are conflicts. A changed
root symlink target is an error, not an ordinary update. Absolute destination
entries, empty components, NUL bytes, dot/parent components, duplicates, and
file/parent overlaps are rejected.

## Transactions and recovery

One transaction covers one application using one managed state, not an entire
framework activation or independently managed imprynt states. Serialize operations
sharing that state with a nonblocking exclusive file lock.

Committed state records the previous deployment. A separately published journal
records the next state and unfinished changes. New contents are staged and old
files are retained until commit, so rollback does not require old Nix store
sources. State and journal formats are internal and have no migration guarantee.

A durable commit separates two recovery behaviors:

- Before commit: roll back to the previous deployment.
- After commit: keep the new deployment and finish cleanup.

Resolve an unfinished transaction before applying a newly supplied declaration.
Check expected file contents during recovery as well as normal application.
Prevalidate all recovery actions before starting rollback. If external changes
prevent safe recovery, stop and retain the files, retained originals, and journal.

Detach a resolved transaction by renaming its directory before deleting recovery
artifacts. An interrupted cleanup must not make an unresolved transaction appear
to be disposable preparation data.

## Safety limits and remaining work

Tests exercise isolated real files, injected application failures, interrupted
application and recovery, conflicts, locks, and symlink boundaries. They do not
establish production safety.

The engine syncs file contents and directories, but physical power loss and
filesystem-specific durability are unverified. Fault injection currently unwinds
the process without automatic recovery; it does not simulate SIGKILL at every
syscall. Multi-file changes are not externally atomic.

The lock coordinates imprynt using the same state, not independent states or
other programs. No-follow traversal and non-replacing moves reduce accidental
redirection and clobbering, but observation and mutation are not one atomic
operation. Concurrent hostile mutation, parent-directory relocation, and
case-insensitive or Unicode-equivalent destination aliases are not yet handled
as a complete safety boundary. Do not run this engine against concurrently
modified or untrusted destinations.

JSON state and journal documents are limited to 16 MiB. Path-specific diagnostics in the
CLI are available for preflight conflicts; recovery diagnostics currently report
an error class and retain the journal. First-party framework modules are not
implemented. Font discovery and application
font caches belong to the consumer's platform integration, not the engine's
commit. Removing an entire integration is not the same as removing
individual declarations: automatic cleanup in that situation remains unresolved.
