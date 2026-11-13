# Deployment contract

These are accepted design decisions, not implemented guarantees. The deployment
engine, manifest generator, and framework modules have not been implemented.
Concrete schemas and public command/API names remain undecided.

## Ownership and conflicts

Inputs may be directory trees, but ownership is per deployed file. Unrelated
manual files survive updates and removal of a deployment declaration. There is
no directory-ownership mode in the initial scope.

Record directories created by imprynt; remove them only when no longer needed
and empty. Existing directories are not adopted as owned directories.

Compare actual managed files with the last committed state before updating or
removing them. Unexpected existing files and externally changed managed files
are conflicts. Initially, conflicts are errors, without backup or overwrite
policies. Collect preflight conflicts and report them without starting managed
file mutations. Preflight does not eliminate races with external writers.

## Generation and application boundary

Build-time generation enumerates input trees into an explicit per-file manifest.
The runtime engine applies that manifest; it does not need to understand fonts
or the framework invoking it. Framework modules own lifecycle integration.
Generated file lists do not need to be read back into Nix evaluation.

Follow source symlinks to materialize regular files. Broken links and cycles are
generation errors. Destination managed roots are explicit: resolve and record
their locations, allow a root itself to be a symlink, and reject unexpected
symlinks beneath it. A changed root symlink target during management is an
error, not an ordinary update.

## Transaction boundary

One transaction covers one application using one managed state. It does not
cover an entire framework activation or independently managed imprynt states.
Serialize imprynt operations sharing that state with a lock. This is not a lock
against unrelated programs writing destination files.

Maintain three separate artifacts:

- Desired manifest: the requested per-file deployment.
- Committed state: the last committed deployment, including content hashes,
  managed attributes, resolved roots, and created-directory ownership.
- Recovery journal: the unfinished plan, staged and retained files, and durable
  transaction progress.

Prepare new contents on the destination filesystem. Retain old files needed
for rollback until commit, so recovery does not require old Nix store sources.
This design aims for recoverability, not externally atomic visibility of a
multi-file change.

## Recovery

A durable commit separates two recovery behaviors:

- Before commit: roll back to the previous deployment.
- After commit: keep the new deployment and finish cleanup.

Resolve an unfinished transaction before applying a newly supplied manifest.
Check expected file contents during recovery as well as normal application.
If external changes prevent safe recovery, stop and retain the affected files,
retained originals, and journal rather than silently overwriting those changes.

## Remaining design and verification

Exact manifest/state/journal encodings, managed metadata, durable write ordering,
filesystem synchronization, safe path traversal, and missing-file handling still
need concrete design and tests. Automatic cleanup when an entire integration is
removed is not solved by removing individual deployment declarations.

No crash-recovery, power-loss, concurrency, or real-font recognition guarantee
has been validated yet.
