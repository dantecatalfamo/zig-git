# zig-git

Implementing git structures and functions in pure zig.

Still very much a work in progress. Some commands are redundant and some will get replaced.

Doesn't support packed objects yet.

## Command

The `zig-git` command currently supports the following subcommands:
* `add <target>` - Add a file or directory to the git index
* `branch` - List current branches (`refs/heads/`) in a format similar to `git branch`
* `branch-create <name>` - Create a new branch from the current branch
* `commit` - Commit the current index
* `index` - List out the content of the index
* `init [directory]` - Create a new git repository
* `read-commit <hash>` - Parse and display a commit
* `read-ref [ref]` - Display a ref and what it points to, or all refs if no argument is given
* `read-tree` - Parse and display the all files in a tree
* `refs` - List all refs
