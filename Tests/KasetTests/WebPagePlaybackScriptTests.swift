import Foundation
import JavaScriptCore
import Testing
@testable import Kaset

/// The in-page playback bridge, driven against a mock page's player.
///
/// These assertions are the contract with YouTube Music's player: it is asked to start one track in the
/// open document, and every answer it can give is mapped to a decision Kaset already knows how to make.
/// Nothing here installs a queue or advances the page's own queue — that is the page's state, and
/// rewriting it is what left its player bar describing a different song.
@Suite(.serialized, .tags(.service))
@MainActor
struct WebPagePlaybackScriptTests {
    @Test("A page already playing the track is not asked to load it again")
    func alreadyPlayingSkipsTheLoad() throws {
        let context = try self.makeContext()
        self.installBridge(in: context)
        self.seedPlayer(playlist: ["a", "b"], index: 0, videoId: "a", in: context)

        let status = self.play("a", in: context)

        #expect(status == WebPagePlaybackStatus.alreadyPlaying)
        #expect(self.callNames(in: context).isEmpty)
    }

    @Test("A track the page's own queue holds is jumped to, not reloaded")
    func jumpsToATrackThePageHolds() throws {
        let context = try self.makeContext()
        self.installBridge(in: context)
        self.seedPlayer(playlist: ["a", "b", "c"], index: 0, videoId: "a", in: context)

        let status = self.play("b", in: context)

        #expect(status == WebPagePlaybackStatus.playedAt)
        #expect(self.callNames(in: context) == ["playVideoAt"])
        #expect(self.playerInt("index", in: context) == 1)
    }

    @Test("A track the page does not hold is loaded into the open document")
    func loadsAnUnknownTrackInTheOpenDocument() throws {
        let context = try self.makeContext()
        self.installBridge(in: context)
        self.seedPlayer(playlist: ["a"], index: 0, videoId: "a", in: context)

        let status = self.play("b", in: context)

        #expect(status == WebPagePlaybackStatus.loadedVideo)
        let load = try #require(self.calls(in: context).first { $0["name"] as? String == "loadVideoById" })
        #expect(load["videoId"] as? String == "b")
        // Positional form, from the start: a load that kept the old position would end immediately.
        #expect(load["startSeconds"] as? Int == 0)
    }

    @Test("A page with no player API reports that instead of failing silently")
    func reportsAMissingPlayer() throws {
        let context = try self.makeContext()
        self.installBridge(in: context)
        context.evaluateScript("window.__hasPlayer = false;")

        #expect(self.play("b", in: context) == WebPagePlaybackStatus.noPlayer)
    }

    @Test("A player that throws is reported as an error")
    func reportsAPlayerThatThrows() throws {
        let context = try self.makeContext()
        self.installBridge(in: context)
        context.evaluateScript("""
            player.loadVideoById = function() { throw new Error('blocked'); };
            """)

        #expect(self.play("b", in: context) == WebPagePlaybackStatus.failed)
    }

    @Test("The bridge is idempotent across documents")
    func bridgeInstallIsIdempotent() throws {
        let context = try self.makeContext()
        self.installBridge(in: context)
        #expect(self.evaluate("String(typeof window.__kasetPlayback.play)", in: context) == "function")
        self.installBridge(in: context)
        #expect(self.evaluate("String(typeof window.__kasetPlayback.play)", in: context) == "function")
    }

    @Test("The page reports the track its player holds")
    func reportsTheCurrentTrack() throws {
        let context = try self.makeContext()
        self.installBridge(in: context)
        self.seedPlayer(playlist: ["a", "b"], index: 1, videoId: "b", in: context)

        #expect(self.evaluate(SingletonPlayerWebView.pageCurrentScript(), in: context) == "b")
    }

    @Test("A page without a player reports no current track")
    func reportsNoCurrentTrackWithoutAPlayer() throws {
        let context = try self.makeContext()
        self.installBridge(in: context)
        context.evaluateScript("window.__hasPlayer = false;")

        #expect(self.evaluate(SingletonPlayerWebView.pageCurrentScript(), in: context) == "")
    }

    @Test("A track id cannot break out of the generated snippet")
    func escapesTrackIds() throws {
        let context = try self.makeContext()
        self.installBridge(in: context)

        let status = self.play("a'b\"c", in: context)

        #expect(status == WebPagePlaybackStatus.loadedVideo)
        let load = try #require(self.calls(in: context).first { $0["name"] as? String == "loadVideoById" })
        #expect(load["videoId"] as? String == "a'b\"c")
    }

    @Test("A document without the bridge reports that, so the caller loads the page")
    func reportsAMissingBridge() throws {
        let context = try self.makeContext()

        #expect(self.play("b", in: context) == WebPagePlaybackStatus.notInstalled)
    }

    @Test("The observer runs, reports the player bar's track, and ends a track only once")
    func observerReportsTrackEndsOnce() throws {
        let context = try #require(JSContext())
        self.evaluate(
            """
            var postedMessages = [];
            var videoListeners = {};
            var pendingTimers = [];
            var setTimeout = function(callback) { pendingTimers.push(callback); return pendingTimers.length; };
            var setInterval = function() { return 1; };
            var clearInterval = function() {};
            function URL(href, base) {
                this.searchParams = { get: function(name) { return 'a'; } };
            }
            function MutationObserver(callback) { this.callback = callback; }
            MutationObserver.prototype.observe = function() {};
            var playerBar = {
                querySelector: function() { return null; },
                getAttribute: function() { return null; }
            };
            var video = {
                paused: false,
                currentTime: 0,
                addEventListener: function(name, handler) { videoListeners[name] = handler; }
            };
            var document = {
                readyState: 'complete',
                body: {},
                documentElement: {},
                querySelector: function(selector) {
                    if (selector === 'ytmusic-player-bar') { return playerBar; }
                    if (selector === 'video') { return video; }
                    return null;
                },
                querySelectorAll: function() { return []; },
                getElementById: function() { return null; },
                addEventListener: function() {}
            };
            var window = {
                location: { href: 'https://music.youtube.com/watch?v=a' },
                webkit: {
                    messageHandlers: {
                        singletonPlayer: {
                            postMessage: function(message) { postedMessages.push(message); }
                        }
                    }
                }
            };
            """,
            in: context
        )

        self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        #expect(context.exception == nil)
        #expect(self.evaluate("String(typeof videoListeners.ended)", in: context) == "function")

        let states = self.messages("STATE_UPDATE", in: context)
        #expect(states.isEmpty == false)
        #expect(states.last?.keys.contains("barVideoId") == true)

        self.evaluate("videoListeners.ended();", in: context)
        self.evaluate("videoListeners.ended();", in: context)

        let ends = self.messages("TRACK_ENDED", in: context)
        #expect(ends.count == 1)
        #expect(ends.first?["videoId"] as? String == "a")
    }

    @Test("The observer takes the player's own words and the media's own length")
    func observerPrefersThePlayerApiAndTheMediaElement() throws {
        let context = try #require(JSContext())
        self.evaluate(
            """
            var postedMessages = [];
            var videoListeners = {};
            var setTimeout = function() { return 1; };
            var setInterval = function() { return 1; };
            var clearInterval = function() {};
            function URL(href, base) {
                this.searchParams = { get: function(name) { return 'a'; } };
            }
            function MutationObserver(callback) { this.callback = callback; }
            MutationObserver.prototype.observe = function() {};
            var bar = {
                querySelector: function() { return { href: 'https://music.youtube.com/watch?v=a' }; },
                getAttribute: function() { return null; }
            };
            var video = {
                paused: false,
                currentTime: 12.6,
                duration: 210.4,
                addEventListener: function(name, handler) { videoListeners[name] = handler; }
            };
            var document = {
                readyState: 'complete',
                body: {},
                documentElement: {},
                querySelector: function(selector) {
                    if (selector === 'ytmusic-player-bar') { return bar; }
                    if (selector === 'ytmusic-player') {
                        return {
                            playerApi: {
                                getVideoData: function() {
                                    return { video_id: 'b', title: 'New Song', author: 'New Artist' };
                                }
                            }
                        };
                    }
                    if (selector === '.ytmusic-player-bar.title') { return { textContent: 'Old Song' }; }
                    if (selector === '.ytmusic-player-bar.byline') { return { textContent: 'Old Artist' }; }
                    if (selector === 'video') { return video; }
                    return null;
                },
                querySelectorAll: function() { return []; },
                getElementById: function() { return null; },
                addEventListener: function() {}
            };
            var window = {
                location: { href: 'https://music.youtube.com/watch?v=b' },
                webkit: {
                    messageHandlers: {
                        singletonPlayer: {
                            postMessage: function(message) { postedMessages.push(message); }
                        }
                    }
                }
            };
            """,
            in: context
        )

        self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        let states = self.messages("STATE_UPDATE", in: context)
        let state = try #require(states.last)
        // The bar is still on the previous track; the player API is already on this one.
        #expect(state["barVideoId"] as? String == "a")
        #expect(state["title"] as? String == "New Song")
        #expect(state["artist"] as? String == "New Artist")
        #expect(state["metadataFromPlayer"] as? Bool == true)
        // The progress bar's DOM values lag a swap; the media element's do not.
        #expect(state["duration"] as? Int == 210)
        #expect(state["progress"] as? Int == 13)
    }

    @Test("The observer takes the API's words when the bar's own link has moved on but its text has not")
    func observerTakesThePlayerApiTextWhenTheBarTextLags() throws {
        let context = try #require(JSContext())
        self.evaluate(
            """
            var postedMessages = [];
            var videoListeners = {};
            var setTimeout = function() { return 1; };
            var setInterval = function() { return 1; };
            var clearInterval = function() {};
            function URL(href, base) {
                this.searchParams = { get: function(name) { return 'b'; } };
            }
            function MutationObserver(callback) { this.callback = callback; }
            MutationObserver.prototype.observe = function() {};
            var video = {
                paused: false,
                currentTime: 5,
                duration: 200,
                addEventListener: function(name, handler) { videoListeners[name] = handler; }
            };
            var bar = {
                querySelector: function() { return { href: 'https://music.youtube.com/watch?v=b' }; },
                getAttribute: function() { return null; }
            };
            var document = {
                readyState: 'complete',
                body: {},
                documentElement: {},
                querySelector: function(selector) {
                    if (selector === 'ytmusic-player-bar') { return bar; }
                    if (selector === 'ytmusic-player') {
                        return {
                            playerApi: {
                                getVideoData: function() {
                                    return { video_id: 'b', title: 'New Song', author: 'New Artist' };
                                }
                            }
                        };
                    }
                    if (selector === '.ytmusic-player-bar.title') { return { textContent: 'Old Song' }; }
                    if (selector === '.ytmusic-player-bar.byline') { return { textContent: 'Old Artist' }; }
                    if (selector === 'video') { return video; }
                    return null;
                },
                querySelectorAll: function() { return []; },
                getElementById: function() { return null; },
                addEventListener: function() {}
            };
            var window = {
                location: { href: 'https://music.youtube.com/watch?v=a' },
                webkit: {
                    messageHandlers: {
                        singletonPlayer: {
                            postMessage: function(message) { postedMessages.push(message); }
                        }
                    }
                }
            };
            """,
            in: context
        )

        self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        let state = try #require(self.messages("STATE_UPDATE", in: context).last)
        // The bar's link already names the new video, but its text still renders the outgoing song.
        // Trusting the link as proof that the text caught up left the old title on screen for good.
        #expect(state["barVideoId"] as? String == "b")
        #expect(state["videoId"] as? String == "b")
        #expect(state["title"] as? String == "New Song")
        #expect(state["artist"] as? String == "New Artist")
        #expect(state["metadataFromPlayer"] as? Bool == true)
    }

    // MARK: - Harness

    private func messages(_ type: String, in context: JSContext) -> [[String: Any]] {
        guard let json = self.evaluate("JSON.stringify(postedMessages)", in: context),
              let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return decoded.filter { $0["type"] as? String == type }
    }

    /// A page with a mocked `ytmusic-player` player API and a controllable player state.
    private func makeContext() throws -> JSContext {
        let context = try #require(JSContext())
        self.evaluate(
            """
            var player = {
                playlist: [],
                index: 0,
                videoId: '',
                calls: [],
                getPlaylist: function() { return player.playlist; },
                getVideoData: function() { return { video_id: player.videoId }; },
                playVideoAt: function(index) {
                    player.calls.push({ name: 'playVideoAt', index: index });
                    player.index = index;
                    player.videoId = player.playlist[index];
                },
                playVideo: function() { player.calls.push({ name: 'playVideo' }); },
                loadVideoById: function(options, startSeconds) {
                    var videoId = (typeof options === 'string') ? options : options.videoId;
                    player.calls.push({ name: 'loadVideoById', videoId: videoId, startSeconds: startSeconds });
                    player.playlist = [];
                    player.index = 0;
                    player.videoId = videoId;
                }
            };

            var videoElement = { paused: false, play: function() {} };

            var document = {
                querySelector: function(selector) {
                    if (selector === 'ytmusic-player') {
                        return window.__hasPlayer ? { playerApi: player } : null;
                    }
                    if (selector === 'video') { return videoElement; }
                    return null;
                },
                getElementById: function() { return null; }
            };

            var window = {
                __hasPlayer: true,
                location: { href: 'https://music.youtube.com/' },
                webkit: { messageHandlers: { singletonPlayer: { postMessage: function() {} } } }
            };
            """,
            in: context
        )
        return context
    }

    private func installBridge(in context: JSContext) {
        self.evaluate(SingletonPlayerWebView.pagePlaybackBridgeScript, in: context)
    }

    private func seedPlayer(playlist: [String], index: Int, videoId: String, in context: JSContext) {
        let ids = playlist
            .map { SingletonPlayerWebView.javaScriptStringLiteral($0) }
            .joined(separator: ", ")
        self.evaluate(
            """
            player.playlist = [\(ids)];
            player.index = \(index);
            player.videoId = \(SingletonPlayerWebView.javaScriptStringLiteral(videoId));
            """,
            in: context
        )
    }

    private func play(_ videoId: String, in context: JSContext) -> String? {
        self.evaluate(SingletonPlayerWebView.pagePlayScript(videoId: videoId), in: context)
    }

    private func calls(in context: JSContext) -> [[String: Any]] {
        guard let json = self.evaluate("JSON.stringify(player.calls)", in: context),
              let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return decoded
    }

    private func callNames(in context: JSContext) -> [String] {
        self.calls(in: context).compactMap { $0["name"] as? String }
    }

    private func playerInt(_ property: String, in context: JSContext) -> Int? {
        guard let value = context.evaluateScript("player.\(property)"), !value.isUndefined else { return nil }
        return Int(value.toInt32())
    }

    @discardableResult
    private func evaluate(_ script: String, in context: JSContext) -> String? {
        context.exception = nil
        let result = context.evaluateScript(script)

        if let exception = context.exception?.toString() {
            Issue.record("JavaScript exception: \(exception)")
            return nil
        }
        return result?.toString()
    }
}
