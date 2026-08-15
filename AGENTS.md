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
- Current local release-candidate runtime: `v1.0-alpha.9` (not published before the physical x86 gate).
- Current hybrid ISO: `output/openwrt-x86-64-installer-hybrid.iso`.
- Current ISO SHA-256 is the pre-candidate development artifact `62653cac2fc7f22f51d48f1a813be45a462d385e3846d2eb2a18bbf585357e21`; replace it after the clean candidate rebuild.
- Older alpha release tags are preserved; do not move them.

## Semantic Navigation With LSP MCP

- For definitions, references, call hierarchy, type-aware navigation, and diagnostics, use the `lsp_mcpls` MCP tools first when they are configured for the project.
- Do not present `rg`, `grep`, or other lexical search as semantic proof.
- If `lsp_mcpls` is unavailable or fails, state that explicitly before using lexical search as a fallback.
- LSP MCP is project-scoped: start Codex from the enrolled project root, which must contain one portable `.lsp-mcp.toml` and one trusted project-local `.codex/config.toml`.
- Never use `/home/w0w` as one giant LSP workspace. Projects unsupported by the installed `lsp-mcp` backends must use an explicit lexical fallback.
