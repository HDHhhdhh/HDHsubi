---
name: aside-browser
description: Prepare the local Aside CLI and read its current browser automation guide before MathSecr work.
---

# Local Aside setup

Read the workspace `docs/installation.md` for Windows/macOS installation. The browser app and CLI are separate components. Use the recipient's own account and login. A found executable is not proof of browser availability or paper identity.

Before browser work, use the installed CLI's current documentation. Run `aside --host local --update`, `aside --host local guide`, and `aside --host local guide repl`. Follow the returned API documentation. Do not invent APIs from old project examples. If update or guide access fails, record the error and use the official Developer setup instructions; do not guess a retired API.

Inspect existing tabs before opening a new one. Attach the relevant MathSecr tab and verify its URL, title and login. The primary agent owns live UI actions. Follow the workspace AGENTS and mathsecr-paper-builder skill for scope, selection, persistence and reporting. Do not use an alternate browser surface or remote host to bypass a failed local session. Do not click `출제하기` without an explicit user request.
