//
//  RealtimeMessageV2.swift
//
//
//  Created by Guilherme Souza on 11/01/24.
//

import Foundation
import Helpers

public struct RealtimeMessageV2: Hashable, Codable, Sendable {
  public let joinRef: String?
  public let ref: String?
  public let topic: String
  public let event: String
  public let payload: JSONObject

  public init(joinRef: String?, ref: String?, topic: String, event: String, payload: JSONObject) {
    self.joinRef = joinRef
    self.ref = ref
    self.topic = topic
    self.event = event
    self.payload = payload
  }

  var status: PushStatus? {
    payload["status"]
      .flatMap(\.stringValue)
      .flatMap(PushStatus.init(rawValue:))
  }

  public var eventType: EventType? {
    switch event {
    case ChannelEvent.system where status == .ok: .system
    case ChannelEvent.postgresChanges:
      .postgresChanges
    case ChannelEvent.broadcast:
      .broadcast
    case ChannelEvent.close:
      .close
    case ChannelEvent.error:
      .error
    case ChannelEvent.presenceDiff:
      .presenceDiff
    case ChannelEvent.presenceState:
      .presenceState
    case ChannelEvent.system
      where payload["message"]?.stringValue?.contains("access token has expired") == true:
      .tokenExpired
    case ChannelEvent.reply:
      .reply
    default:
      nil
    }
  }

  public enum EventType: Sendable {
    case system
    case postgresChanges
    case broadcast
    case close
    case error
    case presenceDiff
    case presenceState
    case tokenExpired
    case reply
  }

  private enum CodingKeys: String, CodingKey {
    case joinRef = "join_ref"
    case ref
    case topic
    case event
    case payload
  }
}

extension RealtimeMessageV2: HasRawMessage {
  public var rawMessage: RealtimeMessageV2 { self }
}
