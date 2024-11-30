import ConcurrencyExtras
import Foundation
import HTTPTypes
import HTTPTypesFoundation
import Helpers

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

let version = Helpers.version

/// An actor representing a client for invoking functions.
public final class FunctionsClient: Sendable {
  /// Fetch handler used to make requests.
  public typealias FetchHandler = @Sendable (
    _ request: HTTPRequest,
    _ bodyData: Data?
  ) async throws -> (Data, HTTPResponse)

  /// The base URL for the functions.
  let url: URL

  /// The Region to invoke the functions in.
  let region: String?

  struct MutableState {
    /// Headers to be included in the requests.
    var headers = HTTPFields()
  }

  private let http: any HTTPClientType
  private let mutableState = LockIsolated(MutableState())

  var headers: HTTPFields {
    mutableState.headers
  }

  /// Initializes a new instance of `FunctionsClient`.
  ///
  /// - Parameters:
  ///   - url: The base URL for the functions.
  ///   - headers: Headers to be included in the requests. (Default: empty dictionary)
  ///   - region: The Region to invoke the functions in.
  ///   - logger: SupabaseLogger instance to use.
  ///   - fetch: The fetch handler used to make requests.
  @_disfavoredOverload
  public convenience init(
    url: URL,
    headers: HTTPFields = [:],
    region: String? = nil,
    logger: (any SupabaseLogger)? = nil,
    fetch: @escaping FetchHandler
  ) {
    var interceptors: [any HTTPClientInterceptor] = []
    if let logger {
      interceptors.append(LoggerInterceptor(logger: logger))
    }

    let http = HTTPClient(fetch: fetch, interceptors: interceptors)

    self.init(url: url, headers: headers, region: region, http: http)
  }

  init(
    url: URL,
    headers: HTTPFields,
    region: String?,
    http: any HTTPClientType
  ) {
    self.url = url
    self.region = region
    self.http = http

    mutableState.withValue {
      $0.headers = headers
      if $0.headers[.xClientInfo] == nil {
        $0.headers[.xClientInfo] = "functions-swift/\(version)"
      }
    }
  }

  /// Initializes a new instance of `FunctionsClient`.
  ///
  /// - Parameters:
  ///   - url: The base URL for the functions.
  ///   - headers: Headers to be included in the requests. (Default: empty dictionary)
  ///   - region: The Region to invoke the functions in.
  ///   - logger: SupabaseLogger instance to use.
  ///   - fetch: The fetch handler used to make requests.
  public convenience init(
    url: URL,
    headers: HTTPFields = [:],
    region: FunctionRegion? = nil,
    logger: (any SupabaseLogger)? = nil,
    fetch: @escaping FetchHandler
  ) {
    self.init(url: url, headers: headers, region: region?.rawValue, logger: logger, fetch: fetch)
  }

  /// Updates the authorization header.
  ///
  /// - Parameter token: The new JWT token sent in the authorization header.
  public func setAuth(token: String?) {
    mutableState.withValue {
      if let token {
        $0.headers[.authorization] = "Bearer \(token)"
      } else {
        $0.headers[.authorization] = nil
      }
    }
  }

  /// Invokes a function and decodes the response.
  ///
  /// - Parameters:
  ///   - functionName: The name of the function to invoke.
  ///   - options: Options for invoking the function. (Default: empty `FunctionInvokeOptions`)
  ///   - decode: A closure to decode the response data and HTTPURLResponse into a `Response`
  /// object.
  /// - Returns: The decoded `Response` object.
  public func invoke<Response>(
    _ functionName: String,
    options: FunctionInvokeOptions = .init(),
    decode: (Data, HTTPResponse) throws -> Response
  ) async throws -> Response {
    let (data, response) = try await rawInvoke(
      functionName: functionName, invokeOptions: options
    )
    return try decode(data, response)
  }

  /// Invokes a function and decodes the response as a specific type.
  ///
  /// - Parameters:
  ///   - functionName: The name of the function to invoke.
  ///   - options: Options for invoking the function. (Default: empty `FunctionInvokeOptions`)
  ///   - decoder: The JSON decoder to use for decoding the response. (Default: `JSONDecoder()`)
  /// - Returns: The decoded object of type `T`.
  public func invoke<T: Decodable>(
    _ functionName: String,
    options: FunctionInvokeOptions = .init(),
    decoder: JSONDecoder = JSONDecoder()
  ) async throws -> T {
    try await invoke(functionName, options: options) { data, _ in
      try decoder.decode(T.self, from: data)
    }
  }

  /// Invokes a function without expecting a response.
  ///
  /// - Parameters:
  ///   - functionName: The name of the function to invoke.
  ///   - options: Options for invoking the function. (Default: empty `FunctionInvokeOptions`)
  public func invoke(
    _ functionName: String,
    options: FunctionInvokeOptions = .init()
  ) async throws {
    try await invoke(functionName, options: options) { _, _ in () }
  }

  private func rawInvoke(
    functionName: String,
    invokeOptions: FunctionInvokeOptions
  ) async throws -> (Data, HTTPResponse) {
    let (request, bodyData) = buildRequest(functionName: functionName, options: invokeOptions)
    let (data, response) = try await http.send(request, bodyData)

    guard 200..<300 ~= response.status.code else {
      throw FunctionsError.httpError(code: response.status.code, data: data)
    }

    let isRelayError = response.headerFields[.xRelayError] == "true"
    if isRelayError {
      throw FunctionsError.relayError
    }

    return (data, response)
  }

  /// Invokes a function with streamed response.
  ///
  /// Function MUST return a `text/event-stream` content type for this method to work.
  ///
  /// - Parameters:
  ///   - functionName: The name of the function to invoke.
  ///   - invokeOptions: Options for invoking the function.
  /// - Returns: A stream of Data.
  ///
  /// - Warning: Experimental method.
  /// - Note: This method doesn't use the same underlying `URLSession` as the remaining methods in the library.
  public func _invokeWithStreamedResponse(
    _ functionName: String,
    options invokeOptions: FunctionInvokeOptions = .init()
  ) -> AsyncThrowingStream<Data, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let delegate = StreamResponseDelegate(continuation: continuation)

    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    let (request, bodyData) = buildRequest(functionName: functionName, options: invokeOptions)
    var urlRequest = URLRequest(httpRequest: request)!
    urlRequest.httpBody = bodyData

    let task = session.dataTask(with: urlRequest)
    task.resume()

    continuation.onTermination = { _ in
      task.cancel()

      // Hold a strong reference to delegate until continuation terminates.
      _ = delegate
    }

    return stream
  }

  private func buildRequest(
    functionName: String,
    options: FunctionInvokeOptions
  ) -> (HTTPRequest, Data?) {
    var request = HTTPRequest(
      method: options.httpMethod ?? .post,
      url: url
        .appendingPathComponent(functionName)
        .appendingQueryItems(options.query),
      headerFields: mutableState.headers.merging(options.headers) { $1 }
    )

    if options.body != nil && request.headerFields[.contentType] == nil {
      request.headerFields[.contentType] = "application/json"
    }

    if let region = options.region ?? region {
      request.headerFields[.xRegion] = region
    }

    return (request, options.body)
  }
}

final class StreamResponseDelegate: NSObject, URLSessionDataDelegate, Sendable {
  let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  init(continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
    self.continuation = continuation
  }

  func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
    continuation.yield(data)
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
    continuation.finish(throwing: error)
  }

  func urlSession(
    _: URLSession,
    dataTask _: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let httpResponse = response as? HTTPURLResponse else {
      continuation.finish(throwing: URLError(.badServerResponse))
      return
    }

    guard 200..<300 ~= httpResponse.statusCode else {
      let error = FunctionsError.httpError(code: httpResponse.statusCode, data: Data())
      continuation.finish(throwing: error)
      return
    }

    let isRelayError = httpResponse.value(forHTTPHeaderField: "x-relay-error") == "true"
    if isRelayError {
      continuation.finish(throwing: FunctionsError.relayError)
    }
    completionHandler(.allow)
  }
}
