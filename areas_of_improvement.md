# Improvements

I inspected both: kulala’s README + repo tree, and the installed `bru` 4.3.0 CLI help/source. Here’s the gap analysis, split into “kulala has”, “bru CLI supports but we don’t surface”, and “not feasible”.

## What kulala.nvim has that we don’t

| Area | kulala | bruno.nvim today |
|---|---|---|
| Protocols | HTTP, gRPC, GraphQL, WebSocket, streaming | HTTP + GraphQL-as-body (whatever `bru run` executes) |
| Running | single request, run all, scratchpad, import external `*.http` | single request only |
| Variables | env/document/request/dynamic/prompt vars, `http-client.env.json`, `$kulala.*` defaults | env/request/collection vars + session runtime vars; no dynamic/prompt vars |
| Auth | Basic/Bearer/Digest/NTLM/OAuth2/AWS/Negotiate/SSL auth manager | OAuth2 flows implemented; other modes only display/run via CLI |
| Response UI | body/headers/verbose/script output/stats/report panes, live filtering, response manager, save to file | Request/Response/Tests/Scripts/Raw/Verbose, jq filter, inline images |
| History | persisted session restore, response manager | in-memory execution history only |
| Tooling | LSP completion, inlay status icons, OpenAPI/GraphQL explorers, formatter | none of these |
| Reports | assertions/report pane, test helper APIs | Tests tab only |

## What `bru` CLI supports but we don’t expose yet

These are the highest-value, lowest-risk gaps because the CLI already does the work:

1. **Collection/folder runs**
`bru run <path> -r`, multiple paths, `--tags/--exclude-tags`, `--delay`, `--bail`, `--tests-only`.
Add `:BrunoRunAll` / `:BrunoRunFolder` and a runner view with per-request status. This is the biggest parity gap vs kulala’s “run all”.

2. **Data-driven runs**
`--csv-file-path`, `--json-file-path`, `--iteration-count`, `--parallel`.
Our `normalize_output` already flattens iterations; we could show them grouped per iteration.

3. **CI reporters**
`--reporter-json`, `--reporter-junit`, `--reporter-html`, plus `--reporter-skip-*`.
Add `:BrunoTest --reporter junit:out.xml` and document CI usage.

4. **Security / network options**
`--insecure`, `--cacert`, `--ignore-truststore`, `--client-cert-config`, `--noproxy`, `--cache-ssl-session`.
Currently only reachable via raw `cli_args`; they deserve config fields.

5. **Environment features**
`--env-file`, `--secrets-env-file`, `--global-env`, `--workspace-path`, `--global-env-var`; environment inheritance (`extends`) is resolved by the CLI but not displayed by us.

6. **Prompt variables (`{{?name}}`)**
The CLI *refuses* to run requests containing them. We could detect them, prompt with `vim.ui.input`, and pass values via `--env-var name=value`. That unlocks a whole class of collections.

7. **Import/docs**
`bru import openapi|wsdl` and `bru docs generate` could become `:BrunoImport` and `:BrunoDocs`.

8. **Cookies**
`--disable-cookies`; no cookie-jar UI/clear command in our plugin.

9. **Sandbox/script modules**
`--sandbox developer`, `--experimental-cache-modules` (npm modules in scripts).

## Response/workbench improvements (not CLI-bound)

- Save response body to a file (and copy path); guard very large bodies (`max_response_size`-style).
- Search/filter within the response body (jq exists; add plain text search).
- Persist execution history across sessions (kulala session restore) and allow pinning/comparing responses.
- GraphQL body rendering: split query and variables, pretty-print variables as JSON.
- Multipart/form/file body display details in the Request tab.
- Inlay/status icons for run state, and optional variable completion (`{{...}}`, headers, methods).
- Scratchpad for ad-hoc requests (temp `.bru`/`.yml`).
- Optional OpenAPI explorer: import via `bru import openapi` and browse operations.
- Live/incremental jq filtering instead of full re-render on each render.

## Not feasible via `bru` CLI (would need a different backend)

- **gRPC, WebSocket, streaming**: kulala-core handles them; `bru run` only executes HTTP (the CLI loader knows the types but there is no execution path).
- **Negotiate/SSO auth**: not in the CLI’s auth paths.
- kulala’s licensed `kulala-core` features in general.

## Suggested roadmap

**P0 — parity with “run collection” workflows**
1. Folder/collection runner (`-r`, tags, bail, delay, tests-only) + result list.
2. Data-driven runs (CSV/JSON iterations, parallel) with per-iteration display.
3. JUnit/HTML reporter command for CI.
4. First-class network flags (`insecure`, `cacert`, `client-cert-config`, `noproxy`).

**P1 — collection/environment depth**
5. Prompt-variable support via `--env-var`.
6. Env-file/secrets/global-env/workspace support + `extends` display.
7. Save body to file, size guard, body search.
8. `:BrunoImport` / `:BrunoDocs`.

**P2 — editor experience**
9. Session-persisted history + response manager (pin/compare).
10. GraphQL/OpenAPI panels, LSP completion, inlay status.
11. Cookie-jar UI, scratchpad.

If you want, I can start with the collection runner + reporters, since those give the most workflow value and are purely CLI-supported.

# Todo
