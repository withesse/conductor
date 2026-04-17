# Changelog

All notable changes to Expero Agents are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to Semantic Versioning.

## [Unreleased]

## [1.0.0] — 2026-04-17

Initial public release.

### Added
- `SPEC.md` — full framework specification (10 sections, 5 core
  abstractions, 8 roles, 8 scenarios, implementation status matrix)
- `README.md` — methodology overview, quick start, mixing examples
- `expero.sh` — CLI bootstrap: `init`, `start`, `status`, `restart`, `help`
- Multi-tool support in `expero.sh start`:
  - claude (Claude 4.7 / 4.6 / 4.5)
  - codex (OpenAI GPT-5.4 / 5.4-pro / 5.4-mini)
  - gemini (Gemini 3.1 Pro / 3 Flash / 3.1 Flash-Lite)
- Role-to-tier mapping (Reasoning / Execution / Template) applied
  consistently across all three providers
- `test-expero.sh` — regression test suite (156 assertions across 9
  groups, including heredoc-leak and template-stub regression guards)
- `ROADMAP.md` — v1.1 doc cleanup, v1.2 ecosystem integration (Skills,
  MCP), v2.0 structural enforcement (JSON stop signals, gate executor,
  schema validator, subagent-based scheduler), explicit non-goals
- Eight scenario templates: `new-product`, `migration`, `refactor`,
  `legacy-analysis`, `security-audit`, `tech-docs`, `multi-service`,
  `greenfield-library`
- `examples/demo-new-product/` — snapshot of a default `new-product`
  init output
- Generated `CLAUDE.md` ships with concrete starter content (stack /
  build commands / architecture-rule placeholders) instead of bare
  `<!-- Fill in -->` comments
- Generated `AGENTS.md` includes an 8-row Role Quick Reference table
  (Owns / Reads / Never) and a Stop Signal Syntax section for non-Claude
  tools (Codex, Gemini CLI, Aider, etc.)
- `LICENSE` — CC0 1.0 Universal Public Domain Dedication

[Unreleased]: https://github.com/withesse/expero-agents/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/withesse/expero-agents/releases/tag/v1.0.0
