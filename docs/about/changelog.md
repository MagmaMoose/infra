# Changelog

<!-- sources: .github/workflows/release.yml, CHANGELOG.md -->

Releases are cut automatically by the Release workflow, using gitversion. Every merge to
`main` that touches something other than documentation produces a tagged release.

**The live changelog is [GitHub Releases](https://github.com/CalebSargeant/infra/releases).**

```bash
gh release list --limit 20
```

```bash
gh release view --web
```

!!! note "`CHANGELOG.md` in the repository root is frozen"
    It stops at v1.76.3 (2026-07-16). The workflow moved to gitversion, which writes release
    notes to the GitHub Release rather than to a file, so nothing has updated it since. Read
    Releases instead. The file is kept for the history it already holds.

Documentation-only merges don't produce a release: `release.yml` ignores `**/*.md`, `docs/**`,
`mkdocs.yml`, `LICENSE`, and `.gitignore`.
