import Foundation
import Testing
@testable import Kaset

/// Tests for AuthService.
@Suite(.serialized, .tags(.service))
@MainActor
struct AuthServiceTests {
    var authService: AuthService
    var mockWebKitManager: MockWebKitManager

    init() {
        self.mockWebKitManager = MockWebKitManager()
        self.authService = AuthService(webKitManager: self.mockWebKitManager)
    }

    @Test("Initial state is initializing")
    func initialState() {
        #expect(self.authService.state == .initializing)
        #expect(self.authService.needsReauth == false)
    }

    @Test("State isInitializing property")
    func isInitializing() {
        #expect(self.authService.state.isInitializing == true)
        #expect(self.authService.state.isLoggedIn == false)

        self.authService.completeLogin(sapisid: "test")
        #expect(self.authService.state.isInitializing == false)
        #expect(self.authService.state.isLoggedIn == true)
    }

    @Test("Start login transitions to loggingIn state")
    func startLogin() {
        self.authService.startLogin()
        #expect(self.authService.state == .loggingIn)
    }

    @Test("Complete login transitions to loggedIn state")
    func completeLogin() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        #expect(self.authService.state == .loggedIn(sapisid: "test-sapisid"))
        #expect(self.authService.needsReauth == false)
    }

    @Test("Session expired transitions to loggedOut and sets needsReauth")
    func sessionExpired() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        self.authService.sessionExpired()

        #expect(self.authService.state == .loggedOut)
        #expect(self.authService.needsReauth == true)
    }

    @Test("State isLoggedIn property")
    func stateIsLoggedIn() {
        #expect(self.authService.state.isLoggedIn == false)

        self.authService.completeLogin(sapisid: "test")
        #expect(self.authService.state.isLoggedIn == true)
    }

    @Test("Sign out clears state and calls mock")
    func signOut() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        self.authService.needsReauth = true

        await self.authService.signOut()

        #expect(self.authService.state == .loggedOut)
        #expect(self.authService.needsReauth == false)
        #expect(self.mockWebKitManager.clearAllDataCalled == true)
    }

    @Test("Check login status waits for restore and logs in from SAPISID")
    func checkLoginStatusLogsIn() async {
        self.authService.needsReauth = true
        self.mockWebKitManager.sapisidValue = "persisted-sapisid"

        await self.authService.checkLoginStatus()

        #expect(self.authService.state == .loggedIn(sapisid: "persisted-sapisid"))
        #expect(self.authService.needsReauth == false)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCalled == true)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCallCount == 1)
        #expect(self.mockWebKitManager.getSAPISIDCallCount == 1)
        #expect(self.mockWebKitManager.callSequence == ["waitForInitialCookieRestore", "getSAPISID"])
    }

    @Test("Check login status waits for restore and logs out when SAPISID is missing")
    func checkLoginStatusLogsOut() async {
        await self.authService.checkLoginStatus()

        #expect(self.authService.state == .loggedOut)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCalled == true)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCallCount == 1)
        #expect(self.mockWebKitManager.getSAPISIDCallCount == 1)
        #expect(self.mockWebKitManager.callSequence == ["waitForInitialCookieRestore", "getSAPISID"])
    }

    @Test("Validating a restored session keeps a real account signed in")
    func validateSessionKeepsRealAccount() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        let client = MockYTMusicClient()
        client.accountsListResponse = AccountsListResponse(
            googleEmail: "test@gmail.com",
            accounts: [UserAccount(
                id: "primary",
                name: "Test",
                handle: nil,
                brandId: nil,
                thumbnailURL: nil,
                isSelected: true
            )]
        )

        await self.authService.validateSession(using: client)

        #expect(self.authService.state == .loggedIn(sapisid: "test-sapisid"))
        #expect(self.mockWebKitManager.clearAllDataCalled == false)
    }

    @Test("Validating a restored session signs out when no account comes back")
    func validateSessionSignsOutWithoutAccounts() async {
        self.authService.completeLogin(sapisid: "stale-sapisid")
        let client = MockYTMusicClient()

        await self.authService.validateSession(using: client)

        #expect(self.authService.state == .loggedOut)
        #expect(self.authService.needsReauth == false)
        #expect(self.mockWebKitManager.clearAllDataCalled == true)
    }

    @Test("Validating a restored session signs out when the API rejects it")
    func validateSessionSignsOutOnAuthError() async {
        self.authService.completeLogin(sapisid: "stale-sapisid")
        let client = MockYTMusicClient()
        client.shouldThrowError = YTMusicError.authExpired

        await self.authService.validateSession(using: client)

        #expect(self.authService.state == .loggedOut)
        #expect(self.mockWebKitManager.clearAllDataCalled == true)
    }

    @Test("Validating a restored session keeps it when the network is down")
    func validateSessionKeepsSessionOnNetworkFailure() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        let client = MockYTMusicClient()
        client.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.authService.validateSession(using: client)

        #expect(self.authService.state == .loggedIn(sapisid: "test-sapisid"))
        #expect(self.mockWebKitManager.clearAllDataCalled == false)
    }

    @Test("State equality")
    func stateEquatable() {
        let state1 = AuthService.State.loggedOut
        let state2 = AuthService.State.loggedOut
        #expect(state1 == state2)

        let state3 = AuthService.State.loggedIn(sapisid: "test")
        let state4 = AuthService.State.loggedIn(sapisid: "test")
        #expect(state3 == state4)

        let state5 = AuthService.State.loggedIn(sapisid: "different")
        #expect(state3 != state5)
    }
}
