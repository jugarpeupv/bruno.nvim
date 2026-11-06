# bruno.nvim

A Neovim client for [Bruno](https://www.usebruno.com/) collections.

It runs requests with the official `bru` CLI, reads both legacy `.bru` files and
the newer OpenCollection `.yml` format, and shows the result in a single,
tabbed workbench buffer inspired by Bruno Desktop and
[kulala.nvim](https://github.com/dont-be-evil-company/kulala.nvim).

The headline feature is **OAuth2 support for flows that the Bruno CLI does not
implement yet**, including the browser-based authorization-code flow with PKCE
and a loopback callback server — the same approach used by the Bruno Desktop
app.

## Features

- Run `.bru` and OpenCollection `.yml` requests through `bru run`.
- Treesitter injection so `scripts[].code` blocks in OpenCollection `.yml`
  files are highlighted as JavaScript instead of a plain string.
- Automatic collection detection from the current working directory, cached per
  `cwd`.
- Automatic environment selection when a collection has exactly one
  environment.
- Tabbed response workbench: **Request**, **Body**, **Headers**, **Tests**,
  **Timeline** and **Raw**.
- Request and environment pickers with no mandatory picker dependency.
- Environment switching per collection and a statusline API for lualine or
  other statusline plugins.
- Markdown workbench (`render-markdown.nvim` compatible) with foldable sections
  and `(` / `)` navigation between requests.
- OAuth2:
  - Authorization Code with PKCE (S256).
  - Implicit flow.
  - Client Credentials.
  - Resource Owner Password.
  - Automatic token caching (mode `0600`) and refresh.
  - Loopback callback server (`http://127.0.0.1:<port>/callback`).
  - Manual fallback for non-loopback redirect URIs.
- Token injection without modifying the original collection: a temporary copy
  of the request is generated and deleted after the run.
- Copy the request as a cURL command.
- Request/result events and a small Lua API for integrations.
- LuaCATS annotations throughout, so `lua-language-server` provides
  completion and type checking while editing the plugin.

## Requirements

- Neovim **0.10+** (developed and tested on 0.12).
- [Bruno CLI](https://docs.usebruno.com/bru-cli/overview) **4.x**:
  ```sh
  npm install -g @usebruno/cli
  ```
- `curl` for OAuth2 token requests (already present on macOS and most Linux
  distributions).

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'jugarpeupv/bruno.nvim',
  ft = { 'bruno' },
  opts = {},
}
```

## Configuration

```lua
require('bruno').setup({
  -- Bruno CLI executable.
  cli = 'bru',

  -- Environment used when the collection has no explicit selection.
  -- When unset and the collection has exactly one environment, that
  -- environment is selected automatically.
  default_env = nil,

  -- Extra arguments appended to every `bru run` invocation.
  cli_args = {},

  -- Kill the CLI after this many milliseconds. 0 disables the timeout.
  timeout = 0,

  -- Show notifications for runs and auth events.
  notify = true,

  -- debug | info | warn | error | off
  log_level = 'warn',

  ui = {
    -- right = split to the right of the current window (not at the far right)
    -- left | bottom also available
    split = 'right',
    width = 0.45,
    height = 0.35,

    -- Open the workbench automatically when a request starts.
    auto_open = true,

    default_tab = 'request',
    tabs = { 'request', 'body', 'headers', 'tests', 'scripts', 'timeline', 'raw', 'verbose' },

    -- Set any value to false to disable that keymap.
    keymaps = {
      next_tab = '<Tab>',
      prev_tab = '<S-Tab>',
      next_response = ')',
      prev_response = '(',
      tab_1 = '1',
      tab_2 = '2',
      tab_3 = '3',
      tab_4 = '4',
      tab_5 = '5',
      tab_6 = '6',
      tab_7 = '7',
      tab_8 = '8',
      replay = 'R',
      edit_source = 'ge',
      env = 'gE',
      requests = 'gp',
      auth = 'ga',
      auth_clear = 'gA',
      copy_curl = 'C',
      yank_body = 'cb',
      yank_raw = 'cr',
      help = '?',
      close = 'q',
      hover = 'K',
      select_tab = '<CR>',
    },
  },

  oauth2 = {
    enabled = true,
    cache = true,
    open_browser = true,

    -- Override the browser launcher. String or list. The authorization URL is
    -- appended as the last argument.
    browser_cmd = nil,

    -- How long to wait for the browser callback (ms).
    callback_timeout = 120000,

    -- Used when a request does not define a callback URL. Register this URI in
    -- your OAuth2 provider before using it.
    default_callback_url = 'http://127.0.0.1:53682/callback',

    -- Token endpoint request timeout (ms).
    token_timeout = 30000,

    -- Refresh tokens this many seconds before they expire.
    refresh_leeway = 60,
  },
})
```

## Collection detection

There is nothing to configure. The plugin looks up the collection from the
current working directory:

1. If `cwd` is inside a collection, the nearest ancestor containing
   `bruno.json` or `opencollection.yml` wins.
2. Otherwise the directory is scanned recursively (breadth-first, shallow
   first) looking for collection roots.
3. In both cases the result is cached per `cwd`, so repeated runs, pickers and
   statusline calls do not rescan the filesystem.

The recursive scan skips common dependency/build folders such as `node_modules`,
`.git`, `target`, `dist`, `build`, `vendor` and hidden directories.

Use:

```vim
:BrunoDetect
```

to print the detected directory, collection name, format, environments and the
selected environment. Append `!` to invalidate the cache and scan again:

```vim
:BrunoDetect!
```

When several collections are found under `cwd`, the first one (shallowest,
then alphabetical) is the primary collection; `:BrunoRequests` lists requests
from all of them with a collection prefix.

## Environments

Environment selection is per collection and lives in memory:

- If you selected an environment explicitly, it is kept.
- Else, `default_env` is used when it exists in the collection.
- Else, if the collection defines exactly one environment, it is selected
  automatically and a notification prints the selection.
- Else the request runs with Bruno's default environment.

The selected environment is shown in the workbench metadata line, for example
`Request: 2/3 · Selected env: dev`, and in the Request tab.

### lualine / statusline integration

```lua
require('lualine').setup({
  sections = {
    lualine_x = {
      function()
        local env = require('bruno').current_environment()
        return env and ('bruno:' .. env) or ''
      end,
    },
  },
})
```

Other useful API calls:

```lua
local bruno = require('bruno')

bruno.current_environment() -- "local" | nil
bruno.current_collection()  -- { name, root, format, ... } | nil
bruno.status()              -- { collection = ..., root = ..., environment = ... }
bruno.detect_collection()   -- { root, roots, source, cached, cwd }
bruno.refresh_detection()   -- forces a fresh scan
```

## Commands

| Command | Description |
|---|---|
| `:Bruno` / `:BrunoOpen` | Open the workbench for the current/last request. |
| `:BrunoToggle` | Focus the workbench if visible, close it if focused, open it otherwise. |
| `:BrunoDetect[!]` | Print detection info; `!` refreshes the `cwd` cache. |
| `:BrunoRun [file]` | Run the current request, or an explicit file. |
| `:BrunoReplay` | Re-run the last request. |
| `:BrunoCancel` | Kill the running CLI process. |
| `:BrunoEnv [name]` | Select (or directly switch to) an environment. |
| `:BrunoRequests` | Pick a request from the detected collection(s). |
| `:BrunoSearch` | Compatibility alias for `:BrunoRequests`. |
| `:BrunoInspect` | Open the workbench on the Request tab. |
| `:BrunoToggleView` | Cycle workbench tabs. |
| `:BrunoStats` | Open the workbench on the Timeline tab. |
| `:BrunoAuth [login\|clear\|status]` | Acquire, clear or inspect the OAuth2 token. |
| `:BrunoAuthClear` | Clear the cached token for the current request. |
| `:BrunoClearTokens` | Remove every cached OAuth2 token. |
| `:BrunoAuthStatus` | Show OAuth2 cache status. |
| `:BrunoCopy` / `:BrunoCopyCurl` | Copy the request as cURL. |
| `:BrunoTab [name\|index]` | Select a workbench tab. |
| `:BrunoClose` | Close the workbench window. |

## Workbench keymaps

The workbench buffer layout is:

```text
Request  Body  Headers  Tests  Scripts  Timeline  Raw  [Verbose]
GET  http://127.0.0.1:8765/archetypes
200 OK  ·  1498 ms  ·  15.7 KiB
Request: 2/3 · Selected env: dev
```

The URL in the second line is resolved with the selected environment. The status
line (status, duration, size) and the execution-history line each get their own
line. The winbar is not used. Manually opening the workbench shows
`Request: 1/1`; every run (including replay) appends a new entry and selects it
(`2/2`, `3/3`, …). When `auto_open` opens the workbench for the first run, no
extra placeholder is added, so that first run is `1/1`. `(` / `)` move back and
forward through previous executions without running anything, staying on
whichever tab you are currently viewing.

With `ui.split = 'right'` (the default) it opens as a normal vertical split
adjacent to the current window, not pinned to the far right.

`ui.default_tab` controls the pane shown the first time the workbench is
opened. After that, the workbench always stays on whichever tab you are
currently viewing — including when a run finishes or when re-running (`R`).
The last selected tab is remembered while the buffer is alive, so closing and
toggling the workbench reopens it on the same tab.

The buffer keeps `filetype=bruno_ui`, but it is treated as Markdown:
Treesitter maps `bruno_ui` to the `markdown` parser and Markdown syntax is used
as fallback. If you use `render-markdown.nvim`, add `bruno_ui` to its own `ft`
and `file_types` configuration to render the workbench. Sections
are Markdown headings (`## ...`); use `za` on a heading to fold its section.

The Body pane wraps the response payload in a fenced code block (JSON, XML,
HTML or text based on the content type), and the Raw pane wraps the CLI JSON in
a `json` fence, so syntax highlighting is enabled. The Scripts pane groups the
pre-request, after-response and tests scripts with their code, console output
and script test results; the Verbose pane shows the executed `bru run` command
and the raw CLI stdout/stderr. A `logs` tab is still available if you add it to
`ui.tabs`; it shows the in-memory plugin log and refreshes live as messages are
appended.

Press `K` with the cursor over a `{{VARIABLE}}` to show its resolved value in a
floating window. Press `K` again to focus the hover window; `q`, `Esc` or `K`
inside it closes it.

All keymaps are buffer-local to the workbench and configurable in
`ui.keymaps`.

| Key | Action |
|---|---|
| `<Tab>` / `<S-Tab>` | Next / previous tab |
| `)` / `(` | Next / previous execution in the history |
| `}` / `{` | Next / previous request in the collection |
| `<CR>` on the tab bar | Open the tab under the cursor |
| `1` … `8` | Jump to a tab |
| `R` | Run the current request |
| `r` | Replay the last request |
| `e` | Edit the request source |
| `ge` | Pick an environment |
| `p` | Pick a request |
| `a` | Acquire/login an OAuth2 token |
| `A` | Clear the cached OAuth2 token |
| `c` | Copy as cURL |
| `y` | Yank the response body |
| `Y` | Yank the raw result |
| `K` | Inspect the `{{variable}}` under the cursor |
| `?` / `g?` | Help |
| `q` | Close the workbench |

The plugin also exposes `<Plug>(bruno-run)`, `<Plug>(bruno-open)` and
`<Plug>(bruno-requests)` for your own mappings.

## OAuth2

### How it works

1. The plugin resolves the effective auth for a request. It supports
   request-level auth and `auth: inherit` / `type: inherit` inherited from
   folders and the collection root.
2. OAuth2 fields are interpolated with collection, folder, environment and
   request variables (`{{baseUrl}}`, `{{clientId}}`, …).
3. The token cache is checked. Expired tokens are refreshed when
   `auto_refresh_token` is enabled and a refresh token exists.
4. For `authorization_code`:
   - a loopback HTTP server is started on the callback URL port;
   - the authorization URL is opened in your default browser (or
     `oauth2.browser_cmd`);
   - the provider redirects to the local server with `?code=…&state=…`;
   - the code is exchanged at the token endpoint, using PKCE when enabled;
   - the token is cached under `stdpath('cache')/bruno.nvim/oauth2.json` with
     mode `0600`.
5. The request is copied to a hidden sibling file. Its auth is replaced with
   `none`, the access token is injected as an `Authorization` header (or a URL
   query parameter), the copy is run with `bru run`, and the copy is deleted.
6. The original request file is never modified.

If the callback URI is not a loopback HTTP URL (or the local port cannot be
bound), the plugin opens the browser and asks you to paste the final redirected
URL. This also works for custom URI schemes and remote callbacks. If the
callback URL is empty or still contains an unresolved `{{...}}` template, the
plugin falls back to `oauth2.default_callback_url` so it can start the loopback
server instead of prompting.

To force a full re-authentication, clear the token cache with
`:BrunoClearTokens` (every token) or `:BrunoAuthClear` / `:BrunoAuth clear`
(current request), then run the request again.

### `.bru` example

```bru
meta {
  name: Protected Request
  type: http
  seq: 1
}

get {
  url: {{baseUrl}}/protected
  body: none
  auth: oauth2
}

auth:oauth2 {
  grant_type: authorization_code
  callback_url: http://127.0.0.1:53682/callback
  authorization_url: https://id.example.com/authorize
  access_token_url: https://id.example.com/token
  refresh_token_url: https://id.example.com/token
  client_id: {{clientId}}
  client_secret: {{clientSecret}}
  scope: openid profile
  pkce: true
  credentials_placement: body
  credentials_id: my-provider
  token_source: access_token
  token_placement: header
  token_header_prefix: Bearer
  auto_fetch_token: true
  auto_refresh_token: true
}
```

### OpenCollection `.yml` example

```yaml
info:
  name: Protected Request
  type: http
  seq: 1
http:
  method: GET
  url: "{{baseUrl}}/protected"
  auth:
    type: oauth2
    flow: authorization_code
    authorizationUrl: https://id.example.com/authorize
    accessTokenUrl: https://id.example.com/token
    refreshTokenUrl: https://id.example.com/token
    callbackUrl: http://127.0.0.1:53682/callback
    credentials:
      clientId: "{{clientId}}"
      clientSecret: "{{clientSecret}}"
      placement: body
    scope: openid profile
    pkce: {}
    tokenConfig:
      id: my-provider
      source: access_token
      placement:
        header: Bearer
    settings:
      autoFetchToken: true
      autoRefreshToken: true
```

### Supported grants

| Grant | Supported |
|---|---|
| Authorization Code + PKCE | ✅ |
| Implicit | ✅ |
| Client Credentials | ✅ |
| Resource Owner Password | ✅ |
| Device Authorization | ❌ (not implemented yet) |

### Token cache

Tokens are stored in:

```
vim.fn.stdpath('cache') .. '/bruno.nvim/oauth2.json'
```

The cache key is derived from the collection root, environment name,
`credentialsId`, `clientId` and token URL, so different environments/providers
do not collide. Use `:BrunoAuth clear` (or `:BrunoAuthClear`) to delete a token, or
`:BrunoClearTokens` to remove the whole cache and force a full re-login.

### Security notes

- The token cache is written with mode `0600`.
- Temporary authenticated requests are written next to the original request
  with mode `0600` and deleted as soon as the CLI exits.
- The `client_secret` is sent to the token endpoint through curl's stdin; Basic
  authentication headers are passed as curl arguments, like most CLI tools do.
- The workbench never prints access tokens; the Bruno CLI itself redacts the
  `Authorization` header in its JSON output.

## Events

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'BrunoRequestFinished',
  callback = function(event)
    local result = event.data.result
    print('Bruno result:', result and result.code)
  end,
})
```

| Event | Data |
|---|---|
| `BrunoRequestStarted` | `request`, `command` |
| `BrunoRequestFinished` | `request`, `result` or `error` |
| `BrunoAuthStarted` | `grant_type` |
| `BrunoAuthFinished` | `token` or `error` |

## Lua API

```lua
local bruno = require('bruno')

bruno.open({ request = bruno.current_request() })
bruno.run()                 -- current request
bruno.run('/path/to/x.bru') -- explicit request
bruno.replay()
bruno.cancel()
bruno.toggle()              -- focus/close/open the workbench
bruno.next_response()       -- next execution in the workbench history
bruno.prev_response()       -- previous execution in the workbench history
bruno.env('Local')
bruno.pick_request()        -- picks and runs a request
bruno.auth()                -- acquire/login OAuth2
bruno.auth_clear()
bruno.copy_curl()
bruno.tab('headers')

-- Collection / environment integration.
bruno.detect_collection()   -- cached detection for cwd
bruno.refresh_detection()   -- force a fresh scan
bruno.current_collection()
bruno.current_environment()
bruno.get_env()             -- alias of current_environment()
bruno.status()
```

## File formats and limitations

- `.bru` requests and OpenCollection `.yml` requests are supported.
- Environments are read from `environments/*.bru` and `environments/*.yml`.
- Request/folder/collection variables are interpolated for display and OAuth2
  configuration.
- Requests are executed by the official CLI, so Bruno scripts, tests,
  assertions, cookies, proxies, client certificates and every other `bru run`
  feature keep working.
- The workbench is intentionally line-based (like kulala.nvim) instead of
  trying to reproduce the full Bruno Desktop GUI. Request editing still happens
  in the source `.bru`/`.yml` file.
- GraphQL bodies are displayed, but the dedicated GraphQL UI is not implemented.
- Device Authorization is not supported yet.
- Collection detection is cached per `cwd`; run `:BrunoDetect!` after creating or
  moving a collection in the same working directory. The request list used by
  `{` / `}` is refreshed by the same command and by `:BrunoRequests`.

## Development

```sh
make test        # headless test suite
make fmt         # stylua
make fmt-check   # stylua --check
make check       # lua-language-server type check
```

The tests cover the `.bru`/YAML parsers, collection detection and its `cwd`
cache, environment auto-selection, OAuth2 PKCE, token storage, request
injection, the loopback server, the full authorization code exchange through a
mock provider, the CLI output normalization and the workbench rendering.

## Credits

- [Bruno](https://www.usebruno.com/) and the `bru` CLI.
- [SugarHashira/bruno.nvim](https://github.com/SugarHashira/bruno.nvim) for the
  original Bruno runner and collection/environment discovery ideas.
- [kulala.nvim](https://github.com/dont-be-evil-company/kulala.nvim) for the
  workbench UX inspiration.
- [romek-codes/bruno.nvim](https://github.com/romek-codes/bruno.nvim) for the
  earliest Bruno Neovim integration.

## License

MIT. See [LICENSE](LICENSE).
