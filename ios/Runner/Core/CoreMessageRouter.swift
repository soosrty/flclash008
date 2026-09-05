import Foundation
import os

private enum AppCoreMethod: String {
  case initClash
  case getIsInit
  case validateConfig
  case getProfileConfig
  case decryptAgeConfig
  case generateAgeKeyPair
  case convertAgeSecretKeyToPublicKey
  case deleteManagedPath
  case updateGeoData
  case getCountryCode
}

private enum ConfigurationCoreMethod: String {
  case setupConfig
  case updateConfig
}

private struct CoreRoutingError: LocalizedError {
  let code: String
  let message: String

  var errorDescription: String? {
    message
  }
}

@MainActor
final class CoreMessageRouter {
  private let tunnelController: TunnelController
  private var currentRoute = CoreRoute.app
  // The observed NEVPNStatus lags the request: startTunnel and the Dart-side
  // applyProfile run concurrently, so at the moment the first setupConfig
  // arrives the tunnel usually still reports .stopped. Routing configuration on
  // the observed state alone therefore let the app core load the profile once
  // more, in parallel with the extension. desiredTunnelState records the
  // requested target so config ownership moves to the extension immediately,
  // and is cleared once the tunnel actually reports that state.
  private var desiredTunnelState: TunnelTarget?
  /// The last setupConfig call that was routed to the Network Extension only.
  /// Replayed into the app core when ownership returns to the app.
  private var lastConfigurationMessage: Data?
  private lazy var notificationCoordinator = CoreNotificationCoordinator(
    sendMessage: { [weak self] data, route in
      guard let self else {
        throw CoreRoutingError(
          code: "core_router_unavailable",
          message: "core router is unavailable"
        )
      }
      return try await self.sendCoreMessage(data, route: route)
    }
  )
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.follow.clash",
    category: "CoreMessageRouter"
  )

  init(tunnelController: TunnelController) {
    self.tunnelController = tunnelController
  }

  func updateTunnelState(_ state: TunnelTarget) {
    // An explicit start/stop intent wins over the observed state until the
    // tunnel actually reaches it. Otherwise a profile applied while the tunnel
    // is still connecting would be routed to the app core, and both cores would
    // end up owning the same profile.
    if let intent = desiredTunnelState, intent != state {
      return
    }
    desiredTunnelState = nil
    setRoute(state == .running ? .networkExtension : .app)
  }

  /// Called as soon as the app asks for the tunnel to start or stop, before the
  /// Network Extension reports its new status.
  func setDesiredTunnelState(_ state: TunnelTarget) {
    desiredTunnelState = state
    setRoute(state == .running ? .networkExtension : .app)
  }

  private func setRoute(_ route: CoreRoute) {
    guard currentRoute != route else {
      return
    }
    currentRoute = route
    log("route=\(route == .networkExtension ? "networkExtension" : "app")")
    notificationCoordinator.setDesiredRoute(route)
    guard route == .app else {
      return
    }
    // While the extension owned the profile the app core was deliberately left
    // out, so it still holds whatever config predates the tunnel. Replay the
    // last applied setup so queries served from the app core (proxy groups,
    // delay tests) do not answer from a stale profile.
    replayConfigurationIntoAppCore()
  }

  private func replayConfigurationIntoAppCore() {
    guard let data = lastConfigurationMessage else {
      return
    }
    lastConfigurationMessage = nil
    Task { [weak self] in
      guard let self else {
        return
      }
      do {
        _ = try await self.sendCoreMessage(data, route: .app)
        self.log("replayed setupConfig into app core")
      } catch {
        self.log(
          "replay setupConfig failed: \(error.localizedDescription)"
        )
      }
    }
  }

  func invoke(_ data: Data) async -> String {
    let method = methodCallName(data)
    let action = notificationCoordinator.action(for: data)
    await notificationCoordinator.prepare(for: action)
    defer {
      notificationCoordinator.finish(action)
    }

    let selectedRoute = currentRoute
    let networkExtensionActive = selectedRoute == .networkExtension

    do {
      if case .stop(let kind) = action {
        return try await sendNotificationStop(
          data,
          kind: kind,
          defaultRoute: selectedRoute
        )
      }

      let routedResult: (response: String, route: CoreRoute)
      if let method,
        let configurationMethod = ConfigurationCoreMethod(rawValue: method)
      {
        let response = try await sendConfigurationMessage(
          data,
          method: configurationMethod,
          networkExtensionActive: networkExtensionActive
        )
        routedResult = (
          response,
          networkExtensionActive ? .networkExtension : .app
        )
      } else {
        routedResult = try await sendRoutedCoreMessage(
          data,
          selectedRoute: route(
            method: method,
            defaultRoute: selectedRoute
          )
        )
      }
      if case .start(let kind) = action,
        methodResponseSucceeded(routedResult.response)
      {
        notificationCoordinator.recordSuccessfulStart(
          kind,
          data: data,
          route: routedResult.route
        )
      }
      return routedResult.response
    } catch let error as CoreRoutingError {
      return methodErrorResponse(
        data: data,
        code: error.code,
        message: error.message
      )
    } catch let error as ProviderMessageError {
      return methodErrorResponse(
        data: data,
        code: error.code,
        message: error.message
      )
    } catch {
      return methodErrorResponse(
        data: data,
        code: "core_routing_error",
        message: error.localizedDescription
      )
    }
  }

  func shutdownAppCore() async -> Bool {
    let methodCall = #"{"method":"shutdown","arguments":null}"#
    return await withCheckedContinuation { continuation in
      IOSCoreBridge.invokeMethod(methodCall) { [weak self] response in
        guard let response,
          let data = response.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          let success = payload["result"] as? Bool
        else {
          self?.log("shutdownAppCore invalid response")
          continuation.resume(returning: false)
          return
        }
        self?.log("shutdownAppCore result=\(success)")
        continuation.resume(returning: success)
      }
    }
  }

  private func sendRoutedCoreMessage(
    _ data: Data,
    selectedRoute: CoreRoute
  ) async throws -> (response: String, route: CoreRoute) {
    do {
      let response = try await sendCoreMessage(data, route: selectedRoute)
      return (response, selectedRoute)
    } catch {
      guard selectedRoute == .networkExtension else {
        throw error
      }
      log(
        "route fallback networkExtension -> app: \(error.localizedDescription)"
      )
      let response = try await sendCoreMessage(data, route: .app)
      return (response, .app)
    }
  }

  private func sendNotificationStop(
    _ data: Data,
    kind: CoreNotificationKind,
    defaultRoute: CoreRoute
  ) async throws -> String {
    let routes = notificationCoordinator.beginStop(
      kind,
      data: data,
      defaultRoute: defaultRoute
    )
    var successfulResponse: String?
    var failedResponse: String?
    var firstError: Error?

    for route in routes {
      do {
        let response = try await sendCoreMessage(data, route: route)
        guard methodResponseSucceeded(response) else {
          if failedResponse == nil {
            failedResponse = response
          }
          continue
        }
        notificationCoordinator.recordSuccessfulStop(
          kind,
          route: route
        )
        if successfulResponse == nil {
          successfulResponse = response
        }
      } catch {
        if firstError == nil {
          firstError = error
        }
      }
    }

    if let failedResponse {
      return failedResponse
    }
    if let firstError {
      throw firstError
    }
    guard let successfulResponse else {
      throw CoreRoutingError(
        code: "notification_stop_failed",
        message: "failed to stop Core notifications"
      )
    }
    return successfulResponse
  }

  private func sendConfigurationMessage(
    _ data: Data,
    method: ConfigurationCoreMethod,
    networkExtensionActive: Bool
  ) async throws -> String {
    // Single-core ownership: while the Network Extension is running it is the
    // only process that may load a profile. Applying the same config in the app
    // core too meant both processes ran hub.ApplyConfig, loaded every provider
    // and dialled every node, which is what produced the duplicated
    // "Start initial configuration" bursts and the reconnect loop.
    if networkExtensionActive {
      let networkExtensionData = method == .updateConfig
        ? try replacingArgument(
          in: data,
          key: "geo-auto-update",
          with: false
        )
        : data
      if method == .setupConfig {
        lastConfigurationMessage = data
      }
      do {
        return try await sendCoreMessage(
          networkExtensionData,
          route: .networkExtension
        )
      } catch let error as ProviderMessageError
        where error.code == "network_extension_unavailable"
      {
        // The tunnel has been asked to start but has not reached .running yet.
        // The extension reads setupParams from the App Group and applies the
        // profile itself in startTunnel, so there is nothing to do here — and
        // falling back to the app core would load the same profile twice.
        log("\(method.rawValue) deferred to Network Extension startup")
        return emptyStringResultResponse(data: data)
      }
    }

    return try await sendCoreMessage(data, route: .app)
  }

  private func sendCoreMessage(
    _ data: Data,
    route: CoreRoute
  ) async throws -> String {
    switch route {
    case .app:
      guard let methodCall = String(data: data, encoding: .utf8) else {
        throw CoreRoutingError(
          code: "invalid_method_call",
          message: "invalid method call"
        )
      }
      let response: String? = await withCheckedContinuation {
        (continuation: CheckedContinuation<String?, Never>) in
        IOSCoreBridge.invokeMethod(methodCall) { value in
          continuation.resume(returning: value)
        }
      }
      guard let response else {
        throw CoreRoutingError(
          code: "empty_response",
          message: "empty app core response"
        )
      }
      return response
    case .networkExtension:
      return try await tunnelController.sendProviderMessage(data)
    }
  }

  private func route(
    method: String?,
    defaultRoute: CoreRoute
  ) -> CoreRoute {
    guard let method,
      AppCoreMethod(rawValue: method) != nil
    else {
      return defaultRoute
    }
    return .app
  }

  private func replacingArgument(
    in data: Data,
    key: String,
    with value: Any
  ) throws -> Data {
    guard var object = methodCallObject(data),
      var arguments = object["arguments"] as? [String: Any]
    else {
      throw CoreRoutingError(
        code: "invalid_arguments",
        message: "invalid configuration arguments"
      )
    }
    arguments[key] = value
    object["arguments"] = arguments
    do {
      return try JSONSerialization.data(withJSONObject: object)
    } catch {
      throw CoreRoutingError(
        code: "invalid_arguments",
        message: error.localizedDescription
      )
    }
  }

  private func methodResponseHasEmptyStringResult(
    _ response: String
  ) -> Bool {
    guard let data = response.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
      methodResponseSucceeded(object)
    else {
      return false
    }
    return object["result"] as? String == ""
  }

  private func methodResponseSucceeded(_ response: String) -> Bool {
    guard let data = response.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else {
      return false
    }
    return methodResponseSucceeded(object)
  }

  private func methodResponseSucceeded(
    _ object: [String: Any]
  ) -> Bool {
    object["error"] == nil || object["error"] is NSNull
  }

  private func methodCallObject(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func methodCallName(_ data: Data) -> String? {
    methodCallObject(data)?["method"] as? String
  }

  private func methodCallID(_ data: Data?) -> String? {
    guard let data,
      let object = methodCallObject(data)
    else {
      return nil
    }
    return object["id"] as? String
  }

  /// A successful method response carrying an empty string result, which is how
  /// the core reports "config applied, no error".
  private func emptyStringResultResponse(data: Data?) -> String {
    var payload: [String: Any] = [
      "result": "",
      "error": NSNull(),
    ]
    if let id = methodCallID(data) {
      payload["id"] = id
    }
    guard
      let responseData = try? JSONSerialization.data(withJSONObject: payload),
      let response = String(data: responseData, encoding: .utf8)
    else {
      return #"{"result":"","error":null}"#
    }
    return response
  }

  private func methodErrorResponse(
    data: Data?,
    code: String,
    message: String
  ) -> String {
    var payload: [String: Any] = [
      "result": NSNull(),
      "error": [
        "code": code,
        "message": message,
        "details": NSNull(),
      ],
    ]
    if let id = methodCallID(data) {
      payload["id"] = id
    }

    guard let responseData = try? JSONSerialization.data(withJSONObject: payload),
      let response = String(data: responseData, encoding: .utf8)
    else {
      return #"{"result":null,"error":{"code":"serialization_error","message":"failed to serialize method response","details":null}}"#
    }
    return response
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
  }
}
