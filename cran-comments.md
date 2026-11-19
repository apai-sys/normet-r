## R CMD check results

0 errors | 0 warnings | 3 notes

- **New submission** — expected for a first release.
- **checking for future file timestamps ... NOTE** — the local check machine
  could not reach a time service ("unable to verify current time"); the package
  sets no file times of its own.
- **checking HTML version of manual ... NOTE** — the local HTML Tidy is older
  than the HTML5 `<main>` element that this R version's `Rd2HTML` emits, and
  defaults to a pre-UTF-8 encoding, so it also reports the UTF-8 em dashes in
  a few pages as invalid character codes. The manual itself renders and the
  PDF version checks OK; the note is a property of the local Tidy, not of the
  package.

## Test environments

- Local: macOS 27.2.1 (aarch64-apple-darwin20), R 4.4.1
- GitHub Actions (`R-CMD-check`): ubuntu-latest, macos-latest and
  windows-latest, R-release

## Downstream dependencies

None: first release.

## Additional comments

- The package uses `doParallel` for its optional parallel loops (the
  superseded `doSNOW` was removed); serial paths keep progress bars and
  parallel branches report through log lines.
- Functions that reach the internet have `\dontrun` examples; the test suite
  mocks HTTP responses with `httr2::local_mocked_responses()`.
- Spelling: the package uses British English (`Language: en-GB`); technical
  terms are listed in `inst/WORDLIST`.
