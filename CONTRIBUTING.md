# Contributing

*(Polish original: [docs/pl/CONTRIBUTING.md](docs/pl/CONTRIBUTING.md).)*

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) and the safety rules in [CLAUDE.md](CLAUDE.md).
2. File logic goes into `OpenCommanderCore` and **must have tests** on temporary directories. Tests must not touch the real Trash (use `FakeTrasher`) or user files.
3. Before a PR: `swift test --scratch-path /tmp/oc-spm` and an `xcodebuild` build (commands in the README).
4. After changing `project.yml` run `xcodegen generate` and include the changed `.xcodeproj`.
5. Network protocols: only those in the ROADMAP (stage 4); new external dependencies need a discussion (license, maintenance, pinned version). Network tests only against local servers inside the test process, never against public servers or with real credentials.
6. Do not show a function in the UI that does not work.
