# Install swiftstories

This document covers common installation paths for `swiftstories` on macOS.

## Prerequisites

- macOS 13+
- Xcode Command Line Tools
- Swift 5.9+

Check Swift version:

```bash
swift --version
```

If needed, install Command Line Tools:

```bash
xcode-select --install
```

## Method 1: Run directly from source (recommended)

```bash
git clone <your-repo-url>
cd swiftstories
swift run swiftstories --help
```

Example:

```bash
swift run swiftstories -u nasa --stories
```

## Method 2: Build once, run binary from `.build`

```bash
swift build -c release
./.build/release/swiftstories --help
```

Example:

```bash
./.build/release/swiftstories -u nasa --stories --highlights
```

## Method 3: Install binary into `/usr/local/bin`

Build release binary:

```bash
swift build -c release
```

Install:

```bash
install -m 0755 ./.build/release/swiftstories /usr/local/bin/swiftstories
```

Now you can run:

```bash
swiftstories --help
```

If `/usr/local/bin` is not in your `PATH`, add it to your shell profile.

## Verify installation

```bash
swiftstories --help
```

or, if you are running from source:

```bash
swift run swiftstories --help
```

## Uninstall

If installed with Method 3:

```bash
rm /usr/local/bin/swiftstories
```

If running from source only, remove the repo directory.

## Troubleshooting

If you moved/renamed the project folder and builds fail due to module cache paths, clean and rebuild:

```bash
swift package clean
swift build
```
