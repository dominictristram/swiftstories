import ArgumentParser
import AppKit
import Foundation
import SwiftSoup

// MARK: - ANSI Colors

/// Provides ANSI escape sequences and convenience printers for terminal output.
enum ANSI {
    /// Red terminal color code.
    static let red = "\u{001B}[31m"
    /// Yellow terminal color code.
    static let yellow = "\u{001B}[33m"
    /// Green terminal color code.
    static let green = "\u{001B}[32m"
    /// Terminal reset color code.
    static let reset = "\u{001B}[0m"

    /// Prints a message in red.
    /// - Parameter msg: Message text to print.
    static func printRed(_ msg: String) { print("\(red)\(msg)\(reset)") }
    /// Prints a message in yellow.
    /// - Parameter msg: Message text to print.
    static func printYellow(_ msg: String) { print("\(yellow)\(msg)\(reset)") }
    /// Prints a message in green.
    /// - Parameter msg: Message text to print.
    static func printGreen(_ msg: String) { print("\(green)\(msg)\(reset)") }
}

// MARK: - SSL Bypass Delegate

/// Accepts server-trust challenges without certificate validation.
///
/// This is used to tolerate backend certificate issues from mirror providers.
final class InsecureDelegate: NSObject, URLSessionDelegate {
    /// Handles TLS authentication challenges by trusting the provided server certificate.
    /// - Parameters:
    ///   - session: URL session issuing the challenge.
    ///   - challenge: Authentication challenge details.
    ///   - completionHandler: Callback for challenge disposition and optional credential.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

// MARK: - Directories

/// Computes and manages destination directories for downloaded media.
struct Directories {
    /// Instagram username for this download run.
    let username: String
    /// Root output path (defaults to `users`).
    let rootPath: String
    /// Path for this user under the root output path.
    let userPath: String
    /// Path where highlight folders are created.
    let highlightsPath: String
    /// Path where stories are saved.
    let storiesPath: String

    /// Creates directory paths for a user.
    /// - Parameters:
    ///   - username: Instagram username being processed.
    ///   - output: Optional custom output directory.
    ///   - chaos: Whether stories should skip date-based subfolders.
    init(username: String, output: String?, chaos: Bool) {
        self.username = username
        rootPath = output ?? "users"
        userPath = (rootPath as NSString).appendingPathComponent(username)
        highlightsPath = (userPath as NSString).appendingPathComponent("highlights")

        if chaos {
            storiesPath = (userPath as NSString).appendingPathComponent("stories")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd-MMMM-yyyy"
            let dateDir = formatter.string(from: Date())
            let storiesBase = (userPath as NSString).appendingPathComponent("stories")
            storiesPath = (storiesBase as NSString).appendingPathComponent(dateDir)
        }
    }

    /// Ensures required output directories exist.
    /// - Parameters:
    ///   - stories: Whether to create the stories directory.
    ///   - highlights: Whether to create the highlights directory.
    func create(stories: Bool, highlights: Bool) {
        let fm = FileManager.default
        func ensureDir(_ path: String) {
            if !fm.fileExists(atPath: path) {
                try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
        }
        ensureDir(rootPath)
        ensureDir(userPath)
        if stories { ensureDir(storiesPath) }
        if highlights { ensureDir(highlightsPath) }
    }

    /// Removes the stories directory when it exists but contains no files.
    func removeEmptyStoriesDir() {
        let fm = FileManager.default
        let absPath = (storiesPath as NSString).standardizingPath
        guard let contents = try? fm.contentsOfDirectory(atPath: absPath), contents.isEmpty else { return }
        try? fm.removeItem(atPath: absPath)
    }
}

// MARK: - Content

/// Encapsulates backend parsing and media download operations for one user.
final class Content {
    /// Instagram username being fetched.
    let username: String
    /// Base URL for the configured backend API.
    let api: String
    /// Default user stories link for non-WebView backends.
    var userLink: String { "\(api)/stories/\(username)" }
    /// HTML payload for the user page.
    let rootPage: String
    /// Derived output directories for this user.
    let directories: Directories
    /// URL session used for all network requests.
    private let session: URLSession

    /// Creates content helpers for one user.
    /// - Parameters:
    ///   - username: Instagram username.
    ///   - rootPage: Initial HTML page content.
    ///   - api: Backend API base URL.
    ///   - output: Optional output root path.
    ///   - chaos: Whether to store stories without date subfolder.
    ///   - session: URL session to use for requests.
    init(username: String, rootPage: String, api: String, output: String?, chaos: Bool, session: URLSession) {
        self.username = username
        self.rootPage = rootPage
        self.api = api
        self.directories = Directories(username: username, output: output, chaos: chaos)
        self.session = session
    }

    var userPath: String { directories.userPath }
    var storiesPath: String { directories.storiesPath }
    var highlightsPath: String { directories.highlightsPath }

    /// Validates whether the target account appears to exist and be public.
    /// - Returns: `true` when account status allows downloading; otherwise `false`.
    func exists() -> Bool {
        if rootPage.contains("This username doesn't exist. Please try with another one.") {
            let igURL = "https://www.instagram.com/\(username)"
            if let url = URL(string: igURL),
               let (_, response) = try? session.synchronousData(from: url),
               let http = response as? HTTPURLResponse, http.statusCode == 404 {
                ANSI.printRed("[!] User '\(username)' does not exist")
            } else {
                ANSI.printRed("[!] Server error. Please try again later")
            }
            return false
        }
        if rootPage.contains("This user has a private account. Please try with another one.") {
            ANSI.printYellow("[!] Account '\(username)' is private")
            return false
        }
        if !api.contains("insta-stories-viewer"), rootPage.contains("This account is private") {
            ANSI.printYellow("[!] Account '\(username)' is private")
            return false
        }
        return true
    }

    /// Extracts story media URLs from the initial page.
    /// - Returns: A list of media URLs, or `nil` when no stories are available.
    func getStories() -> [String]? {
        if rootPage.contains("No stories available. Please try again later.") {
            ANSI.printYellow("\n[!] Whoops! \(username) did not post any recent stories")
            return nil
        }
        if rootPage.contains("There has been an error. Please try again later.") {
            ANSI.printYellow("\n[!] Server error. Please try again later")
            return nil
        }
        print("\n[*] Getting \(username) stories")
        return Self.parsingContent(rootPage, apiBase: api)
    }

    /// Downloads all discovered story items to disk.
    /// - Parameter storiesPool: Story media URLs annotated with video metadata.
    func downloadStories(_ storiesPool: [(url: String, isVideo: Bool)]) {
        let rootStoriesPath = (userPath as NSString).appendingPathComponent("stories")
        let total = storiesPool.count

        func upgradedVideoURL(from raw: String) -> String? {
            var upgraded = raw
            var changed = false
            for suffix in ["", "2", "3", "4", "5", "6"] {
                let imgToken = "/img\(suffix).php"
                let videoToken = "/video\(suffix).php"
                if upgraded.contains(imgToken) {
                    upgraded = upgraded.replacingOccurrences(of: imgToken, with: videoToken)
                    changed = true
                }
            }
            return changed ? upgraded : nil
        }

        func mediaRequest(for url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            for (key, value) in browserHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue(api + "/", forHTTPHeaderField: "Referer")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            return request
        }

        for (i, item) in storiesPool.enumerated() {
            print("\r[*] Downloading stories [\(i + 1)/\(total)]", terminator: "")
            fflush(stdout)
            var data: Data?
            var response: URLResponse?
            if let videoURL = upgradedVideoURL(from: item.url), let url = URL(string: videoURL), videoURL != item.url {
                    if let result = try? session.synchronousData(from: mediaRequest(for: url)),
                       let http = result.1 as? HTTPURLResponse,
                       let ct = http.value(forHTTPHeaderField: "Content-Type"),
                       ct.contains("video") || ct.contains("mp4") {
                        data = result.0
                        response = result.1
                    }
            }
            if data == nil, let url = URL(string: item.url), let result = try? session.synchronousData(from: mediaRequest(for: url)) {
                data = result.0
                response = result.1
            }
            guard let data else { continue }
            let ext: String
            if let http = response as? HTTPURLResponse,
               let ct = http.value(forHTTPHeaderField: "Content-Type"),
               ct.contains("video") || ct.contains("mp4") {
                ext = "mp4"
            } else if item.isVideo {
                ext = "mp4"
            } else {
                ext = "jpg"
            }
            let filename = String(format: "story_%03d.%@", i + 1, ext)
            guard Self.validate(filename: filename, inPath: rootStoriesPath) else { continue }
            let destPath = (storiesPath as NSString).appendingPathComponent(filename)
            try? data.write(to: URL(fileURLWithPath: destPath))
        }
        print("")
    }

    /// Extracts highlight group links and display names from the page HTML.
    /// - Returns: Dictionary of highlight page URL to local folder name.
    func getHighlights() -> [String: String]? {
        guard let doc = try? SwiftSoup.parse(rootPage) else { return nil }
        // div with class starting with "highlight "
        let highlightDivs = (try? doc.select("div[class^='highlight ']")) ?? Elements()
        guard !highlightDivs.isEmpty() else {
            ANSI.printYellow("\n[!] Whoops! \(username) does not appear to have any highlights")
            return nil
        }

        print("\n[*] Getting \(username) highlights")

        var highlightLinks: [String] = []
        for div in highlightDivs.array() {
            guard let a = try? div.select("a").first(),
                  let href = try? a.attr("href")
            else { continue }
            let parts = href.split(separator: "/")
            let clearLink = "/" + parts.dropFirst(2).joined(separator: "/")
            highlightLinks.append(clearLink)
        }

        var highlightsArray: [String] = []
        var highlightsIdArray: [String] = []
        for url in highlightLinks {
            let id = (url as NSString).lastPathComponent
            highlightsIdArray.append(id)
            highlightsArray.append(api + url)
        }

        let nameEls = (try? doc.select("div.highlight-description")) ?? Elements()
        var highlightsNamesArray: [String] = []
        for el in nameEls.array() {
            if let text = try? el.text() {
                highlightsNamesArray.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        var result: [String: String] = [:]
        for (idx, link) in highlightsArray.enumerated() {
            let name = idx < highlightsNamesArray.count ? highlightsNamesArray[idx] : "highlight"
            let id = idx < highlightsIdArray.count ? highlightsIdArray[idx] : ""
            result[link] = "\(name)_\(id)"
        }
        return result
    }

    /// Downloads all media for a single highlight group.
    /// - Parameters:
    ///   - group: Highlight page URL.
    ///   - name: Folder name for this highlight.
    ///   - start: 1-based index of this highlight in the total list.
    ///   - end: Total number of highlights being downloaded.
    func downloadHighlights(group: String, name: String, start: Int, end: Int) {
        guard let url = URL(string: group),
              let (data, _) = try? session.synchronousData(from: url),
              let html = String(data: data, encoding: .utf8)
        else { return }

        let highlightDir = (highlightsPath as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: highlightDir, withIntermediateDirectories: true)

        let links = Self.parsingContent(html, apiBase: api)
        let total = links.count
        for (i, link) in links.enumerated() {
            print("\r[*] Downloading highlight \(start) of \(end) [\(i + 1)/\(total)]", terminator: "")
            fflush(stdout)
            guard let mediaURL = URL(string: link),
                  let (data, response) = try? session.synchronousData(from: mediaURL)
            else { continue }
            let filename = Self.filename(for: link, index: i, response: response)
            guard Self.validate(filename: filename, inPath: highlightsPath) else { continue }
            let destPath = (highlightDir as NSString).appendingPathComponent(filename)
            try? data.write(to: URL(fileURLWithPath: destPath))
        }
        print("")
    }

    /// Parses media URLs from backend HTML response content.
    /// - Parameters:
    ///   - page: Raw HTML page content.
    ///   - apiBase: Backend API base URL.
    /// - Returns: Ordered list of media URLs.
    static func parsingContent(_ page: String, apiBase: String) -> [String] {
        var contentLinks: [String] = []
        guard let doc = try? SwiftSoup.parse(page) else { return contentLinks }

        // insta-stories-viewer.com: img src with cdn proxy URLs (exclude profile avatar)
        if apiBase.contains("insta-stories-viewer") {
            let imgs = (try? doc.select("img[src*='cdn.insta-stories-viewer.com/img.php']:not(.profile__avatar-pic):not(.popup__avatar-pic)")) ?? Elements()
            var seen = Set<String>()
            for img in imgs.array() {
                guard let src = try? img.attr("src"),
                      src.hasPrefix("http"),
                      !seen.contains(src)
                else { continue }
                seen.insert(src)
                contentLinks.append(src)
            }
            return contentLinks
        }

        // insta-stories.com / anonyig style: div.download-story-container with onclick
        let containers = (try? doc.select("div.download-story-container")) ?? Elements()
        let pattern = try! NSRegularExpression(pattern: #"(https://scontent\S+)(.*?)'"#, options: [])

        for div in containers.array() {
            guard let link = try? div.select("a.download-story").first(),
                  let onclick = try? link.attr("onclick")
            else { continue }
            let range = NSRange(onclick.startIndex..., in: onclick)
            guard let match = pattern.firstMatch(in: onclick, options: [], range: range),
                  let urlRange = Range(match.range(at: 1), in: onclick)
            else { continue }
            var url = String(onclick[urlRange])
            url = url
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
            contentLinks.append(url)
        }
        return contentLinks
    }

    /// Parses story tile metadata from `insta-stories-viewer` page markup.
    /// - Parameter page: Raw HTML page content.
    /// - Returns: Unique story URLs paired with inferred video flag.
    static func parsingViewerStoryItems(_ page: String) -> [(url: String, isVideo: Bool)] {
        var items: [(url: String, isVideo: Bool)] = []
        guard let doc = try? SwiftSoup.parse(page) else { return items }
        let links = (try? doc.select(".profile__tabs-media-item-link.show-modal[data-type='stories']")) ?? Elements()
        var seen = Set<String>()
        for el in links.array() {
            guard let content = try? el.attr("data-content"), !content.isEmpty else { continue }
            if seen.contains(content) { continue }
            let mediaType = ((try? el.attr("data-media-type")) ?? "").lowercased()
            let filename = ((try? el.attr("data-filename")) ?? "").lowercased()
            let isVideo = mediaType == "video" || filename.hasSuffix(".mp4")
            seen.insert(content)
            items.append((content, isVideo))
        }
        return items
    }

    /// Computes a local filename for a downloaded media item.
    /// - Parameters:
    ///   - link: Original media link.
    ///   - index: Zero-based position in the current download list.
    ///   - response: HTTP response used to infer content type.
    /// - Returns: Filename with extension.
    static func filename(for link: String, index: Int, response: URLResponse?) -> String {
        let pathComponent = (link as NSString).lastPathComponent
        if pathComponent.contains("."), !pathComponent.hasPrefix("img.") {
            return pathComponent
        }
        let ext: String
        if let http = response as? HTTPURLResponse,
           let contentType = http.value(forHTTPHeaderField: "Content-Type") {
            if contentType.contains("video") || contentType.contains("mp4") { ext = "mp4" }
            else if contentType.contains("image") { ext = "jpg" }
            else { ext = "jpg" }
        } else {
            ext = "jpg"
        }
        return String(format: "story_%03d.%@", index + 1, ext)
    }

    /// Checks whether a filename already exists in a target directory tree.
    /// - Parameters:
    ///   - filename: Candidate filename.
    ///   - path: Root path to inspect.
    /// - Returns: `true` if no existing file uses the same name.
    static func validate(filename: String, inPath path: String) -> Bool {
        let fm = FileManager.default
        var existingFiles: Set<String> = []
        if let enumerator = fm.enumerator(atPath: path) {
            while let file = enumerator.nextObject() as? String {
                let name = (file as NSString).lastPathComponent
                if !name.hasPrefix(".") {
                    existingFiles.insert(name)
                }
            }
        }
        return !existingFiles.contains(filename)
    }
}

// MARK: - HTTP Helpers

/// Browser-like HTTP headers used for requests to scraping backends.
private let browserHeaders: [String: String] = [
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
]

/// Provides blocking wrappers around URLSession request APIs.
extension URLSession {
    /// Performs a blocking HTTP request for a URL using default browser headers.
    /// - Parameter url: Target URL.
    /// - Returns: Response data and URL response.
    /// - Throws: Request or transport errors.
    func synchronousData(from url: URL) throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        for (key, value) in browserHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try synchronousData(from: request)
    }

    /// Performs a blocking HTTP request for a URLRequest.
    /// - Parameter request: Fully configured request.
    /// - Returns: Response data and URL response.
    /// - Throws: Request or transport errors.
    func synchronousData(from request: URLRequest) throws -> (Data, URLResponse) {
        var result: (Data, URLResponse)?
        var requestError: Error?
        let sem = DispatchSemaphore(value: 0)
        let task = dataTask(with: request) { data, response, error in
            if let data, let response {
                result = (data, response)
            } else {
                requestError = error ?? URLError(.unknown)
            }
            sem.signal()
        }
        task.resume()
        sem.wait()
        if let error = requestError { throw error }
        guard let r = result else { throw URLError(.unknown) }
        return r
    }
}

// MARK: - CLI

/// Command-line entrypoint and argument parsing for `swiftstories`.
struct SwiftstoriesCommand: ParsableCommand {
    /// CLI metadata shown in generated help output.
    static let configuration = CommandConfiguration(
        commandName: "swiftstories",
        abstract: "Download Instagram stories or highlights anonymously"
    )

    /// One or more Instagram usernames to process.
    @Option(name: [.short, .long], parsing: .singleValue, help: "Instagram username(s)")
    var users: [String] = []

    /// Enables story download workflow.
    @Flag(name: [.short, .long], help: "Download stories")
    var stories: Bool = false

    /// Enables highlight download workflow.
    @Flag(name: [.long, .customShort("H")], help: "Download highlights")
    var highlights: Bool = false

    /// Custom root output directory.
    @Option(name: [.short, .long], help: "Directory for data storage")
    var output: String?

    /// Backend API base URL.
    @Option(name: .long, help: "Backend API base URL")
    var api: String = "https://insta-stories-viewer.com"

    /// Stores stories in a single folder instead of date partitioning.
    @Flag(name: [.short, .long], help: "Save stories in one directory")
    var chaos: Bool = false

    /// Writes fetched HTML to `/tmp/swiftstories_debug.html`.
    @Flag(name: .long, help: "Save page HTML to /tmp/swiftstories_debug.html for debugging")
    var debug: Bool = false

    /// Validates required CLI arguments before command execution.
    /// - Throws: `ValidationError` when required options are missing.
    mutating func validate() throws {
        guard !users.isEmpty else {
            throw ValidationError("At least one username is required. Use -u or --users.")
        }
        guard stories || highlights else {
            throw ValidationError("At least one of --stories or --highlights is required.")
        }
    }

    /// Runs the full download workflow for all requested users.
    /// - Throws: Propagates command-level failures surfaced by ArgumentParser.
    func run() throws {
        let delegate = InsecureDelegate()
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let apiBase = api.hasSuffix("/") ? String(api.dropLast()) : api

        for user in users {
            let link: String
            if apiBase.contains("insta-stories-viewer") {
                link = "\(apiBase)/\(user)/"
            } else {
                link = "\(apiBase)/stories/\(user)"
            }
            guard let url = URL(string: link) else { continue }

            let rootPage: String
            let storyItems: [(url: String, isVideo: Bool)]

            if apiBase.contains("insta-stories-viewer") {
                NSApplication.shared.setActivationPolicy(.accessory)
                print("\n[*] Loading \(user)…", terminator: "")
                fflush(stdout)
                let lock = NSLock()
                var done = false
                var fetchedRootPage = ""
                var fetchedItems: [(url: String, isVideo: Bool)] = []
                let fetcher = WebViewFetcher()
                let debugFlag = debug
                DispatchQueue.global().async {
                    let (items, html) = fetcher.fetchStoryURLs(from: url)
                    lock.lock()
                    fetchedRootPage = html
                    fetchedItems = items
                    done = true
                    lock.unlock()
                }
                while true {
                    lock.lock()
                    let d = done
                    lock.unlock()
                    if d { break }
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
                }
                rootPage = fetchedRootPage
                let parsedFromHTML = Content.parsingViewerStoryItems(fetchedRootPage)
                storyItems = parsedFromHTML.isEmpty ? fetchedItems : parsedFromHTML
                if debugFlag, !rootPage.isEmpty {
                    try? rootPage.write(toFile: "/tmp/swiftstories_debug.html", atomically: true, encoding: .utf8)
                    print(" [debug: saved HTML to /tmp/swiftstories_debug.html]")
                    print(" [debug: extracted \(storyItems.count) story item(s)]")
                    for (idx, item) in storyItems.enumerated() {
                        print(" [debug] \(idx + 1). \(item.isVideo ? "video" : "image") \(item.url)")
                    }
                }
                print(" done")
            } else {
                do {
                    var request = URLRequest(url: url)
                    request.setValue(browserHeaders["User-Agent"], forHTTPHeaderField: "User-Agent")
                    request.setValue(browserHeaders["Accept"], forHTTPHeaderField: "Accept")
                    request.setValue(browserHeaders["Accept-Language"], forHTTPHeaderField: "Accept-Language")
                    request.setValue(apiBase + "/", forHTTPHeaderField: "Referer")
                    let (data, response) = try session.synchronousData(from: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        ANSI.printRed("[!] Failed to fetch page for '\(user)': HTTP \(http.statusCode)")
                        continue
                    }
                    guard let text = String(data: data, encoding: .utf8) else {
                        ANSI.printRed("[!] Failed to fetch page for '\(user)': Could not decode response")
                        continue
                    }
                    rootPage = text
                    storyItems = []
                } catch {
                    ANSI.printRed("[!] Failed to fetch page for '\(user)': \(error.localizedDescription)")
                    continue
                }
            }

            let userContent = Content(username: user, rootPage: rootPage, api: apiBase, output: output, chaos: chaos, session: session)
            guard userContent.exists() else { continue }

            let dirs = Directories(username: user, output: output, chaos: chaos)

            if stories {
                let storiesPool: [(url: String, isVideo: Bool)]
                if apiBase.contains("insta-stories-viewer") {
                    storiesPool = storyItems
                } else if let pool = userContent.getStories() {
                    storiesPool = pool.map { ($0, false) }
                } else {
                    storiesPool = []
                }
                if !storiesPool.isEmpty {
                    dirs.create(stories: true, highlights: false)
                    userContent.downloadStories(storiesPool)
                    dirs.removeEmptyStoriesDir()
                } else {
                    ANSI.printYellow("\n[!] No stories found for '\(user)'")
                }
            }

            if highlights {
                if let highlightsPool = userContent.getHighlights(), !highlightsPool.isEmpty {
                    dirs.create(stories: false, highlights: true)
                    let end = highlightsPool.count
                    for (idx, (group, name)) in highlightsPool.enumerated() {
                        userContent.downloadHighlights(group: group, name: name, start: idx + 1, end: end)
                    }
                }
            }
        }

        ANSI.printGreen("\n[*] All tasks have been completed\n")
    }
}

SwiftstoriesCommand.main()
