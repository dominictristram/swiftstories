# swiftstories

`swiftstories` is a macOS Swift command-line utility that downloads publicly available Instagram stories and highlights for one or more usernames.

It uses anonymous public story-viewer backends and saves media to local folders.

## Features

- Download stories with one command
- Download highlights (`--highlights`)
- Handle multiple users in a single run (`-u user1 -u user2`)
- Save output to a custom directory (`--output`)
- Optional "chaos" mode to keep stories in one folder (`--chaos`)
- Configurable backend API (`--api`)

## Requirements

- macOS 13 or newer
- Swift 5.9+
- Internet connection

## Build

```bash
swift build
```

## Usage

```bash
swift run swiftstories -u <username> --stories
```

### Common examples

Download stories for one user:

```bash
swift run swiftstories -u nasa --stories
```

Download stories and highlights:

```bash
swift run swiftstories -u nasa --stories --highlights
```

Download for multiple users:

```bash
swift run swiftstories -u nasa -u natgeo --stories
```

Set custom output directory:

```bash
swift run swiftstories -u nasa --stories --output ./downloads
```

Store stories in a single directory (no date subfolder):

```bash
swift run swiftstories -u nasa --stories --chaos
```

Use a different backend endpoint:

```bash
swift run swiftstories -u nasa --stories --api https://insta-stories-viewer.com
```

Debug HTML extraction:

```bash
swift run swiftstories -u nasa --stories --debug
```

## CLI options

```text
USAGE: swiftstories [--users <users> ...] [--stories] [--highlights] [--output <output>] [--api <api>] [--chaos] [--debug]

OPTIONS:
  -u, --users <users>     Instagram username(s)
  -s, --stories           Download stories
  -H, --highlights        Download highlights
  -o, --output <output>   Directory for data storage
  --api <api>             Backend API base URL (default: https://insta-stories-viewer.com)
  -c, --chaos             Save stories in one directory
  --debug                 Save page HTML to /tmp/swiftstories_debug.html for debugging
  -h, --help              Show help information
```

## Output structure

Default structure:

```text
users/
  <username>/
    stories/
      <dd-MMMM-yyyy>/
        story_001.jpg|mp4
        story_002.jpg|mp4
    highlights/
      <highlight_name>_<id>/
        ...
```

With `--chaos`, stories are saved to:

```text
users/<username>/stories/
```

## Notes

- This tool only works for publicly accessible content from accounts/backends that return media links.
- Backend availability and page structure can change over time.
- Respect Instagram's Terms of Service and local laws when using this project.

## License

Add your preferred license in a `LICENSE` file.
