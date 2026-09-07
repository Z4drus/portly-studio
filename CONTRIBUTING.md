# Contributing to Portly Studio

Thanks for helping make local development calmer and more predictable.

## Before you start

- Search existing issues before opening a new one.
- For substantial changes, open a discussion or issue before writing code.
- Keep changes focused. Portly Studio is intentionally small and native.
- Never include API keys, tokens, private paths, or real project logs in a report.

## Local development

Portly Studio requires macOS 14 or newer and Swift 6.

```bash
swift build
swift test
./build.sh --no-install   # assembles dist/Portly Custom.app without installing it
```

## Pull requests

1. Create a focused branch.
2. Add or update tests when behavior changes.
3. Run `swift build -c release` and `swift test`.
4. Explain the problem, the chosen solution, and the verification performed.
5. Keep user-facing copy in English.

By contributing, you agree that your contribution is licensed under the MIT License.
