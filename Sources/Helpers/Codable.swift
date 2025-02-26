//
//  Codable.swift
//  Supabase
//
//  Created by Guilherme Souza on 20/01/25.
//

import ConcurrencyExtras
import Foundation

extension JSONDecoder {
  private static let supportedDateFormatStyles: [Date.ISO8601FormatStyle] = [
    Date.ISO8601FormatStyle(includingFractionalSeconds: true),
    Date.ISO8601FormatStyle(includingFractionalSeconds: false),
  ]

  /// Default `JSONDecoder` for decoding types from Supabase.
  package static let `default`: JSONDecoder = {
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
}
