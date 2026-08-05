# AGENTS.md: dmj engineering conventions for any AI coding agent

One brain, every agent. This is the canonical instruction set for Claude Code, GitHub
Copilot, Continue, Cline / Roo, Cursor, and anything that reads `AGENTS.md`. Mirror it to
each agent's own filename with `agents/setup-agents.sh`: write once, all of them obey.

## Identity and intent
- Work ships under the dmj.one identity. No AI branding on any user-facing surface.
- Build for a slow phone, bad internet, a small town. Works there means works everywhere.
- Accessibility is line one, not a final pass: WCAG 2.2 AAA, keyboard nav, screen-reader
  labels, visible focus, reduced motion, high contrast, captions, alt text. Never trade
  one person's access away for another's.

## How to work
- Orchestrate, do not grind. Decompose, run independent work in parallel, verify, synthesize.
- Smallest end-to-end working version first, then grow in layers. Never trade a working
  product for unfinished complexity.
- Modify what exists before adding new. No duplicate files or functions. Aim for O(1) or the
  best known complexity, or do not ship it.
- Simplest implementation that meets the current requirement. No speculative abstraction,
  config, or indirection. No backward-compat shims unless a real contract needs one.
- Use existing dependencies first. Read the API and types before assuming a library lacks
  something, before adding a package, before reimplementing. Never invent a signature.

## Never guess
- Unsure means say so. No fabrication, no placeholders, no TODO stubs, no "simplified" stand-ins.
- Triple check: it compiles, it runs, it is correct. "Probably" means stop and verify.
  Treat every output as a production deploy and a code review at once.

## Security, from line one, non-negotiable
- Threat-model before code. Zero trust, least privilege. Validate every input.
- Secrets live in env or a vault, never in source or logs. PII is field-level encrypted.
- Passwords: Argon2id, never bcrypt or scrypt. At rest: an audited AEAD (AES-256-GCM is the
  baseline). Prefer hybrid post-quantum for new crypto where it fits; never hand-roll a primitive.
- Respect data-residency and privacy law (DPDP, GDPR). When security conflicts with anything
  else, security wins.

## Tests and quality gates
- Write the failing test first, then the code. No test bypasses, no mocks passed off as fixes.
- Fix the environment, not the code, when something is flaky. Everything is production.
- One-shot fixes: find the root cause, fix it once, prove it with a test.

## Performance and cost
- Know the hot path. No N+1 queries, no accidental O(n^2) over large input. Assert budgets
  where they matter.
- Free-first. Prefer free or scale-to-zero infrastructure. A billable or always-on resource
  is a deliberate, confirmed choice, never a silent default. One deploy target per project,
  Cloudflare in front.

## Product bar
- End-to-end UX or it is not a product. Obsess the last 10 percent. Defaults are the product.
- Errors are product moments. Loading is progress. Onboarding is under 30 seconds or lost.

## Voice, for prose, docs, commits, and UI copy
- No em dashes. Short sentences, plain words. Show the feeling, hide the machinery.
- Ban the AI-tell words: delve, leverage, utilize, streamline, robust, seamless, innovative,
  empower, holistic, synergy, paradigm, comprehensive, and their kin.
- The first five words are the pitch. If removing a word changes nothing, remove it.

## Git and delivery
- Conventional commits. Keep a Changelog, updated in the same commit as the change it describes.
- Reversible means just do it. Destructive or irreversible means confirm first.
- Never push, deploy, or delete beyond your scope without a green test and an explicit go.

## Shared tools across agents (MCP)
- MCP servers carry across Claude, Cline, Continue, and Copilot. See `agents/mcp.json`.
- Register the same servers in each agent so they share tools: current docs lookup, browser
  automation, and whatever else you add. The instruction file above ports the conventions;
  MCP ports the capabilities.
