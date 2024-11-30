import CustomDump
import HTTPTypes
import IssueReporting
import XCTest

@testable import Auth
@testable import Functions
@testable import Realtime
@testable import Supabase

final class AuthLocalStorageMock: AuthLocalStorage {
  func store(key _: String, value _: Data) throws {}

  func retrieve(key _: String) throws -> Data? {
    nil
  }

  func remove(key _: String) throws {}
}

final class SupabaseClientTests: XCTestCase {
  func testClientInitialization() async {
    final class Logger: SupabaseLogger {
      func log(message _: SupabaseLogMessage) {
        // no-op
      }
    }

    let logger = Logger()
    let customSchema = "custom_schema"
    let localStorage = AuthLocalStorageMock()
    let customHeaders: HTTPFields = [.init("header_field")!: "header_value"]

    let client = SupabaseClient(
      supabaseURL: URL(string: "https://project-ref.supabase.co")!,
      supabaseKey: "ANON_KEY",
      options: SupabaseClientOptions(
        db: SupabaseClientOptions.DatabaseOptions(schema: customSchema),
        auth: SupabaseClientOptions.AuthOptions(
          storage: localStorage,
          autoRefreshToken: false
        ),
        global: SupabaseClientOptions.GlobalOptions(
          headers: customHeaders,
          logger: logger,
          fetch: { request, bodyData in
            if let bodyData {
              try await URLSession.shared.upload(for: request, from: bodyData)
            } else {
              try await URLSession.shared.data(for: request)
            }
          }
        ),
        functions: SupabaseClientOptions.FunctionsOptions(
          region: .apNortheast1
        ),
        realtime: RealtimeClientOptions(
          headers: [.init("custom_realtime_header_key")!: "custom_realtime_header_value"],
          fetch: { request, bodyData in
            if let bodyData {
              try await URLSession.shared.upload(for: request, from: bodyData)
            } else {
              try await URLSession.shared.data(for: request)
            }
          }
        )
      )
    )

    XCTAssertEqual(client.supabaseURL.absoluteString, "https://project-ref.supabase.co")
    XCTAssertEqual(client.supabaseKey, "ANON_KEY")
    XCTAssertEqual(client.storageURL.absoluteString, "https://project-ref.supabase.co/storage/v1")
    XCTAssertEqual(client.databaseURL.absoluteString, "https://project-ref.supabase.co/rest/v1")
    XCTAssertEqual(
      client.functionsURL.absoluteString,
      "https://project-ref.supabase.co/functions/v1"
    )

    XCTAssertEqual(
	  client.headers,
      [
        .xClientInfo: "supabase-swift/\(Supabase.version)",
        .apiKey: "ANON_KEY",
        .init("header_field")!: "header_value",
        .authorization: "Bearer ANON_KEY",
      ]
    )

    XCTAssertEqual(client.functions.region, "ap-northeast-1")

    let realtimeURL = client.realtimeV2.url
    XCTAssertEqual(realtimeURL.absoluteString, "https://project-ref.supabase.co/realtime/v1")

    let realtimeOptions = client.realtimeV2.options
    let expectedRealtimeHeader = client.headers.merging([
      .init("custom_realtime_header_key")!: "custom_realtime_header_value"
    ]) { $1 }

    expectNoDifference(realtimeOptions.headers, expectedRealtimeHeader)
    XCTAssertIdentical(realtimeOptions.logger as? Logger, logger)

    XCTAssertFalse(client.auth.configuration.autoRefreshToken)
    XCTAssertEqual(client.auth.configuration.storageKey, "sb-project-ref-auth-token")

    XCTAssertNotNil(
      client.mutableState.listenForAuthEventsTask,
      "should listen for internal auth events"
    )
  }

  #if !os(Linux)
    func testClientInitWithDefaultOptionsShouldBeAvailableInNonLinux() {
      _ = SupabaseClient(
        supabaseURL: URL(string: "https://project-ref.supabase.co")!,
        supabaseKey: "ANON_KEY",
        options: .init(
          global: .init(fetch: { request, bodyData in
            if let bodyData {
              try await URLSession.shared.upload(for: request, from: bodyData)
            } else {
              try await URLSession.shared.data(for: request)
            }
          }),
          realtime: .init(fetch: { request, bodyData in
            if let bodyData {
              try await URLSession.shared.upload(for: request, from: bodyData)
            } else {
              try await URLSession.shared.data(for: request)
            }
          })
        )
      )
    }
  #endif

  func testClientInitWithCustomAccessToken() async {
    let localStorage = AuthLocalStorageMock()

    let client = SupabaseClient(
      supabaseURL: URL(string: "https://project-ref.supabase.co")!,
      supabaseKey: "ANON_KEY",
      options: .init(
        auth: .init(
          storage: localStorage,
          accessToken: { "jwt" }
        ),
        global: .init(fetch: { request, bodyData in
          if let bodyData {
            try await URLSession.shared.upload(for: request, from: bodyData)
          } else {
            try await URLSession.shared.data(for: request)
          }
        }),
        realtime: .init(fetch: { request, bodyData in
          if let bodyData {
            try await URLSession.shared.upload(for: request, from: bodyData)
          } else {
            try await URLSession.shared.data(for: request)
          }
        })
      )
    )

    XCTAssertNil(
      client.mutableState.listenForAuthEventsTask,
      "should not listen for internal auth events when using 3p authentication"
    )

    #if canImport(Darwin)
      // withExpectedIssue is unavailable on non-Darwin platform.
      withExpectedIssue {
        _ = client.auth
      }
    #endif
  }
}
