//
//  AuthClientMultipleInstancesTests.swift
//
//
//  Created by Guilherme Souza on 05/07/24.
//

import TestHelpers
import XCTest

@testable import Auth

final class AuthClientMultipleInstancesTests: XCTestCase {
  func testMultipleAuthClientInstances() {
    let url = URL(string: "http://localhost:54321/auth")!

    let client1Storage = InMemoryLocalStorage()
    let client2Storage = InMemoryLocalStorage()

    let client1 = AuthClient(
      configuration: AuthClient.Configuration(
        url: url,
        localStorage: client1Storage,
        logger: nil,
        fetch: { request, bodyData in
          if let bodyData {
            try await URLSession.shared.upload(for: request, from: bodyData)
          } else {
            try await URLSession.shared.data(for: request)
          }
        }
      )
    )

    let client2 = AuthClient(
      configuration: AuthClient.Configuration(
        url: url,
        localStorage: client2Storage,
        logger: nil,
        fetch: { request, bodyData in
          if let bodyData {
            try await URLSession.shared.upload(for: request, from: bodyData)
          } else {
            try await URLSession.shared.data(for: request)
          }
        }
      )
    )

    XCTAssertNotEqual(client1.clientID, client2.clientID)

    XCTAssertIdentical(
      Dependencies[client1.clientID].configuration.localStorage as? InMemoryLocalStorage,
      client1Storage
    )
    XCTAssertIdentical(
      Dependencies[client2.clientID].configuration.localStorage as? InMemoryLocalStorage,
      client2Storage
    )
  }
}
