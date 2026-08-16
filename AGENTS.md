# Project Instructions

## Project Memory

- Project Memory key: `woffko/openwrt-installer`.
- Project root: `/home/w0w/owrt_installer`.
- Repository: `https://github.com/woffko/openwrt-installer`.
- Use Project Memory for resume/context lookup before repeating release, ISO, QEMU, or GitHub publication work.
- Store only non-secret, verified facts. Do not store tokens, passwords, private keys, or raw credential contents.
- Local continuation notes are in `LOCAL_CONTEXT.md`; this file is ignored by Git and may mention where a credential file is located, but must not contain the token value.

## Current Artifacts

- Current published alpha release: `v1.0-alpha.10`.
- Current development runtime: `v1.0-alpha.12`; it is not frozen or published before the physical SATA/NVMe compatible-layout, two-cycle standard sysupgrade, Safe Upgrade, rescue, and pre-ERASE power-cycle schema 4 gate.
- Current hybrid ISO: `output/openwrt-x86-64-installer-hybrid.iso`.
- Read the current development ISO checksum from `output/sha256sums.txt`; do not treat it as a release candidate until the freeze workflow succeeds.
- Historical `v1.0-alpha.9` candidate metadata remains under `release/`; do not move it.
- Older alpha release tags are preserved; do not move them.

## Semantic Navigation With LSP MCP

- For definitions, references, call hierarchy, type-aware navigation, and diagnostics, use the `lsp_mcpls` MCP tools first when they are configured for the project.
- Do not present `rg`, `grep`, or other lexical search as semantic proof.
- If `lsp_mcpls` is unavailable or fails, state that explicitly before using lexical search as a fallback.
- LSP MCP is project-scoped: start Codex from the enrolled project root, which must contain one portable `.lsp-mcp.toml` and one trusted project-local `.codex/config.toml`.
- Never use `/home/w0w` as one giant LSP workspace. Projects unsupported by the installed `lsp-mcp` backends must use an explicit lexical fallback.
