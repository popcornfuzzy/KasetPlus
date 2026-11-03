import Foundation
import Observation
import os

/// Manages authentication state for YouTube Music.
@MainActor
@Observable
final class AuthService: AuthServiceProtocol {
    /// Authentication states.
    enum State: Equatable {
        case initializing
        case loggedOut
        case loggingIn
        case loggedIn(sapisid: String)

        var isLoggedIn: Bool {
            if case .loggedIn = self { return true }
            return false
        }

        var isInitializing: Bool {
            self == .initializing
        }
    }

    /// Current authentication state.
    private(set) var state: State

    /// Flag indicating whether re-authentication is needed.
    var needsReauth: Bool = false

    private let webKitManager: WebKitManagerProtocol
    private let logger = DiagnosticsLogger.auth

    init(webKitManager: WebKitManagerProtocol = WebKitManager.shared) {
        self.webKitManager = webKitManager
        // In UI test mode with skip auth, start in logged-in state immediately
        // This avoids async delays that can cause UI test flakiness
        let isUITest = UITestConfig.isUITestMode
        let skipAuth = UITestConfig.shouldSkipAuth
        let forceLoggedOut = UITestConfig.environmentValue(for: UITestConfig.mockLoggedOutKey) == "true"
        self.logger.debug("AuthService init: isUITestMode=\(isUITest), shouldSkipAuth=\(skipAuth)")
        if isUITest, forceLoggedOut {
            self.logger.info("UI Test mode: forcing logged-out state")
            self.state = .loggedOut
        } else if isUITest, skipAuth {
            self.logger.info("UI Test mode with SkipAuth: starting in logged-in state")
            self.state = .loggedIn(sapisid: "mock-sapisid-for-ui-tests")
        } else {
            self.state = .initializing
        }
    }

    /// Starts the login flow by presenting the login sheet.
    func startLogin() {
        self.logger.info("Starting login flow")
        self.state = .loggingIn
    }

    /// Checks if the user is logged in based on existing cookies.
    /// Waits for the initial Keychain restore before reading WebKit cookies.
    func checkLoginStatus() async {
        // In UI test mode with skip auth, immediately set logged in state
        if UITestConfig.isUITestMode, UITestConfig.environmentValue(for: UITestConfig.mockLoggedOutKey) == "true" {
            self.logger.info("UI Test mode: forcing logged out state")
            self.state = .loggedOut
            return
        }

        if UITestConfig.isUITestMode, UITestConfig.shouldSkipAuth {
            self.logger.info("UI Test mode: skipping auth check, assuming logged in")
            self.state = .loggedIn(sapisid: "mock-sapisid-for-ui-tests")
            return
        }

        self.logger.debug("Checking login status from cookies")

        await self.webKitManager.waitForInitialCookieRestore()
        self.logger.debug("Initial cookie restore completed, checking auth cookies")

        // Log detailed cookie info for debugging
        #if DEBUG
            await self.webKitManager.logAuthCookies()
        #endif

        if let sapisid = await self.webKitManager.getSAPISID() {
            self.logger.info("Found SAPISID cookie after initial restore, user is logged in")
            self.state = .loggedIn(sapisid: sapisid)
            self.needsReauth = false
            return
        }

        self.logger.info("No SAPISID cookie found after initial restore, user is logged out")
        self.state = .loggedOut
    }

    /// Confirms the restored cookies are a session the API still accepts.
    ///
    /// Cookie presence is not a login: an archive can outlive the account it describes (a restore after
    /// signing out, a session revoked elsewhere), and the app then opened on the main window with an
    /// account row it could never fill and nothing that would play. The account list is the cheapest
    /// authenticated answer — every signed-in account has at least one entry, so an empty one means the
    /// request was served without an account.
    ///
    /// Network and decoding failures deliberately keep the session: they say nothing about whether it is
    /// valid, and signing a reader out because the Wi-Fi is down would be worse than a retry.
    func validateSession(using client: any YTMusicClientProtocol) async {
        guard self.state.isLoggedIn else { return }

        do {
            let accounts = try await client.fetchAccountsList().accounts
            guard accounts.isEmpty else { return }
            self.logger.warning("Session cookies present but no account was returned, signing out")
            await self.clearRejectedSession()
        } catch let error as YTMusicError where error.requiresReauth {
            self.logger.warning("Restored session was rejected, signing out: \(error.localizedDescription)")
            await self.clearRejectedSession()
        } catch {
            self.logger.warning("Could not validate the restored session: \(error.localizedDescription)")
        }
    }

    /// Ends a session whose cookies the API no longer accepts.
    ///
    /// The cookies go with the state. Keeping them in the Keychain is what let the next launch look
    /// signed in again, so the reader had no way back to the welcome screen.
    private func clearRejectedSession() async {
        await self.webKitManager.clearAllData()
        self.state = .loggedOut
        self.needsReauth = false
    }

    /// Called when a session expires (e.g., 401/403 from API).
    func sessionExpired() {
        self.logger.warning("Session expired, requiring re-authentication")
        self.state = .loggedOut
        self.needsReauth = true
    }

    /// Signs out the user by clearing all cookies and data.
    func signOut() async {
        self.logger.info("Signing out user")

        await self.webKitManager.clearAllData()

        self.state = .loggedOut
        self.needsReauth = false

        self.logger.info("User signed out successfully")
    }

    /// Called when login completes successfully (from LoginSheet observation).
    func completeLogin(sapisid: String) {
        self.logger.info("Login completed successfully")
        self.state = .loggedIn(sapisid: sapisid)
        self.needsReauth = false
    }
}
