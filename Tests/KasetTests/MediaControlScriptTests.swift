import JavaScriptCore
import Testing
@testable import Kaset

/// Tests for singleton media-control script generation and scheduling.
@Suite(.serialized, .tags(.service))
@MainActor
struct MediaControlScriptTests {
    @Test("Bootstrap script reflects pending media-control style changes")
    func bootstrapScriptReflectsPendingStyleChanges() throws {
        let singleton = SingletonPlayerWebView.shared
        let originalUseNextPrev = SettingsManager.shared.mediaControlStyle == .nextPreviousTrack
        defer {
            singleton.setMediaControlStyle(useNextPrev: originalUseNextPrev)
        }

        singleton.setMediaControlStyle(useNextPrev: true)

        let context = try #require(JSContext())
        self.evaluateBootstrapStateScript(in: context)
        self.evaluate(singleton.mediaControlBootstrapScript(), in: context)

        let storedPreference = context.evaluateScript("localStorageValues.kasetUseNextPrev")?.toString()
        let windowPreference = context.evaluateScript("String(window.__kasetUseNextPrev)")?.toString()

        #expect(storedPreference == "true")
        #expect(windowPreference == "true")
    }

    @Test("The page's own Next/Previous registrations are replaced by Kaset's forwarders")
    func pageRegistrationsArePinned() throws {
        let context = try #require(self.makeOverrideScriptContext(useNextPrev: true))

        self.evaluate(SingletonPlayerWebView.mediaControlOverrideScript, in: context)

        // What YouTube Music does on every playback event: register its own handlers again.
        self.evaluate("""
            navigator.mediaSession.setActionHandler('nexttrack', function() {
                mediaSessionCalls.push('page:next');
            });
            navigator.mediaSession.setActionHandler('previoustrack', function() {
                mediaSessionCalls.push('page:previous');
            });
        """, in: context)

        self.evaluate("mediaSessionHandlers.nexttrack(); mediaSessionHandlers.previoustrack();", in: context)

        let posted = context.evaluateScript("""
            postedMessages.map(function(message) { return message.type; }).join(',')
        """)?.toString()
        #expect(posted == "REMOTE_NEXT,REMOTE_PREVIOUS")

        let pageRan = context.evaluateScript("mediaSessionCalls.join(',')")?.toString() ?? ""
        #expect(!pageRan.contains("page:next"))
        #expect(!pageRan.contains("page:previous"))
    }

    @Test("The ±15s style takes the same slot and keeps it")
    func seekStyleReplacesTrackButtons() throws {
        let context = try #require(self.makeOverrideScriptContext(useNextPrev: true))
        self.evaluate(SingletonPlayerWebView.mediaControlOverrideScript, in: context)

        self.evaluate("""
            window.__kasetUseNextPrev = false;
            window.__kasetRefreshMediaControlStyle();
        """, in: context)

        #expect(context.evaluateScript("mediaSessionHandlers.nexttrack == null")?.toBool() == true)
        #expect(context.evaluateScript("typeof mediaSessionHandlers.seekforward")?.toString() == "function")
        #expect(context.evaluateScript("typeof mediaSessionHandlers.seekbackward")?.toString() == "function")

        // A page that registers Next again does not get it back while the ±15s style is on.
        self.evaluate("navigator.mediaSession.setActionHandler('nexttrack', function() {});", in: context)
        #expect(context.evaluateScript("mediaSessionHandlers.nexttrack == null")?.toBool() == true)
    }

    @Test("A session whose method lives on the prototype is pinned there too")
    func prototypeSessionIsPinned() throws {
        let context = try #require(JSContext())
        self.evaluate("""
            var mediaSessionCalls = [];
            var mediaSessionHandlers = {};
            function MediaSession() {}
            MediaSession.prototype.setActionHandler = function(name, handler) {
                mediaSessionHandlers[name] = handler;
                mediaSessionCalls.push(name);
            };
            var navigator = { mediaSession: new MediaSession() };
            var postedMessages = [];
            var window = {
                __kasetUseNextPrev: true,
                webkit: {
                    messageHandlers: {
                        singletonPlayer: {
                            postMessage: function(message) { postedMessages.push(message); }
                        }
                    }
                }
            };
            var document = {
                querySelector: function() { return null; },
                addEventListener: function() {}
            };
        """, in: context)

        self.evaluate(SingletonPlayerWebView.mediaControlOverrideScript, in: context)

        // Where WebKit really puts it: the accessor is on the prototype, and the page registers there.
        self.evaluate("navigator.mediaSession.setActionHandler('nexttrack', function() {});", in: context)
        self.evaluate("mediaSessionHandlers.nexttrack();", in: context)

        #expect(context.evaluateScript("postedMessages.length")?.toInt32() == 1)
        #expect(context.evaluateScript("postedMessages[0].type")?.toString() == "REMOTE_NEXT")
    }

    @Test("Pinning does not schedule animation frames")
    func pinningIsNotFrameDriven() throws {
        let context = try #require(self.makeOverrideScriptContext(useNextPrev: true))
        self.evaluate(SingletonPlayerWebView.mediaControlOverrideScript, in: context)

        // A hidden page stops producing frames; the pin must not depend on any.
        #expect(context.evaluateScript("pendingRafCallbacks.length")?.toInt32() == 0)
        #expect(context.evaluateScript("window.__kasetMediaHandlers.isPinned()")?.toBool() == true)
    }

    private func evaluateBootstrapStateScript(in context: JSContext) {
        self.evaluate(
            """
            var localStorageValues = {};
            var localStorage = {
                getItem: function(key) {
                    return Object.prototype.hasOwnProperty.call(localStorageValues, key)
                        ? localStorageValues[key]
                        : null;
                },
                setItem: function(key, value) {
                    localStorageValues[key] = value;
                }
            };
            var window = {};
            """,
            in: context
        )
    }

    private func makeOverrideScriptContext(useNextPrev: Bool) -> JSContext? {
        guard let context = JSContext() else { return nil }

        self.evaluate(
            """
            var pendingRafCallbacks = [];
            function requestAnimationFrame(callback) {
                pendingRafCallbacks.push(callback);
                return pendingRafCallbacks.length;
            }
            var mediaSessionCalls = [];
            var mediaSessionHandlers = {};
            var navigator = {
                mediaSession: {
                    setActionHandler: function(name, handler) {
                        mediaSessionHandlers[name] = handler;
                        mediaSessionCalls.push(name + ':' + (handler ? 'set' : 'clear'));
                    }
                }
            };
            var localStorageValues = { kasetUseNextPrev: '\(useNextPrev ? "true" : "false")' };
            var localStorage = {
                getItem: function(key) {
                    return Object.prototype.hasOwnProperty.call(localStorageValues, key)
                        ? localStorageValues[key]
                        : null;
                },
                setItem: function(key, value) {
                    localStorageValues[key] = value;
                }
            };
            var video = { currentTime: 0, duration: 0 };
            var document = {
                documentElement: {},
                querySelector: function(selector) {
                    if (selector === 'video') {
                        return video;
                    }
                    return null;
                }
            };
            var postedMessages = [];
            var window = {
                webkit: {
                    messageHandlers: {
                        singletonPlayer: {
                            postMessage: function(message) {
                                postedMessages.push(message);
                            }
                        }
                    }
                }
            };
            window.__kasetUseNextPrev = \(useNextPrev ? "true" : "false");
            """,
            in: context
        )

        return context
    }

    private func evaluate(_ script: String, in context: JSContext) {
        context.exception = nil
        _ = context.evaluateScript(script)

        if let exception = context.exception?.toString() {
            Issue.record("JavaScript exception: \(exception)")
        }
    }
}
