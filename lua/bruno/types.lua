---Central LuaCATS type definitions for bruno.nvim.
---
---This module is intentionally runtime-free: it only exists so
---lua-language-server (and other LuaCATS-aware tooling) can resolve the
---annotations used across the plugin.
---@meta

---@alias bruno.Format 'bru'|'yml'

---@alias bruno.AuthMode
---| 'none'
---| 'inherit'
---| 'basic'
---| 'bearer'
---| 'digest'
---| 'ntlm'
---| 'wsse'
---| 'apikey'
---| 'oauth1'
---| 'oauth2'
---| 'awsv4'
---| 'akamai-edgegrid'

---@alias bruno.GrantType
---| 'authorization_code'
---| 'implicit'
---| 'client_credentials'
---| 'password'
---| 'device_code'

---@class bruno.KeyValue
---@field name string
---@field value string
---@field enabled boolean
---@field description? string

---@class bruno.Body
---@field mode string
---@field content? string
---@field entries? bruno.KeyValue[]
---@field file? string

---@class bruno.Script
---@field pre? string
---@field post? string

---@class bruno.Vars
---@field req bruno.KeyValue[]
---@field res bruno.KeyValue[]

---@class bruno.OAuth2AdditionalParam
---@field name string
---@field value string
---@field enabled boolean
---@field send_in 'headers'|'queryparams'|'body'

---@class bruno.OAuth2AdditionalParams
---@field authorization? bruno.OAuth2AdditionalParam[]
---@field token? bruno.OAuth2AdditionalParam[]
---@field refresh? bruno.OAuth2AdditionalParam[]

---@class bruno.OAuth2Config
---@field grant_type bruno.GrantType
---@field client_id? string
---@field client_secret? string
---@field username? string
---@field password? string
---@field authorization_url? string
---@field access_token_url? string
---@field refresh_token_url? string
---@field callback_url? string
---@field scope? string
---@field state? string
---@field pkce? boolean
---@field credentials_placement? 'basic_auth_header'|'body'
---@field credentials_id? string
---@field token_source? 'access_token'|'id_token'
---@field token_placement? 'header'|'url'
---@field token_header_prefix? string
---@field token_query_key? string
---@field auto_fetch_token? boolean
---@field auto_refresh_token? boolean
---@field additional_params? bruno.OAuth2AdditionalParams

---@class bruno.Auth
---@field mode bruno.AuthMode
---@field config? table
---@field source? string

---@class bruno.Request
---@field path string
---@field relpath string
---@field root string
---@field format bruno.Format
---@field name string
---@field type string
---@field method string
---@field url string
---@field params bruno.KeyValue[]
---@field path_params bruno.KeyValue[]
---@field headers bruno.KeyValue[]
---@field body bruno.Body
---@field auth bruno.Auth
---@field script bruno.Script
---@field tests? string
---@field docs? string
---@field assertions? table[]
---@field vars bruno.Vars
---@field raw string

---@class bruno.RequestSummary
---@field path string
---@field relpath string
---@field root string
---@field format bruno.Format
---@field name string
---@field method string
---@field url string
---@field type string

---@class bruno.Collection
---@field root string
---@field name string
---@field format bruno.Format
---@field config_path string
---@field env_dir? string

---@class bruno.Detection
---@field cwd string
---@field root? string
---@field roots string[]
---@field source 'upward'|'downward'|'none'
---@field cached boolean
---@field scanned_at integer

---@class bruno.Token
---@field access_token? string
---@field refresh_token? string
---@field id_token? string
---@field token_type? string
---@field scope? string
---@field expires_in? number
---@field expires_at? number
---@field obtained_at? number
---@field extra? table

---@class bruno.TestResult
---@field description string
---@field status 'pass'|'fail'|'error'|'skipped'|string
---@field uid? string
---@field error? string
---@field isScriptError? boolean

---@class bruno.AssertionResult
---@field lhsExpr? string
---@field operator? string
---@field rhsExpr? string
---@field status 'pass'|'fail'|'error'|'skipped'|string
---@field error? string

---@class bruno.Result
---@field name? string
---@field path? string
---@field filename? string
---@field request? table
---@field response? table
---@field error? string
---@field status? string
---@field assertionResults? bruno.AssertionResult[]
---@field testResults? bruno.TestResult[]
---@field preRequestTestResults? bruno.TestResult[]
---@field postResponseTestResults? bruno.TestResult[]
---@field runDuration? number

---@class bruno.RunResult
---@field request bruno.Request
---@field raw string
---@field data table
---@field results bruno.Result[]
---@field summary? table
---@field stdout string
---@field stderr string
---@field code integer
---@field env? string
---@field command? string[]

---@class bruno.OAuth2Options
---@field enabled boolean
---@field cache boolean
---@field open_browser boolean
---@field browser_cmd? string|string[]
---@field callback_timeout number
---@field default_callback_url string
---@field token_timeout number
---@field refresh_leeway number

---@class bruno.UIKeymaps
---@field next_tab string|false
---@field prev_tab string|false
---@field next_request string|false
---@field prev_request string|false
---@field next_response string|false
---@field prev_response string|false
---@field tab_1 string|false
---@field tab_2 string|false
---@field tab_3 string|false
---@field tab_4 string|false
---@field tab_5 string|false
---@field tab_6 string|false
---@field tab_7 string|false
---@field tab_8 string|false
---@field run string|false
---@field replay string|false
---@field edit_source string|false
---@field env string|false
---@field requests string|false
---@field auth string|false
---@field auth_clear string|false
---@field copy_curl string|false
---@field yank_body string|false
---@field yank_raw string|false
---@field help string|false
---@field close string|false
---@field hover string|false
---@field select_tab string|false

---@class bruno.UIConfig
---@field split 'right'|'left'|'bottom'
---@field width number
---@field height number
---@field auto_open boolean
---@field default_tab string
---@field tabs string[]
---@field keymaps bruno.UIKeymaps

---@class bruno.Config
---@field cli string
---@field default_env? string
---@field cli_args string[]
---@field timeout number
---@field notify boolean
---@field log_level 'debug'|'info'|'warn'|'error'|'off'
---@field ui bruno.UIConfig
---@field oauth2 bruno.OAuth2Options

---@class bruno.UIState
---@field request? bruno.Request
---@field result? bruno.RunResult
---@field tab string
---@field running boolean
---@field error? string

---@class bruno.PickerItem
---@field label string
---@field value string

return {}
