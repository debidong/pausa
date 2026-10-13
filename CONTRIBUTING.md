# Contributing to Pausa

Thanks for helping improve Pausa. This guide explains how to build the app,
run the checks, and get a pull request merged.

## Requirements

- macOS 13 or later
- Swift 5.9 or later (Xcode or the Swift toolchain)

## Build

To build the package for development, run:

```sh
swift build
```

To build `Pausa.app` (universal, ad-hoc signed) into `build/`, run:

```sh
App/build-app.sh
```

## Run the checks

The scheduling logic in `Sources/PausaCore` has a check program. Run it
before you open a pull request:

```sh
swift run PausaCoreCheck
```

All checks must pass.

## Open a pull request

1. Fork the repository and create a branch for your change.
1. Keep each pull request focused on one change.
1. Make sure `swift build` and `swift run PausaCoreCheck` pass.
1. Open the pull request against `main`.

## Sign the CLA

Before we can merge your first pull request, you must sign the
[Contributor License Agreement](CLA.md). You sign it once, and it covers
your future contributions.

When you open a pull request, the CLA Assistant bot posts a comment. To sign,
reply on the pull request with this exact text:

```
I have read the CLA Document and I hereby sign the CLA
```

If the check doesn't update, comment `recheck`.

## License

Pausa is source-available under the [PolyForm Shield License 1.0.0](LICENSE).
