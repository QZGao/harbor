# Harbor manual test suite

Use this suite on a dedicated macOS test account when possible. Quit Harbor before you start a UI test. The offline suite uses a local fixture server and does not require public network access.

## Run the suites

Run the core unit tests:

```sh
Scripts/run-test-suite.sh core
```

Run the offline UI tests:

```sh
HARBOR_UI_CONFIRM_NO_RUNNING_HARBOR=YES Scripts/run-test-suite.sh ui
```

Run one UI test again:

```sh
HARBOR_UI_CONFIRM_NO_RUNNING_HARBOR=YES \
HARBOR_ONLY_TESTING=HarborUITests/HarborLaunchUITests/testLaunchNavigationSearchAndAddSheet \
Scripts/run-test-suite.sh ui
```

Run the macOS integration tests only after you review their state changes:

```sh
HARBOR_UI_CONFIRM_NO_RUNNING_HARBOR=YES \
HARBOR_UI_ALLOW_SYSTEM_INTEGRATIONS=YES \
HARBOR_UI_NOTIFICATION_PREAPPROVED=YES \
Scripts/run-test-suite.sh system
```

Run the public-site canaries only when public network traffic is acceptable:

```sh
HARBOR_UI_CONFIRM_NO_RUNNING_HARBOR=YES \
HARBOR_UI_ALLOW_LIVE_NETWORK=YES \
Scripts/run-test-suite.sh live
```

Use `Scripts/run-test-suite.sh all` only when all three system and live opt-in variables are set. Use `Scripts/run-test-suite.sh release-smoke /absolute/path/Harbor.app` to run the packaged-app smoke test.

## macOS permissions

Xcode can request Accessibility and Automation access when it starts UI tests. The system tests can also open Finder, Quick Look, and an `NSOpenPanel`. Grant access only to the Xcode processes that run this local suite.

Notification authorization is not automated. Preapprove Harbor notifications and set `HARBOR_UI_NOTIFICATION_PREAPPROVED=YES` before the system suite. The runner stops with a setup error when this confirmation is missing.

## Fixtures and results

The fixture server binds to `127.0.0.1` on a random port. It provides deterministic files, slow and ranged transfers, redirects, error responses, browser downloads, media, and torrent fixtures. Each test uses separate temporary defaults, application-support, and download directories.

The runner stores logs and `.xcresult` bundles in `build/TestResults/<UTC timestamp>/`. A failed UI test attaches a screenshot, the accessibility hierarchy, the Harbor persistence file, and the fixture request log when each item is available.

Live links are in `Fixtures/live-links.json`. These checks are canaries, not deterministic acceptance tests. Update a link only after you confirm that the public page is still suitable for anonymous testing.
