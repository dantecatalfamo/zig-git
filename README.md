# zig-git

Implementing git structures and functions in pure zig.

Still very much a work in progress. Some commands are redundant and some will get replaced.

This project is primarily for learning purposes and not meant to be a replacement for something like libgit2.

It doesn't support pack deltas yet.

## Command

The `zig-git` command currently supports the following subcommands:
* `add <target>` - Add a file or directory to the git index
* `branch` - List current branches (`refs/heads/`) in a format similar to `git branch`
* `branch-create <name>` - Create a new branch from the current branch
* `checkout` - Checkout a ref or commit
* `commit` - Commit the current index (as a test, doesn't use correct information)
* `index` - List out the content of the index
* `init [directory]` - Create a new git repository
* `log` - List commits
* `read-commit <hash>` - Parse and display a commit
* `read-object <hash>` - Dump the decompressed contents of an object to stdout
* `read-pack <id>` - Parse a pack file and iterate over its contents
* `read-pack-index <id> <hash>` - Search a pack file index for the offset of an object with a hash in a pack file
* `read-ref [ref]` - Display a ref and what it points to, or all refs if no argument is given
* `read-tag [ref]` - Parse and display a tag
* `read-tree <name>` - Parse and display the all files in a tree
* `refs` - List all refs
* `rm <file>` - Remove file from index
* `root` - Print the root of the current git project
* `status` - Branch status
