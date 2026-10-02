@echo off
rem MCP wrapper: clear proxy env so Node/undici does not route through cntlm
rem (global NODE_USE_ENV_PROXY=1 + HTTP_PROXY breaks undici -> "fetch failed").
set HTTP_PROXY=
set HTTPS_PROXY=
set http_proxy=
set https_proxy=
set ALL_PROXY=
set all_proxy=
set NODE_USE_ENV_PROXY=
set GLOBAL_AGENT_HTTP_PROXY=
set GLOBAL_AGENT_HTTPS_PROXY=
set GLOBAL_AGENT_NO_PROXY=
set NO_PROXY=*
set no_proxy=*
call "%APPDATA%\npm\hermes-atlas-mcp.cmd" %*
