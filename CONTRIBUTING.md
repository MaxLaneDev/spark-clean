# Contributing to SparkClean

Thanks for your interest in contributing to SparkClean!

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Test your changes by building and running the app
5. Commit with a clear message (`git commit -m "feat(scope): description"`)
6. Push to your fork (`git push origin feature/your-feature`)
7. Open a Pull Request

## Commit Message Format

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): description
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`

Scopes: `app`, `ui`, `cleanup`, `uninstaller`, `settings`, `models`, `dashboard`

## Code Style

- Follow existing Swift conventions in the codebase
- Use SwiftUI for all UI components
- Keep functions focused and small
- No external dependencies (pure Swift only)

## Adding a Translation

SparkClean uses `SparkClean/Localizable.xcstrings`, the Xcode String Catalog format.
To contribute a language:

1. Open `SparkClean.xcodeproj` in Xcode.
2. Select `Localizable.xcstrings`, choose **Editor → Add Language**, and select the language.
3. Translate user-facing entries without changing file paths, bundle identifiers,
   command names, or audit-log text.
4. Run the app with that language and check the sidebar, confirmation sheets, and
   Settings at the minimum window size.
5. Submit one language per pull request so native speakers can review it independently.

The source language is English. Priority community translations are Spanish, German,
French, Japanese, Simplified Chinese, and Portuguese.

## Reporting Bugs

Open an [issue](https://github.com/georgekhananaev/spark-clean/issues) with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- macOS version and Mac model

## Feature Requests

Open an [issue](https://github.com/georgekhananaev/spark-clean/issues) with the `enhancement` label describing what you'd like to see and why.

## License

By contributing, you agree that your contributions will be subject to the project's [LICENSE](LICENSE). All contributions are assigned to George Khananaev as described in Section 5 of the license.
