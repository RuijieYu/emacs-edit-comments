# Edit Comments

This package adds an analogous command of `org-edit-src-code` that is suitable for all major modes.

## Usage

One can enable `edit-comments-mode` or `global-edit-comments-mode` to set a keybind <kbd>C-c '</kbd> for the actual command `edit-comments-start`.  Alternatively run `edit-comments-start` directly or bind this command to an different keybind.

*Note: `global-edit-comments-mode` shadows the <kbd>C-c '</kbd> command for all modes unconditionally, so enable it with caution.*

The behavior of the `edit-comments-start` command can be altered by adding a prefix (<kbd>C-u</kbd>).

Without the prefix, the edit range starts before the first comment character of the first comment in a series, and ends right before the first non-comment character after the comment series.

With the prefix, the edit range does not go beyond any lines consisting of only spaces or newlines.

See this snippet as an example:

```rust
/// LINE  1 <<< Without prefix, edit range starts at line 1 char 1
/// LINE  2     More docstring

/// LINE  4 <<< With prefix, edit range starts at line 4 char 1
///
///
/// LINE  7     Point is in this line
///
/// LINE  9 >>> With prefix, edit range ends at line 10 char 1

/// LINE 11     More docstring
/// LINE 12 >>> Without prefix, edit range ends at line 13 char 1
struct Foo;
```

### Keybinds

The `edit-comments-mode` minor mode introduces the following keybind.

| Keybind          | Description                                  |
|------------------|----------------------------------------------|
| <kbd>C-c '</kbd> | Start editing the comment block around point |

Inside an inferior buffer created by `edit-comments-start`, there are three keybinds in effect, analogous to the keybinds in orgmode code buffer:

| Keybind             | Description                             |
|---------------------|-----------------------------------------|
| <kbd>C-c '</kbd>    | Finish editing, return to parent buffer |
| <kbd>C-c C-k</kbd>  | Abort editing, return to parent buffer  |
| remap `save-buffer` | Write to and save the parent buffer     |

## Caveats

Currently the command only supports line comments occupying entire lines, for example `//` in C/C++ (not block comments like `/* ... */`).  Trailing line comments have not been taken into consideration during initial implementation.

Currently the command does not support mixed comment styles.  In other words, all comments should be the same string.  For example, the following Rust snippet is problematic because some lines use `//` and others use `///`:

```rust
/// Docstring here.
// This is not a docstring, but is still considered part of the comment block,
// and when the edit finishes, they will also be converted into "///" comments.
/// Some other docstring here.
struct Foo;
```

Currently if the comment block is indented, finishing editing will always mark the buffer as modified, because the next line after the comment block is always re-indented.  That applies to the following snippet:

``` rust
struct Foo;
impl Foo {
    /// Dostring here.
    /// This will always be marked as modified.
    /// Because the "pub fn bar()" line has its indentation removed, and
    /// therefore has to re-indent.
    pub fn bar() {}
}
```

In addition, if a save hook for stripping trailing empty lines is installed, this command removes all extraneous empty lines between the comment block and the next non-comment item.  This is unexpected but hasn't yet disrupted my workflow.  See the following example:

``` rust
struct Foo;
impl Foo {
    /// Docstring
    /// More docstring
    /// The next line will be deleted

    pub fn bar() {}
}
```

This effect is not manifested for the prefixed command.

## Planned Features
- Sensibly limit the `fill-column` variable in the inferior buffer.
- If certain minor modes are enabled in the parent buffer, also enable them in the inferior buffer.
  - `auto-fill-mode`?

## Attributions
- [org-mode](https://orgmode.org) for the general idea of indirect editing and some adapted code snippets
