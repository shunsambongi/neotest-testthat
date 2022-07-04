# neotest-testthat

[Neotest](https://github.com/nvim-neotest/neotest) adapter for R packages using [testthat](https://testthat.r-lib.org/) tests.

Requires [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) and the parser for R.

```lua
require('neotest').setup {
  adapters = {
    require('neotest-testthat')
  }
}
```
