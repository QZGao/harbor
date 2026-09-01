# Contributing to Harbor

Harbor accepts contributions.

This project is a native macOS download manager, and contributions are welcome in two main forms:

- feature requests that help shape Harbor into a better Mac download manager
- pull requests that implement open issues or improve existing behavior

## Feature Requests

Feature requests are welcome, especially when they describe a real download workflow.

Good feature requests usually include:

- the problem you are trying to solve
- how you expect Harbor to behave
- examples from other download managers, if useful
- any edge cases contributors should consider

Small, focused requests are easier to discuss and build. If an idea is large, it is fine to open it as a larger proposal, but it may be split into smaller implementation issues before work starts.

## Working on Features

If you want to work on a feature, start with an open issue.

Before opening a pull request:

- comment on the issue so others know you are working on it
- keep the first implementation scoped to the issue
- ask questions on the issue if behavior is unclear
- prefer native macOS patterns over web-style UI patterns
- avoid adding cloud services, accounts, or hosted dependencies unless the issue explicitly calls for it

Pull requests that implement features added or requested by other contributors are welcome. You do not need to be the person who opened an issue to work on it.

## Pull Requests

When opening a pull request, include:

- what changed
- which issue it closes or relates to
- how you tested it
- screenshots or screen recordings for every fix or feature that changes the UI
- the AI tool and model you used, if AI assisted with the contribution, and a short description of how you used it

You remain responsible for the code, tests, documentation, and review of an AI-assisted contribution.

Keep PRs focused. A small PR that solves one clear issue is easier to review and more likely to ship than a large PR that mixes several unrelated changes.

## Code Style

Harbor is built as a native macOS app with SwiftUI.

Please follow the existing project style:

- keep UI state, app state, persistence, and download engines separated
- prefer clear names over clever abstractions
- add defensive code only for a verified failure mode, platform constraint, or data-safety requirement
- avoid speculative fallback layers that make the code harder to read and maintain
- keep user-facing behavior predictable and conservative
- use system macOS controls and platform conventions where possible
- preserve Harbor's local-first, privacy-friendly product direction

## Bugs

Bug reports are also welcome. Include the Harbor version, macOS version, steps to reproduce, expected behavior, and actual behavior. If the issue involves a specific download URL and the URL can be shared publicly, include it.

## License

By contributing to Harbor, you agree that your contribution will be licensed under the same license as the project.
