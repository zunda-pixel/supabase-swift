//
//  Defaults.swift
//
//
//  Created by Guilherme Souza on 14/12/23.
//

import ConcurrencyExtras
import Foundation
import Helpers

let version = Helpers.version

extension PostgrestClient.Configuration {
  private static let supportedDateFormatStyles: [Date.ISO8601FormatStyle] = [
    Date.ISO8601FormatStyle(includingFractionalSeconds: true),
    Date.ISO8601FormatStyle(includingFractionalSeconds: false),
  ]

  /// The default `JSONDecoder` instance for ``PostgrestClient`` responses.
  public static let jsonDecoder = { () -> JSONDecoder in
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)

      for formatStyle in supportedDateFormatStyles {
        if let date = try? Date(string, strategy: formatStyle) {
          return date
        }
      }

      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid date format: \(string)"
      )
    }
    return decoder
  }()

  /// The default `JSONEncoder` instance for ``PostgrestClient`` requests.
  public static let jsonEncoder = { () -> JSONEncoder in
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  public static let defaultHeaders: [String: String] = [
    "X-Client-Info": "postgrest-swift/\(version)",
  ]
}
