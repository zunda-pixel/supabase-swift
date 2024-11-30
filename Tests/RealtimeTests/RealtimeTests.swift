import ConcurrencyExtras
import CustomDump
import HTTPTypes
import Helpers
import InlineSnapshotTesting
import TestHelpers
import XCTest

@testable import Realtime

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class RealtimeTests: XCTestCase {
  let url = URL(string: "https://localhost:54321/realtime/v1")!
  let apiKey = "anon.api.key"

  override func invokeTest() {
    withMainSerialExecutor {
      super.invokeTest()
    }
  }

  var ws: MockWebSocketClient!
  var http: HTTPClientMock!
  var sut: RealtimeClientV2!

  override func setUp() {
    super.setUp()

    ws = MockWebSocketClient()
    http = HTTPClientMock()
    sut = RealtimeClientV2(
      url: url,
      options: RealtimeClientOptions(
        headers: [.apiKey: apiKey],
        heartbeatInterval: 1,
        reconnectDelay: 1,
        timeoutInterval: 2,
        fetch: { request, bodyData in
          if let bodyData {
            try await URLSession.shared.upload(for: request, from: bodyData)
          } else {
            try await URLSession.shared.data(for: request)
          }
        }
      ),
      ws: ws,
      http: http
    )
  }

  override func tearDown() {
    sut.disconnect()

    super.tearDown()
  }

  func testBehavior() async throws {
    let channel = sut.channel("public:messages")
    var subscriptions: Set<ObservationToken> = []

    channel.onPostgresChange(InsertAction.self, table: "messages") { _ in
    }
    .store(in: &subscriptions)

    channel.onPostgresChange(UpdateAction.self, table: "messages") { _ in
    }
    .store(in: &subscriptions)

    channel.onPostgresChange(DeleteAction.self, table: "messages") { _ in
    }
    .store(in: &subscriptions)

    let socketStatuses = LockIsolated([RealtimeClientStatus]())

    sut.onStatusChange { status in
      socketStatuses.withValue { $0.append(status) }
    }
    .store(in: &subscriptions)

    await connectSocketAndWait()

    XCTAssertEqual(socketStatuses.value, [.disconnected, .connecting, .connected])

    let messageTask = sut.mutableState.messageTask
    XCTAssertNotNil(messageTask)

    let heartbeatTask = sut.mutableState.heartbeatTask
    XCTAssertNotNil(heartbeatTask)

    let channelStatuses = LockIsolated([RealtimeChannelStatus]())
    channel.onStatusChange { status in
      channelStatuses.withValue {
        $0.append(status)
      }
    }
    .store(in: &subscriptions)

    ws.mockReceive(.messagesSubscribed)
    await channel.subscribe()

    assertInlineSnapshot(of: ws.sentMessages, as: .json) {
      """
      [
        {
          "event" : "phx_join",
          "join_ref" : "1",
          "payload" : {
            "access_token" : "anon.api.key",
            "config" : {
              "broadcast" : {
                "ack" : false,
                "self" : false
              },
              "postgres_changes" : [
                {
                  "event" : "INSERT",
                  "schema" : "public",
                  "table" : "messages"
                },
                {
                  "event" : "UPDATE",
                  "schema" : "public",
                  "table" : "messages"
                },
                {
                  "event" : "DELETE",
                  "schema" : "public",
                  "table" : "messages"
                }
              ],
              "presence" : {
                "key" : ""
              },
              "private" : false
            }
          },
          "ref" : "1",
          "topic" : "realtime:public:messages"
        }
      ]
      """
    }
  }

  func testSubscribeTimeout() async throws {
    let channel = sut.channel("public:messages")
    let joinEventCount = LockIsolated(0)

    ws.on { message in
      if message.event == "heartbeat" {
        return RealtimeMessageV2(
          joinRef: message.joinRef,
          ref: message.ref,
          topic: "phoenix",
          event: "phx_reply",
          payload: [
            "response": [:],
            "status": "ok",
          ]
        )
      }

      if message.event == "phx_join" {
        joinEventCount.withValue { $0 += 1 }

        // Skip first join.
        if joinEventCount.value == 2 {
          return .messagesSubscribed
        }
      }

      return nil
    }

    await connectSocketAndWait()
    await channel.subscribe()

    try? await Task.sleep(nanoseconds: NSEC_PER_SEC * 2)

    assertInlineSnapshot(of: ws.sentMessages.filter { $0.event == "phx_join" }, as: .json) {
      """
      [
        {
          "event" : "phx_join",
          "join_ref" : "1",
          "payload" : {
            "access_token" : "anon.api.key",
            "config" : {
              "broadcast" : {
                "ack" : false,
                "self" : false
              },
              "postgres_changes" : [

              ],
              "presence" : {
                "key" : ""
              },
              "private" : false
            }
          },
          "ref" : "1",
          "topic" : "realtime:public:messages"
        },
        {
          "event" : "phx_join",
          "join_ref" : "2",
          "payload" : {
            "access_token" : "anon.api.key",
            "config" : {
              "broadcast" : {
                "ack" : false,
                "self" : false
              },
              "postgres_changes" : [

              ],
              "presence" : {
                "key" : ""
              },
              "private" : false
            }
          },
          "ref" : "2",
          "topic" : "realtime:public:messages"
        }
      ]
      """
    }
  }

  func testHeartbeat() async throws {
    let expectation = expectation(description: "heartbeat")
    expectation.expectedFulfillmentCount = 2

    ws.on { message in
      if message.event == "heartbeat" {
        expectation.fulfill()
        return RealtimeMessageV2(
          joinRef: message.joinRef,
          ref: message.ref,
          topic: "phoenix",
          event: "phx_reply",
          payload: [
            "response": [:],
            "status": "ok",
          ]
        )
      }

      return nil
    }

    await connectSocketAndWait()

    await fulfillment(of: [expectation], timeout: 3)
  }

  func testHeartbeat_whenNoResponse_shouldReconnect() async throws {
    let sentHeartbeatExpectation = expectation(description: "sentHeartbeat")

    ws.on {
      if $0.event == "heartbeat" {
        sentHeartbeatExpectation.fulfill()
      }

      return nil
    }

    let statuses = LockIsolated<[RealtimeClientStatus]>([])

    Task {
      for await status in sut.statusChange {
        statuses.withValue {
          $0.append(status)
        }
      }
    }
    await Task.yield()
    await connectSocketAndWait()

    await fulfillment(of: [sentHeartbeatExpectation], timeout: 2)

    let pendingHeartbeatRef = sut.mutableState.pendingHeartbeatRef
    XCTAssertNotNil(pendingHeartbeatRef)

    // Wait until next heartbeat
    try await Task.sleep(nanoseconds: NSEC_PER_SEC * 2)

    // Wait for reconnect delay
    try await Task.sleep(nanoseconds: NSEC_PER_SEC * 1)

    XCTAssertEqual(
      statuses.value,
      [
        .disconnected,
        .connecting,
        .connected,
        .disconnected,
        .connecting,
      ]
    )
  }

  func testBroadcastWithHTTP() async throws {
    await http.when { request, bodyData in
      request.url!.path.hasSuffix("broadcast")
    } return: { _, _ in
      (
        Data("{}".utf8),
        HTTPResponse(status: .init(code: 200))
      )
    }

    let channel = sut.channel("public:messages") {
      $0.broadcast.acknowledgeBroadcasts = true
    }

    try await channel.broadcast(event: "test", message: ["value": 42])

    let request = await http.receivedRequests.last
    var urlRequest = request.map { URLRequest(httpRequest: $0.0) }
    urlRequest??.httpBody = request?.1

    assertInlineSnapshot(of: urlRequest as? URLRequest, as: .raw(pretty: true)) {
      """
      POST https://localhost:54321/realtime/v1/api/broadcast
      Authorization: Bearer anon.api.key
      Content-Type: application/json
      apiKey: anon.api.key

      {
        "messages" : [
          {
            "event" : "test",
            "payload" : {
              "value" : 42
            },
            "private" : false,
            "topic" : "realtime:public:messages"
          }
        ]
      }
      """
    }
  }

  private func connectSocketAndWait() async {
    ws.mockConnect(.connected)
    await sut.connect()
  }
}

extension RealtimeMessageV2 {
  static let messagesSubscribed = Self(
    joinRef: nil,
    ref: "2",
    topic: "realtime:public:messages",
    event: "phx_reply",
    payload: [
      "response": [
        "postgres_changes": [
          ["id": 43_783_255, "event": "INSERT", "schema": "public", "table": "messages"],
          ["id": 124_973_000, "event": "UPDATE", "schema": "public", "table": "messages"],
          ["id": 85_243_397, "event": "DELETE", "schema": "public", "table": "messages"],
        ]
      ],
      "status": "ok",
    ]
  )
}
