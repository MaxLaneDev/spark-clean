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

Scopes: `app`, `ui`, `cleanup`, `uninstaller`, `settings`, `models`, `dashboard`, `localization`

## Code Style

- Follow existing Swift conventions in the codebase
- Use SwiftUI for all UI components
- Keep functions focused and small
- No external dependencies (pure Swift only)

## Adding a Translation

SparkClean uses `SparkClean/Localizable.xcstrings`, the Xcode String Catalog format. Most
of the included non-English strings were initially produced with AI-assisted translation.
They should be treated as a starting point, not a replacement for review by fluent and
native speakers.

For the complete workflow, testing checklist, and instructions for registering a new
language in the app, see the [Translation Contribution Guide](docs/TRANSLATIONS.md).

Translation corrections are especially welcome, including small changes. You do not
need to review a complete language before contributing. Fixing one awkward label,
technical term, or sentence makes the app better for everyone who uses that language.

### Improve an Existing Translation

1. Open `SparkClean.xcodeproj` in Xcode and select `Localizable.xcstrings`.
2. Find the English source text and update only the language you are correcting.
3. Keep placeholders such as `%1$@` and `%2$lld` unchanged. Keep file paths, bundle
   identifiers, command names, and URLs in their original left-to-right form.
4. If possible, run the app in that language and check the affected screen at the
   minimum window size. Right-to-left corrections should also be checked for layout,
   directional icons, and technical text.
5. Open a pull request describing what was corrected and why. Please keep each pull
   request focused on one language so it can be reviewed clearly.

If you do not use Xcode or Git, you can still help by
[opening an issue](https://github.com/georgekhananaev/spark-clean/issues/new). Include:

- The language.
- The English source text.
- The current translation.
- Your suggested replacement and, if useful, a short explanation or screenshot.

### Add a New Language

To add a language that is not included yet:

1. Open `SparkClean.xcodeproj` in Xcode.
2. Select `Localizable.xcstrings`, choose **Editor → Add Language**, and select the language.
3. Translate user-facing entries without changing placeholders such as `%1$@` or
   `%2$lld`. Keep file paths, bundle identifiers, command names, and URLs in their
   original left-to-right form.
4. Run the app with that language and check the sidebar, confirmation sheets, and
   Settings at the minimum window size. For a right-to-left language, also verify
   navigation order, directional icons, and technical text.
5. Submit one language per pull request so it can be reviewed independently.

The source language is English. Simplified Chinese, Japanese, German, and Hebrew are
included. Priority community translations are Spanish, French, Portuguese, Korean,
Italian, and Traditional Chinese.

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
