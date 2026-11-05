.PHONY: test fmt fmt-check check

test:
	nvim --headless -u tests/minimal/init.lua -l tests/run.lua

fmt:
	stylua lua plugin tests ftdetect lazy.lua

fmt-check:
	stylua --check lua plugin tests ftdetect lazy.lua

check:
	lua-language-server --check . --checklevel=Warning
