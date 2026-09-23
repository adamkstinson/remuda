# Vendored skills

Copied into this repository so the coding agent and anyone running Pi here load the same skills.

- [obra/superpowers](https://github.com/obra/superpowers) at `5bf4e78`: `test-driven-development`, `systematic-debugging`, `verification-before-completion`, `receiving-code-review`. MIT, copyright Jesse Vincent. `LICENSE` in each skill directory.
- `pull-request` is ours, adapted from `yeet` and `gh-fix-ci` in [openai/skills](https://github.com/openai/skills) (Apache-2.0).

Local changes: `disable-model-invocation` is removed so the model sees each skill, and `superpowers:` prefixes are dropped from skill names.
