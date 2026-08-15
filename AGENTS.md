# Project Instructions

## Project Memory

- Project Memory key: `woffko/openwrt-installer`.
- Project root: `/home/w0w/owrt_installer`.
- Repository: `https://github.com/woffko/openwrt-installer`.
- Use Project Memory for resume/context lookup before repeating release, ISO, QEMU, or GitHub publication work.
- Store only non-secret, verified facts. Do not store tokens, passwords, private keys, or raw credential contents.
- Local continuation notes are in `LOCAL_CONTEXT.md`; this file is ignored by Git and may mention where a credential file is located, but must not contain the token value.

## Current Artifacts

- Current published alpha release: `v1.0-alpha.7`.
- Current frozen local release candidate: `v1.0-alpha.9`, runtime commit `8e8593c5891ff69f98a9ee3ef5fcdd23444d2b51`, metadata `release/v1.0-alpha.9-candidate.env` (not published before the physical x86 gate).
- Current hybrid ISO: `output/openwrt-x86-64-installer-hybrid.iso`.
- Current candidate ISO SHA-256: `2b570a2e5747b0a9f2cd46c8252059dd64f101d35c0e14c06fdb69402cffd851`.
- Older alpha release tags are preserved; do not move them.

## Semantic Navigation With LSP MCP

- For definitions, references, call hierarchy, type-aware navigation, and diagnostics, use the `lsp_mcpls` MCP tools first when they are configured for the project.
- Do not present `rg`, `grep`, or other lexical search as semantic proof.
- If `lsp_mcpls` is unavailable or fails, state that explicitly before using lexical search as a fallback.
- LSP MCP is project-scoped: start Codex from the enrolled project root, which must contain one portable `.lsp-mcp.toml` and one trusted project-local `.codex/config.toml`.
- Never use `/home/w0w` as one giant LSP workspace. Projects unsupported by the installed `lsp-mcp` backends must use an explicit lexical fallback.
