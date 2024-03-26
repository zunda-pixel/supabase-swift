//
//  AuthClientTests.swift
//
//
//  Created by Guilherme Souza on 23/10/23.
//

import XCTest
@_spi(Internal) @testable import _Helpers
import ConcurrencyExtras
import TestHelpers

@testable import Auth

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class AuthClientTests: XCTestCase {
  var eventEmitter: Auth.EventEmitter!
  var sessionManager: SessionManager!

  var api: APIClient!
  var sut: AuthClient!

  override func invokeTest() {
    withMainSerialExecutor {
      super.invokeTest()
    }
  }

  override func setUp() {
    super.setUp()

    eventEmitter = .mock
    sessionManager = .mock
    api = .mock
  }

  override func tearDown() {
    super.tearDown()

    let completion = { [weak sut] in
      XCTAssertNil(sut, "sut should not leak")
    }

    defer { completion() }

    sut = nil
    eventEmitter = nil
    sessionManager = nil
  }

  func testOnAuthStateChanges() async {
    eventEmitter = .live
    let session = Session.validSession
    sessionManager.session = { @Sendable _ in session }

    sut = makeSUT()

    let events = LockIsolated([AuthChangeEvent]())

    let handle = await sut.onAuthStateChange { event, _ in
      events.withValue {
        $0.append(event)
      }
    }

    XCTAssertEqual(events.value, [.initialSession])

    handle.remove()
  }

  func testAuthStateChanges() async throws {
    eventEmitter = .live
    let session = Session.validSession
    sessionManager.session = { @Sendable _ in session }

    sut = makeSUT()

    let stateChange = await sut.authStateChanges.first { _ in true }
    XCTAssertEqual(stateChange?.event, .initialSession)
    XCTAssertEqual(stateChange?.session, session)
  }

  func testSignOut() async throws {
    let emitReceivedEvents = LockIsolated<[AuthChangeEvent]>([])

    eventEmitter.emit = { @Sendable event, _, _ in
      emitReceivedEvents.withValue {
        $0.append(event)
      }
    }
    sessionManager.session = { @Sendable _ in .validSession }
    sessionManager.remove = { @Sendable in }
    api.execute = { @Sendable _ in .stub() }

    sut = makeSUT()

    try await sut.signOut()

    do {
      _ = try await sut.session
    } catch AuthError.sessionNotFound {
    } catch {
      XCTFail("Unexpected error.")
    }

    XCTAssertEqual(emitReceivedEvents.value, [.signedOut])
  }

  func testSignOutWithOthersScopeShouldNotRemoveLocalSession() async throws {
    let removeCalled = LockIsolated(false)
    sessionManager.remove = { @Sendable in removeCalled.setValue(true) }
    sessionManager.session = { @Sendable _ in .validSession }
    api.execute = { @Sendable _ in .stub() }

    sut = makeSUT()

    try await sut.signOut(scope: .others)

    XCTAssertFalse(removeCalled.value)
  }

  func testSignOutShouldRemoveSessionIfUserIsNotFound() async throws {
    let emitReceivedEvents = LockIsolated<[(AuthChangeEvent, Session?)]>([])

    eventEmitter.emit = { @Sendable event, session, _ in
      emitReceivedEvents.withValue {
        $0.append((event, session))
      }
    }

    let removeCallCount = LockIsolated(0)
    sessionManager.remove = { @Sendable in
      removeCallCount.withValue { $0 += 1 }
    }
    sessionManager.session = { @Sendable _ in .validSession }
    api.execute = { @Sendable _ in throw AuthError.api(AuthError.APIError(code: 404)) }

    sut = makeSUT()

    do {
      try await sut.signOut()
    } catch AuthError.api {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let emitedParams = emitReceivedEvents.value
    let emitedEvents = emitedParams.map(\.0)
    let emitedSessions = emitedParams.map(\.1)

    XCTAssertEqual(emitedEvents, [.signedOut])
    XCTAssertEqual(emitedSessions.count, 1)
    XCTAssertNil(emitedSessions[0])

    XCTAssertEqual(removeCallCount.value, 1)
  }

  func testSignOutShouldRemoveSessionIfJWTIsInvalid() async throws {
    let emitReceivedEvents = LockIsolated<[(AuthChangeEvent, Session?)]>([])

    eventEmitter.emit = { @Sendable event, session, _ in
      emitReceivedEvents.withValue {
        $0.append((event, session))
      }
    }

    let removeCallCount = LockIsolated(0)
    sessionManager.remove = { @Sendable in
      removeCallCount.withValue { $0 += 1 }
    }
    sessionManager.session = { @Sendable _ in .validSession }
    api.execute = { @Sendable _ in throw AuthError.api(AuthError.APIError(code: 401)) }

    sut = makeSUT()

    do {
      try await sut.signOut()
    } catch AuthError.api {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let emitedParams = emitReceivedEvents.value
    let emitedEvents = emitedParams.map(\.0)
    let emitedSessions = emitedParams.map(\.1)

    XCTAssertEqual(emitedEvents, [.signedOut])
    XCTAssertEqual(emitedSessions.count, 1)
    XCTAssertNil(emitedSessions[0])

    XCTAssertEqual(removeCallCount.value, 1)
  }

  private func makeSUT() -> AuthClient {
    let configuration = AuthClient.Configuration(
      url: clientURL,
      headers: ["Apikey": "dummy.api.key"],
      localStorage: InMemoryLocalStorage(),
      logger: nil
    )

    let sut = AuthClient(
      configuration: configuration,
      sessionManager: sessionManager,
      codeVerifierStorage: .mock,
      api: api,
      eventEmitter: eventEmitter,
      sessionStorage: .mock,
      logger: nil
    )

    return sut
  }
}

extension Response {
  static func stub(_ body: String = "", code: Int = 200) -> Response {
    Response(
      data: body.data(using: .utf8)!,
      response: HTTPURLResponse(
        url: clientURL,
        statusCode: code,
        httpVersion: nil,
        headerFields: nil
      )!
    )
  }
}
