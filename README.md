# neotest-bashunit

A [neotest](https://github.com/nvim-neotest/neotest) adapter for
[bashunit](https://github.com/TypedDevs/bashunit) test files.

Most bash test runners give you the whole file or nothing. This adapter gives you the parts that are
worth having. The output window shows the one test you asked about, not the run it happened to be part
of. A failing test jumps to the line that failed: bashunit's structured report carries no line number,
so the adapter reads the assertion listing out of the run's own output. When bashunit names exactly one
assertion the jump lands on it. When it lists several, the jump goes to the test's own line and the
message says why, rather than pointing at an assertion that passed. And you can run one test by name,
with its siblings excluded, instead of its whole file.

## Requirements

- Neovim 0.10 or newer, which is where `vim.fs.root` arrived. Developed and tested on 0.12.5.
- [neotest](https://github.com/nvim-neotest/neotest).
- `bashunit` on your `PATH`.

The adapter was measured against bashunit 0.50.1. Every rule about bashunit's output shapes is
recorded in `lua/neotest-bashunit/parse.lua` and pinned by frozen fixtures under `tests/`, with the
release named in `M.verified_version`. A bashunit that changed an output shape would leave those fixtures
green while the adapter misreported real runs, so `:checkhealth neotest-bashunit` warns when the
installed release is not the one the fixtures came from.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim), as a dependency of neotest:

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    "nvim-neotest/nvim-nio",
    "webdavis/neotest-bashunit",
  },
  config = function()
    require("neotest").setup({
      adapters = {
        require("neotest-bashunit"),
      },
    })
  end,
}
```

The adapter is a plain table. It has no `setup` function and nothing to call: `require` it and put
it in the list.

## Which files it finds

A test file is one whose name ends in `.test.sh`. Inside it, a test is any function named `test_`
plus at least one more character, written with or without the `function` keyword.

That rule mirrors what bashunit itself runs at runtime rather than the grep it uses for line
lookups. The grep matches `testCamel` and `testable`, which bashunit never runs, and misses
`test_éclair`, which it runs and titles "éclair".

## Which directories it claims

A directory belongs to this adapter when the nearest ancestor holding a `.bashunitrc` or a `.git`
either:

- holds a `.bashunitrc`, which is an explicit opt-in and is taken at its word, with or without any
  test files; or
- has at least one `*.test.sh` reachable inside it.

The second rule is there because `.git` sits at the top of every repository, so claiming on the
marker alone would attach the adapter to all of them. neotest hands a whole-directory
run to the single adapter that claimed the directory, so a project with no bash in it would run its
"all tests" here and find nothing.

The search for a test file prunes `.git`, `.bashunit`, `node_modules`, `target` and `fixtures`, and
stops at the first match.

## How a run is built

One bashunit process per file. Running a single test passes `--filter` with that test's name, and
then names every sibling the filter would also drag in as an `--exclude-filter`, because `--filter`
is a substring match rather than a regular expression: `--filter test_alpha` on its own also runs
`test_alpha_extended` and `test_beta_alpha`.

Color is disabled with `NO_COLOR`, not `--no-color`, which is ignored in either position on 0.50.1.

## Two tests with the same title

bashunit titles a test by transforming its function name, and its report names tests by that title
alone. `test_dupe` and `test_Dupe` both become "Dupe", so neither report row can be attributed to a
function. Both positions are failed with the collision named, rather than one silently taking the
other's verdict.

## Health

```vim
:checkhealth neotest-bashunit
```

Reports whether bashunit is on `PATH`, which release it is, and whether that matches the release
the adapter's fixtures were measured against.

## Tests

The tests are pure functions over strings and tables. They run under a bare headless Neovim with
nothing else installed:

```sh
nvim --headless --clean -l tests/run.lua
```

Pass a spec name to narrow the run, for example `nvim --headless --clean -l tests/run.lua
root_spec`.

## License

MIT. See `LICENSE`.
