# Glossary

**Project**
A repo whose main checkout is mounted in the sandbox at its host path, e.g. `~/dev/vortex`.

**Workspace**
A colocated jj workspace of a repo, and therefore also a git worktree. Lives at
`~/dev/workspaces/<repo>/<name>`, whether jj, T3 Code, Zed, or a person created it. Only
Workspaces of a Project are visible in the sandbox.
_Avoid_: worktree (except when talking about what a tool created before adoption)

**Adopt**
Turn a git worktree that a tool created into a Workspace, by giving it jj workspace metadata.

**Park**
Remove a Workspace's directory once the tool's branch points at its work, so the tool can recreate
it from that branch. The reverse of creating and Adopting it.

**Cargo workspace**
A Rust cargo workspace. Always qualified, since a Workspace usually contains one.
