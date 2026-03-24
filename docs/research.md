# org-babel-detangle: Thorough Research Summary

## 1. What It Does / API

`org-babel-detangle` is an interactive Elisp function in `ob-tangle.el`:

```elisp
(org-babel-detangle &optional SOURCE-CODE-FILE)
```

**Purpose**: Propagate changes made in a tangled source file back into the
original Org file's source blocks.

**Invocation**: Call it from within the tangled source code buffer (or pass a
file path). It scans the buffer for link comments, extracts the code body
between each matching pair of begin/end comments, then calls
`org-babel-tangle-jump-to-org` to navigate to the original Org source block
and `org-babel-update-block-body` to replace its contents.

**Return value**: Integer count of detangled blocks. Prints "Detangled N code
blocks".

**Companion function**: `org-babel-tangle-jump-to-org` — jumps from a position
in a tangled file to the corresponding Org source block. Used internally by
detangle and also available interactively.

## 2. How It Works — Mechanism in Detail

### Prerequisite: `:comments link` (or `:comments yes` / `:comments noweb`)

Detangle **only works** when the code was tangled with link comments. This is
set via the `:comments` header argument on source blocks. When `:comments link`
is active, tangling inserts bracketed Org-mode links as comments around each
code block in the output file.

### What the tangled file looks like

For a block named "my-block" in `config.org`:

```python
# [[file:config.org::*Heading][my-block]]
def hello():
    print("world")
# my-block ends here
```

The comment format is controlled by two customizable variables:
- `org-babel-tangle-comment-format-beg` — default: `"[[%link][%source-name]]"`
- `org-babel-tangle-comment-format-end` — default: `"%source-name ends here"`

Format placeholders: `%start-line`, `%file`, `%link`, `%source-name`.

### The detangle algorithm (from source code)

1. Go to beginning of tangled file buffer
2. Search forward for `org-link-bracket-re` (matches `[[link][description]]`)
3. If match has a description (match group 2), search for the corresponding
   end marker: `" <description> ends here"`
4. Extract body text between the begin-comment line and end-comment line
5. Call `org-babel-tangle-jump-to-org`:
   - Searches backward from point for the nearest bracket link comment
   - Validates that point is between a matching begin/end pair
   - Opens the link (using `org-link-open-from-string`)
   - Navigates to the named source block or Nth source block under heading
   - Returns the body text from the tangled file
6. Call `org-babel-update-block-body` with the new body to overwrite the
   Org source block content
7. Increment counter, continue scanning

**Critical**: It **updates existing Org source blocks in place**. It does NOT
create Org files from scratch. The Org file must already exist with the
source blocks in the positions the links point to.

## 3. Limitations

### 3.1 Requires pre-existing Org file with link comments
- The Org file must already exist
- Source blocks must have been tangled WITH `:comments link` (or `yes`/`noweb`)
- Without these comments, detangle has nothing to navigate by

### 3.2 Cannot create Org files from scratch
- It is purely a "sync changes back" mechanism
- It cannot infer Org structure, headings, prose, or block metadata from
  a plain source file

### 3.3 Noweb references are deeply broken
- When using `:comments noweb`, nested noweb blocks create nested
  begin/end comment pairs
- The outer block's "ends here" marker wraps inner blocks' markers
- `org-babel-detangle` gets confused by the nesting and reports
  "Not in tangled code"
- Even when it partially works, detangling can lose the noweb reference
  structure — the expanded code replaces the `<<reference>>` syntax
- This has been a known bug since at least 2018, described by developers
  as needing "a complete rewrite"

### 3.4 Link resolution is fragile
- Uses `org-store-link` / `org-link-open-from-string` to navigate back
- Headline-based links break if headings are renamed or duplicated
- Relative file links (the default!) cause path doubling bugs
  (e.g., `home/user/home/user/...`)
- Setting `org-babel-tangle-use-relative-file-links` to nil is
  practically required
- Using `org-id-link-to-org-use-id` set to `t` (UUID-based links)
  is recommended but not the default

### 3.5 One block at a time internally
- The loop processes blocks sequentially by scanning for link comments
- If a link can't be resolved, that block is silently skipped
- No batch error reporting

### 3.6 Cursor position matters
- `org-babel-tangle-jump-to-org` requires the cursor to be on the code
  body, NOT on the comment lines
- This is an ergonomic issue for interactive use, but in `org-babel-detangle`
  the cursor positioning is handled by the scanning loop

### 3.7 No support for structural changes
- Cannot handle blocks being added, removed, or reordered in the tangled file
- Only updates the body content of blocks that match existing link comments
- If you add a new function in the tangled file, detangle cannot create a
  new source block for it in the Org file

### 3.8 Single file only
- Operates on one tangled file at a time
- No concept of detangling a directory tree

## 4. Comparison to Our Need

**Our need**: Take a directory tree of source files and produce an Org file
that, when run through `org-babel-tangle`, reproduces that directory tree.

### What detangle provides vs. what we need

| Capability | org-babel-detangle | What we need |
|---|---|---|
| Direction | Source -> existing Org (update) | Source -> new Org (create) |
| Org file must exist | YES | NO — we create it |
| Link comments required | YES | N/A — source files are plain |
| Creates headings/structure | NO | YES |
| Handles directory trees | NO (single file) | YES |
| Handles multiple languages | Only what's already in Org | YES — infer from extensions |
| Preserves prose/docs | N/A (only touches code blocks) | N/A (no prose to preserve) |
| Round-trips through tangle | N/A | YES — primary requirement |
| Noweb support | Broken | Not required initially |

### Conclusion

**`org-babel-detangle` is fundamentally the wrong tool for our use case.** It is
designed for a narrow workflow: tangle with link comments, edit source, sync
changes back. It:

1. Cannot create Org files — only updates existing ones
2. Requires link comments embedded in source files — we have plain source files
3. Operates on single files — we need directory trees
4. Has well-documented bugs with noweb, link resolution, and relative paths

What we need is essentially the **inverse of tangle**: a tool that reads a file
tree and *generates* an Org file with appropriate headings, `:tangle` paths,
and source blocks such that `org-babel-tangle` reproduces the original tree.
This is a distinct problem that org-babel-detangle was never designed to solve.

## Sources

- [Org Manual: Extracting Source Code](https://orgmode.org/manual/Extracting-Source-Code.html)
- [ob-tangle.el source (emacs-mirror)](https://raw.githubusercontent.com/emacs-mirror/emacs/master/lisp/org/ob-tangle.el)
- [Eric Schulte's original announcement (2010)](https://emacs-orgmode.gnu.narkive.com/rEubpzsZ/orgmode-babel-detangle)
- [Detangle not working (2014)](https://lists.gnu.org/archive/html/emacs-orgmode/2014-11/msg00079.html)
- [Detangle subtree bug (2016)](https://mail.gnu.org/archive/html/emacs-orgmode/2016-08/msg00342.html)
- [Issues with detangle and :comments noweb (2018)](https://lists.gnu.org/archive/html/emacs-orgmode/2018-05/msg00531.html)
- [Reply to noweb issues (2018)](https://lists.gnu.org/archive/html/emacs-orgmode/2018-06/msg00211.html)
- [Emacs online docs: org-babel-detangle](http://doc.endlessparentheses.com/Fun/org-babel-detangle.html)
