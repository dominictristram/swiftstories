//
//  swiftstories
//  Written by Dominic Tristram
//  Released under the GNU General Public License v3.0 (GPL-3.0)
//  https://www.gnu.org/licenses/gpl-3.0.en.html
//

import AppKit
import Foundation
import WebKit

/// Fetches a page using WKWebView, waits for JavaScript to execute, and extracts story URLs.
/// Must be called from a background thread; WebView runs on main.
final class WebViewFetcher: NSObject {
    /// Headless web view used for script-driven extraction.
    private var webView: WKWebView!
    /// Off-screen window required to host the web view.
    private var window: NSWindow!
    /// Signals when the initial page load finishes or fails.
    private let loadSem = DispatchSemaphore(value: 0)
    /// Signals when a single extraction pass completes.
    private let extractSem = DispatchSemaphore(value: 0)
    /// Accumulates extracted story items across scraping phases.
    private var extractedItems: [(url: String, isVideo: Bool)] = []
    /// Stores latest HTML snapshot for debug and fallback parsing.
    private var extractedHTML: String = ""
    /// Captures navigation/load failures.
    private var loadError: Error?
    /// Signals when final results are ready to return.
    private let resultSem = DispatchSemaphore(value: 0)
    /// Final return value for `fetchStoryURLs(from:)`.
    private var result: (items: [(url: String, isVideo: Bool)], html: String) = ([], "")

    /// JavaScript injected at document start to silence all media playback.
    ///
    /// The scraper still reads media URLs and downloads assets, but no audio is emitted
    /// while pages/videos are being loaded in the hidden web view.
    private static let muteMediaScript = """
    (function() {
      if (window.__swiftstoriesMuteInstalled) return;
      window.__swiftstoriesMuteInstalled = true;

      function silence(el) {
        if (!el) return;
        try { el.muted = true; } catch (_) {}
        try { el.defaultMuted = true; } catch (_) {}
        try { el.volume = 0; } catch (_) {}
        try { el.setAttribute('muted', 'muted'); } catch (_) {}
      }

      function silenceAll() {
        document.querySelectorAll('video, audio').forEach(silence);
      }

      var nativePlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function() {
        silence(this);
        return nativePlay.apply(this, arguments);
      };

      document.addEventListener('play', function(e) { silence(e.target); }, true);
      silenceAll();

      var observer = new MutationObserver(function() { silenceAll(); });
      observer.observe(document.documentElement || document, { childList: true, subtree: true });
    })();
    """

    /// Normalizes provider-specific media URL variants to a canonical key.
    /// - Parameter url: Raw media URL.
    /// - Returns: Canonicalized key used for deduplication.
    private static func canonicalStoryKey(for url: String) -> String {
        var normalized = url
        for suffix in ["", "2", "3", "4", "5", "6"] {
            normalized = normalized.replacingOccurrences(of: "/img\(suffix).php", with: "/media\(suffix).php")
            normalized = normalized.replacingOccurrences(of: "/video\(suffix).php", with: "/media\(suffix).php")
        }
        return normalized
    }

    /// Merges an extracted story candidate while preserving preferred video links.
    /// - Parameters:
    ///   - url: Story media URL.
    ///   - isVideo: Whether the item should be treated as video.
    private func mergeExtractedItem(url: String, isVideo: Bool) {
        guard !url.isEmpty else { return }

        if let exact = extractedItems.firstIndex(where: { $0.url == url }) {
            if isVideo, !extractedItems[exact].isVideo {
                extractedItems[exact].isVideo = true
            }
            return
        }

        let key = Self.canonicalStoryKey(for: url)
        if let sameStory = extractedItems.firstIndex(where: { Self.canonicalStoryKey(for: $0.url) == key }) {
            let existing = extractedItems[sameStory]
            let existingIsImg = existing.url.contains("/img")
            let incomingIsVideoURL = url.contains("/video")
            if (isVideo && !existing.isVideo) || (incomingIsVideoURL && existingIsImg) {
                extractedItems[sameStory] = (url, true)
            }
            return
        }

        extractedItems.append((url, isVideo))
    }

    /// Call from background thread. Returns (story items with video flag, page HTML).
    /// - Parameter url: User page URL to load.
    /// - Returns: Extracted story items plus final page HTML.
    func fetchStoryURLs(from url: URL) -> (items: [(url: String, isVideo: Bool)], html: String) {
        DispatchQueue.main.async { [weak self] in
            self?.setupAndLoad(url: url)
        }
        loadSem.wait()

        if loadError != nil {
            finish([], ""); return result
        }

        // Wait for profile to load
        Thread.sleep(forTimeInterval: 4)

        // Click profile avatar to open story viewer modal (stories often load on click)
        DispatchQueue.main.async { [weak self] in
            self?.clickProfileAvatar()
        }
        Thread.sleep(forTimeInterval: 2)

        // Click stories tab and wait for content to load
        DispatchQueue.main.async { [weak self] in
            self?.clickStoriesTab()
        }
        Thread.sleep(forTimeInterval: 3)

        // Prefer extraction directly from story tiles metadata; it's more stable than popup navigation.
        DispatchQueue.main.async { [weak self] in
            self?.extractFromStoriesTab()
        }
        extractSem.wait()
        if !extractedItems.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.finish(self?.extractedItems ?? [], self?.extractedHTML ?? "")
            }
            resultSem.wait()
            return result
        }

        DispatchQueue.main.async { [weak self] in
            self?.clickFirstStory()
        }
        Thread.sleep(forTimeInterval: 4)

        // Extract from popup, then click next to advance
        for step in 0 ..< 10 {
            DispatchQueue.main.async { [weak self] in
                self?.extractContent()
            }
            extractSem.wait()
            if step < 9 {
                DispatchQueue.main.async { [weak self] in
                    self?.clickNextStory()
                }
                Thread.sleep(forTimeInterval: 2.0)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.finish(self?.extractedItems ?? [], self?.extractedHTML ?? "")
        }
        resultSem.wait()
        return result
    }

    /// Stores final extraction result and schedules web view cleanup.
    /// - Parameters:
    ///   - items: Story items to return.
    ///   - html: Last captured page HTML.
    private func finish(_ items: [(url: String, isVideo: Bool)], _ html: String) {
        result = (items, html)
        resultSem.signal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.cleanup()
        }
    }

    /// Configures an off-screen WKWebView and begins loading the target URL.
    /// - Parameter url: URL to open in the web view.
    private func setupAndLoad(url: URL) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.addUserScript(
            WKUserScript(
                source: Self.muteMediaScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView?.addSubview(webView)
        window.orderOut(nil)

        webView.load(URLRequest(url: url))
    }

    /// Attempts to open the profile viewer by clicking avatar elements.
    private func clickProfileAvatar() {
        let script = """
        (function() {
            var avatar = document.querySelector('.profile__avatar, .profile__avatar-inner, [data-popup="profile__tabs-stories"]');
            if (avatar) { avatar.click(); return true; }
            var ring = document.querySelector('.profile__avatar');
            if (ring) { ring.click(); return true; }
            return false;
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Selects the stories tab so story tiles become visible.
    private func clickStoriesTab() {
        let script = """
        (function() {
            var tab = document.querySelector('.profile__tabs-item[data-tab="profile__tabs-stories"]');
            if (tab) { tab.click(); return true; }
            var any = document.querySelector('[data-tab="profile__tabs-stories"]');
            if (any) { any.click(); return true; }
            return false;
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Advances the story viewer popup to the next story item.
    private func clickNextStory() {
        webView?.evaluateJavaScript("""
            (function() {
                var sel = '.popup__arrow_right, .popup__arrow-right, .popup__nav-next, .popup [data-direction="next"], .popup__arrow[data-direction="next"], button.next, [class*="arrow"][class*="right"], .swiper-button-next, .slick-next';
                var n = document.querySelector(sel);
                if (n) { n.click(); return true; }
                var arr = document.querySelectorAll('.popup__arrow, [class*="arrow"]');
                for (var i = 0; i < arr.length; i++) {
                    var c = String(arr[i].className || '');
                    if (c.indexOf('right') >= 0 || c.indexOf('next') >= 0) { arr[i].click(); return true; }
                }
                var rightBtn = document.querySelector('.popup button[aria-label*="next"]');
                if (rightBtn) { rightBtn.click(); return true; }
                var popup = document.querySelector('.popup');
                if (popup) {
                    var r = popup.getBoundingClientRect();
                    var x = r.left + r.width * 0.85, y = r.top + r.height / 2;
                    var el = document.elementFromPoint(x, y);
                    if (el) { el.click(); return true; }
                }
                var ev = new KeyboardEvent('keydown', { key: 'ArrowRight', keyCode: 39, which: 39 });
                document.dispatchEvent(ev);
                return true;
            })();
        """, completionHandler: nil)
    }

    /// Scrolls the stories tab to reveal additional story tiles.
    private func scrollStoriesTabRight() {
        webView?.evaluateJavaScript("""
            (function() {
                var section = document.querySelector('.profile__tabs-stories, [data-tab="profile__tabs-stories"]');
                if (!section) return;
                var scroller = section.querySelector('.profile__tabs-media, [class*="scroll"], [class*="media"]') || section;
                if (scroller.scrollLeft !== undefined) scroller.scrollLeft += 200;
                var inner = section.querySelector('[class*="inner"], [class*="list"]');
                if (inner && inner.scrollLeft !== undefined) inner.scrollLeft += 200;
            })();
        """, completionHandler: nil)
    }

    /// Extracts candidate story URLs directly from the stories tab.
    private func extractFromStoriesTab() {
        let script = """
        (function() {
            var out = [];
            var seen = new Set();
            function add(url, isV) {
                if (!url || seen.has(url)) return;
                if (!isV && url.indexOf('img.php') === -1 && url.indexOf('img2.php') === -1 && url.indexOf('cdn.') === -1) return;
                seen.add(url);
                out.push([url, isV ? 'video' : 'image']);
            }
            var section = document.querySelector('.profile__tabs-stories, [data-tab="profile__tabs-stories"]');
            if (section) {
                section.querySelectorAll('.profile__tabs-media-item-link.show-modal[data-type="stories"]').forEach(function(el) {
                    var u = el.getAttribute('data-content') || el.getAttribute('href');
                    var mt = (el.getAttribute('data-media-type') || '').toLowerCase();
                    var fn = (el.getAttribute('data-filename') || '').toLowerCase();
                    var isV = mt === 'video' || fn.indexOf('.mp4') !== -1;
                    add(u, isV);
                });
                section.querySelectorAll('img[src*="img.php"]').forEach(function(img) {
                    add(img.src || img.getAttribute('data-src'), false);
                });
                section.querySelectorAll('img[src*="img2.php"]').forEach(function(img) {
                    add(img.src || img.getAttribute('data-src'), false);
                });
                section.querySelectorAll('video source').forEach(function(s) {
                    add(s.src || s.getAttribute('data-src'), true);
                });
                section.querySelectorAll('a[href*="img.php"]').forEach(function(a) {
                    add(a.href || a.getAttribute('href'), false);
                });
            }
            if (out.length === 0) {
                document.querySelectorAll('.profile__tabs-media img[src*="img.php"], .profile__stories img[src*="img.php"]').forEach(function(img) {
                    if (!img.closest('.profile__tabs-posts') && !img.closest('.profile__avatar')) add(img.src || img.getAttribute('data-src'), false);
                });
            }
            return out;
        })();
        """
        let sem = extractSem
        webView.evaluateJavaScript(script) { [weak self] jsResult, _ in
            if let self = self, let pairs = jsResult as? [[String]] {
                for p in pairs where p.count >= 2 {
                    let url = p[0], isVideo = p[1] == "video"
                    self.mergeExtractedItem(url: url, isVideo: isVideo)
                }
            }
            guard let wv = self?.webView else { sem.signal(); return }
            wv.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] htmlResult, _ in
                defer { sem.signal() }
                if let html = htmlResult as? String { self?.extractedHTML = html }
            }
        }
    }

    /// Opens the first visible story item in the story viewer popup.
    private func clickFirstStory() {
        let script = """
        (function() {
            var items = document.querySelectorAll('.profile__tabs-media-item, .profile__stories-item, [data-slide], .profile__tabs-media [data-popup]');
            for (var i = 0; i < Math.min(items.length, 3); i++) {
                if (items[i].click) { items[i].click(); return true; }
            }
            var links = document.querySelectorAll('.profile__tabs-stories a, .profile__tabs-media a');
            if (links.length) { links[0].click(); return true; }
            return false;
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Extracts URLs for the currently visible story in the popup viewer.
    private func extractContent() {
        // Extract the CURRENT visible story from the popup. Prefer the active/visible slide.
        // Fall back to global extraction if popup structure doesn't match.
        let urlScript = """
        (function() {
            var out = [];
            var seen = new Set();
            function add(url, isVideo) {
                if (!url || seen.has(url)) return;
                if (!isVideo && url.indexOf('img.php') === -1 && url.indexOf('cdn.insta-stories-viewer.com') === -1) return;
                seen.add(url);
                out.push([url, isVideo ? 'video' : 'image']);
            }
            function fromEl(el) {
                if (!el) return null;
                var v = el.querySelector('video');
                if (v) {
                    var src = v.currentSrc || v.src;
                    if (!src) { var s = v.querySelector('source'); src = s ? (s.src || s.getAttribute('data-src') || s.getAttribute('data-video')) : null; }
                    if (!src) src = v.getAttribute('data-src') || v.getAttribute('data-video');
                    if (src) return [src, true];
                    var i = el.querySelector('img[src*="img.php"]');
                    if (i) return [i.src || i.getAttribute('data-src'), true];
                }
                var i = el.querySelector('img[src*="img.php"]');
                if (i && !i.closest('.popup__avatar')) return [i.src || i.getAttribute('data-src'), false];
                return null;
            }
            var popup = document.querySelector('.popup, [class*="popup"]');
            if (popup) {
                var active = popup.querySelector('.popup__slide--active, .swiper-slide-active, .popup__media-item--active, [class*="slide"][class*="active"], [class*="active"]');
                if (active) {
                    var r = fromEl(active);
                    if (r) { add(r[0], r[1]); return out; }
                }
                var slides = popup.querySelectorAll('.popup__slide, .popup__media-item, .swiper-slide, [data-slide], [class*="slide"]');
                var collected = [];
                for (var i = 0; i < slides.length; i++) {
                    var s = slides[i];
                    var style = window.getComputedStyle(s);
                    if (s.offsetParent === null && style.display === 'none') continue;
                    if (style.visibility === 'hidden' && style.opacity === '0') continue;
                    var r = fromEl(s);
                    if (r) collected.push(r);
                }
                if (collected.length > 0) {
                    var preferred = null;
                    for (var i = 0; i < collected.length; i++) {
                        if (collected[i][1] === true) { preferred = collected[i]; break; }
                    }
                    if (!preferred) preferred = collected[0];
                    add(preferred[0], preferred[1]);
                    return out;
                }
                for (var i = 0; i < slides.length; i++) { var r = fromEl(slides[i]); if (r) { add(r[0], r[1]); return out; } }
                var container = popup.querySelector('.popup__media, .popup__content, [class*="media"], [class*="viewer"]') || popup;
                var video = container.querySelector('video') || popup.querySelector('video');
                var img = container.querySelector('img[src*="img.php"]');
                if (img && img.closest('.popup__avatar')) img = null;
                if (video) {
                    var src = video.currentSrc || video.src;
                    if (!src) { var s = video.querySelector('source'); src = s ? (s.src || s.getAttribute('data-src') || s.getAttribute('data-video')) : null; }
                    if (!src) src = video.getAttribute('data-src') || video.getAttribute('data-video');
                    if (!src && video.parentElement) src = video.parentElement.getAttribute('data-video') || video.parentElement.getAttribute('data-src');
                    if (src) { add(src, true); return out; }
                    if (img) { add(img.src || img.getAttribute('data-src'), true); return out; }
                }
                if (img) { add(img.src || img.getAttribute('data-src'), false); return out; }
                if (out.length > 0) return out;
            }
            if (popup && out.length < 2) {
                popup.querySelectorAll('img[src*="img.php"]').forEach(function(el) {
                    if (el.closest('.profile__avatar') || el.closest('.popup__avatar')) return;
                    var u = el.src || el.getAttribute('data-src');
                    if (u) add(u, false);
                });
                popup.querySelectorAll('video source, video[src]').forEach(function(el) {
                    var u = el.src || el.getAttribute('data-src');
                    if (u) add(u, true);
                });
                if (out.length > 0) return out;
            }
            document.querySelectorAll('video source').forEach(function(s) {
                if (!s.closest('.profile__tabs-posts')) add(s.src || s.getAttribute('data-src'), true);
            });
            document.querySelectorAll('video[src]').forEach(function(v) { add(v.src, true); });
            document.querySelectorAll('img[src*="img.php"]').forEach(function(img) {
                if (img.closest('.profile__avatar') || img.closest('.popup__avatar') || img.closest('.profile__tabs-posts')) return;
                add(img.src || img.getAttribute('data-src'), false);
            });
            return out;
        })();
        """

        let sem = extractSem
        webView.evaluateJavaScript(urlScript) { [weak self] jsResult, _ in
            if let self = self, let pairs = jsResult as? [[String]] {
                for p in pairs where p.count >= 2 {
                    let url = p[0], isVideo = p[1] == "video"
                    self.mergeExtractedItem(url: url, isVideo: isVideo)
                }
            }
            guard let wv = self?.webView else { sem.signal(); return }
            wv.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] htmlResult, _ in
                defer { sem.signal() }
                if let html = htmlResult as? String { self?.extractedHTML = html }
            }
        }
    }

    /// Tears down WKWebView resources after extraction completes.
    private func cleanup() {
        window?.close()
        window = nil
        webView = nil
    }
}

/// Signals loading state transitions from WKWebView navigation.
extension WebViewFetcher: WKNavigationDelegate {
    /// Called when page navigation succeeds.
    /// - Parameters:
    ///   - webView: Web view that finished navigation.
    ///   - navigation: Navigation object.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadSem.signal()
    }

    /// Called when committed navigation fails.
    /// - Parameters:
    ///   - webView: Web view that failed.
    ///   - navigation: Navigation object.
    ///   - error: Failure details.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadError = error
        loadSem.signal()
    }

    /// Called when provisional navigation (request/load start) fails.
    /// - Parameters:
    ///   - webView: Web view that failed.
    ///   - navigation: Navigation object.
    ///   - error: Failure details.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadError = error
        loadSem.signal()
    }
}
