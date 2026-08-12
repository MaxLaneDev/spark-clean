# Translation Contribution Guide

SparkClean is built for people around the world, and clear native-language wording is
an important part of making cleanup actions understandable and safe.

Most of the current non-English strings were initially produced with AI-assisted
translation. They provide broad coverage, but they can still be too literal, use the
wrong technical meaning, or sound unnatural to a native speaker. Community review is
welcome at any size: correcting one button or warning is useful, and no coding
experience is required to suggest a change.

## Choose How You Want to Help

| Contribution | Best option |
| --- | --- |
| Correct one or two strings without using Git | [Open a translation issue](https://github.com/georgekhananaev/spark-clean/issues/new) |
| Improve an existing language | Edit the String Catalog and open a focused pull request |
| Add a new language | Add the catalog localization, register it in the app, update tests, and open a pull request |
| Review an open translation contribution | Read the changed strings in context and leave specific suggestions on the pull request |

## Suggest a Correction Without Xcode or Git

Open a [new GitHub issue](https://github.com/georgekhananaev/spark-clean/issues/new) and
use a title such as:

```text
[Translation] Improve German wording in Settings
```

Include the following information:

```text
Language:
English source text:
Current translation:
Suggested translation:
Where it appears in the app:
Why the change is clearer (optional):
```

A screenshot is helpful when the same English word could have different meanings in
different places. Remove or hide personal file paths before attaching screenshots.

## Prepare a Pull Request

You need a Mac with Xcode 26 or later to run the current project.

1. Fork the repository on GitHub.
2. Clone your fork and create a focused branch:

   ```bash
   git clone https://github.com/YOUR-USERNAME/spark-clean.git
   cd spark-clean
   git switch -c fix/translation-german
   open SparkClean.xcodeproj
   ```

3. Keep one language per branch and pull request. This makes native-language review and
   follow-up changes much easier.

## Improve an Existing Language

1. In Xcode, open `SparkClean/Localizable.xcstrings`.
2. Find the English source string, then edit only the language you are reviewing.
3. Check nearby strings so repeated actions and technical terms use consistent wording.
4. Run SparkClean, choose the language under **Settings → General → App Language**, and
   restart when prompted.
5. Visit the affected screen and verify that the text fits at the minimum window size.
6. Review the diff and remove unrelated String Catalog changes before committing.
7. Open a pull request describing the screen, wording, and reason for the correction.

Small pull requests are encouraged. A focused correction is easier to verify than a
large rewrite covering unrelated parts of the app.

## Add a New Language

Adding a language requires both translated catalog entries and a small amount of app
registration code.

1. Open `SparkClean/Localizable.xcstrings` in Xcode.
2. Choose **Editor → Add Language** and select the new language.
3. Translate every user-facing catalog entry. The localization test requires every
   shipped language to have a non-empty, format-safe translation.
4. Update `AppLanguage` and `AppLocalization` in `SparkClean/Localization.swift`:
   - Add an `AppLanguage` enum case using the correct language identifier.
   - Return its BCP 47 code from `languageCode`.
   - Map saved macOS language identifiers in `fromPreference(_:)`.
   - Update `AppLocalization.layoutDirection(for:)` if the language is right-to-left.
5. Add the language's native name to the App Language picker in
   `SparkClean/SettingsView.swift`.
6. Update the localization expectations in `SparkCleanTests/SparkCleanTests.swift`:
   - The shipped language-code list.
   - Preference mapping and preference-value checks.
   - Left-to-right or right-to-left layout checks.
7. Add the language to the README and include a current screenshot if possible.
8. Run the checks and complete the visual review below.

Script or region variants need extra care. For example, Simplified Chinese (`zh-Hans`)
and Traditional Chinese (`zh-Hant`) share the same base language code. Their preference
mapping must inspect the full normalized identifier before falling back to the base
language.

## Translation Rules

- Translate the meaning in its UI context instead of following the English sentence
  word for word. Reorder, shorten, or rewrite the sentence when that is how a native
  speaker would naturally express the same idea.
- Prefer the terminology used by macOS in that language for Settings, Trash, files,
  storage, permissions, and common controls.
- Keep the voice direct, calm, and conversational. A small touch of humor is welcome in
  onboarding or an empty state, but warnings, confirmations, errors, and recovery text
  should stay plain and precise.
- Avoid stiff marketing language and translated English idioms. Read the result aloud;
  if it does not sound like a native Mac app, rewrite it rather than defending the
  literal translation.
- Keep product names such as SparkClean, Docker, Ollama, Xcode, APFS, and Time Machine
  unchanged unless the product has an established localized name.
- Do not translate file paths, bundle identifiers, URLs, command names, command-line
  arguments, or code examples.
- Preserve placeholders exactly. Examples include `%@`, `%lld`, `%1$@`, `%2$lld`, and
  `%%`. Reordering positional placeholders is allowed only when their identifiers remain
  correct.
- Preserve intentional line breaks and Markdown markers unless the localized sentence
  needs a different break for readability.
- Keep safety language precise. **Safe**, **Review**, and **Caution** describe different
  cleanup risk levels and should not become interchangeable.
- Do not soften destructive warnings or remove information about Trash, permanent
  deletion, administrator approval, running applications, or lost data.
- Use consistent translations for the same action across the dashboard, confirmation
  sheets, menus, and Settings.

## Visual Review Checklist

Test the language at SparkClean's minimum window size and check:

- Onboarding and the ready-to-scan dashboard.
- Every sidebar category and tool name.
- Category-specific Scan buttons.
- Safety labels and cleanup confirmation sheets.
- App Uninstaller and Duplicate Finder controls.
- Maintenance, Startup Items, Time Machine, Disk Map, and Storage Insights.
- Every Settings tab, including the language and threshold controls.
- Dynamic values containing file counts, sizes, percentages, dates, or app names.
- Buttons with longer translations for clipping or unintended wrapping.
- Singular and plural sentences where the language requires different grammar.

For a right-to-left language, also verify that:

- Sentences, controls, and directional icons follow the expected reading direction.
- The main sidebar remains on the left, consistent with SparkClean's navigation design.
- File paths, commands, bundle identifiers, versions, and URLs remain left-to-right.
- Mixed text does not reorder punctuation, numbers, or placeholders incorrectly.

## Automated Checks

Validate the String Catalog JSON:

```bash
jq empty SparkClean/Localizable.xcstrings
```

Run the unit suite, which checks shipped language registration, preference mapping,
layout direction, missing translations, and format placeholders:

```bash
xcodebuild test \
  -project SparkClean.xcodeproj \
  -scheme SparkClean \
  -destination 'platform=macOS' \
  -only-testing:SparkCleanTests
```

## Pull Request Checklist

- The pull request changes one language only.
- The wording has been checked by a fluent or native speaker.
- Placeholders and technical text are unchanged and correctly ordered.
- Destructive and safety-related messages preserve their original meaning.
- The affected screens were reviewed at the minimum window size.
- Right-to-left behavior was checked when applicable.
- Automated localization tests pass.
- New languages are registered in the app, tests, and README.
- The diff contains no unrelated String Catalog rewrites.

Use a clear pull request title, for example:

```text
fix(localization): improve Japanese storage terminology
```

The review may ask for clarification or screenshots when wording changes a safety or
cleanup instruction. Appropriate corrections will be merged after the language,
formatting, and UI context have been checked.

## Languages Wanted

The current priority languages are Spanish, French, Portuguese, Korean, Italian, and
Traditional Chinese. Contributions for other languages are welcome as well.

For questions, open a [GitHub issue](https://github.com/georgekhananaev/spark-clean/issues)
and mention that it is about localization.
