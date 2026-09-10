#if canImport(os)
  import os
#else
  public struct OSLogType: Sendable, Equatable {
    public let rawValue: UInt8

    private init(_ rawValue: UInt8) { self.rawValue = rawValue }

    public static let debug = Self(0)
    public static let info = Self(1)
    public static let `default` = Self(2)
    public static let error = Self(3)
    public static let fault = Self(4)
  }
#endif

/// Selects which registered implementation is active for a container.
/// A non-live context falls back to the live registration when no context-specific registration exists.
public enum DependencyContext: String, Sendable, Hashable, CustomStringConvertible {
  case live
  case preview
  case test

  public var description: String { rawValue }
}

/// A type-safe identity for one dependency value.
/// Keep keys in the composition layer; feature and business types do not need to import Weaver.
public protocol DependencyKey: Sendable {
  associatedtype Value: Sendable
}

public enum DependencyLifetime: Sendable {
  case singleton
  case weakReference
  case transient
}

struct DependencyRegistration: Sendable {
  let lifetime: DependencyLifetime
  let factory: @Sendable (DependencyResolver) async throws -> any Sendable
  let keyName: String
  let dependencies: Set<AnyDependencyKey>
}

struct DependencyRegistrationSnapshot: Sendable {
  let context: DependencyContext
  let registrations: [AnyDependencyKey: DependencyRegistration]
  let keys: Set<AnyDependencyKey>

  init(
    context: DependencyContext,
    registrations: [AnyDependencyKey: DependencyRegistration]
  ) {
    self.context = context
    self.registrations = registrations
    self.keys = Set(registrations.keys)
  }
}

/// Resolver access is intentionally limited to composition factories.
/// Do not pass a resolver or container into feature/business objects.
public protocol DependencyResolver: Sendable {
  func resolve<Key: DependencyKey>(_ key: Key.Type) async throws -> Key.Value
}

public protocol DependencyModule: Sendable {
  func register(in registry: DependencyRegistry) async
}

public protocol DependencyLogger: Sendable {
  func log(_ message: String, level: OSLogType) async
  func recordResolutionFailure(for key: String, error: Error) async
}

public actor DefaultDependencyLogger: DependencyLogger {
  public nonisolated static let shared = DefaultDependencyLogger()

  #if canImport(os)
    private let logger = Logger(subsystem: "com.weaver.di", category: "Dependency")
  #endif

  public init() {}

  public func log(_ message: String, level: OSLogType) async {
    #if canImport(os)
      logger.log(level: level, "\(message, privacy: .public)")
    #else
      _ = (message, level)
    #endif
  }

  public func recordResolutionFailure(for key: String, error: Error) async {
    #if canImport(os)
      logger.error(
        "Resolution failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    #else
      _ = (key, error)
    #endif
  }
}

public struct AnyDependencyKey: Hashable, Sendable, CustomStringConvertible {
  private let identifier: String
  private let objectID: ObjectIdentifier

  public init<Key: DependencyKey>(_ key: Key.Type) {
    identifier = String(describing: key)
    objectID = ObjectIdentifier(key)
  }

  public var description: String { identifier }

  public func hash(into hasher: inout Hasher) { hasher.combine(objectID) }

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.objectID == rhs.objectID }
}

public enum DependencyConfigurationError: Error, Sendable, CustomStringConvertible {
  case duplicateRegistrations([String])
  case missingDependencies([String])
  case circularDependency([String])

  public var description: String {
    switch self {
    case .duplicateRegistrations(let keys):
      "Duplicate dependency registrations: \(keys.joined(separator: ", "))"
    case .missingDependencies(let missing):
      "Missing dependencies: \(missing.joined(separator: ", "))"
    case .circularDependency(let cycle):
      "Circular dependency: \(cycle.joined(separator: " -> "))"
    }
  }
}

private struct DependencyRegistrationIdentity: Hashable, Sendable {
  let key: AnyDependencyKey
  let context: DependencyContext

  var description: String { "\(key.description)@\(context.description)" }
}

private enum DependencyValidationResult {
  case valid
  case missing([String])
  case circular([String])
}

private struct DependencyGraph {
  let registrations: [AnyDependencyKey: DependencyRegistration]
  let availableExternalKeys: Set<AnyDependencyKey>

  func validate() -> DependencyValidationResult {
    if let cycle = detectCycle() { return .circular(cycle) }
    let missing = locateMissingDependencies()
    return missing.isEmpty ? .valid : .missing(missing)
  }

  private func detectCycle() -> [String]? {
    var visiting: Set<AnyDependencyKey> = []
    var visited: Set<AnyDependencyKey> = []
    var stack: [AnyDependencyKey] = []

    func dfs(_ key: AnyDependencyKey) -> [String]? {
      if visiting.contains(key), let start = stack.firstIndex(of: key) {
        return (Array(stack[start...]) + [key]).map(\.description)
      }
      if visited.contains(key) { return nil }

      visiting.insert(key)
      stack.append(key)
      let dependencies = (registrations[key]?.dependencies ?? [])
        .filter { registrations[$0] != nil }
        .sorted { $0.description < $1.description }
      for dependency in dependencies {
        if let cycle = dfs(dependency) { return cycle }
      }
      _ = stack.popLast()
      visiting.remove(key)
      visited.insert(key)
      return nil
    }

    for key in registrations.keys.sorted(by: { $0.description < $1.description }) {
      if let cycle = dfs(key) { return cycle }
    }
    return nil
  }

  private func locateMissingDependencies() -> [String] {
    registrations.flatMap { key, registration in
      registration.dependencies.compactMap { dependency in
        registrations[dependency] == nil && !availableExternalKeys.contains(dependency)
          ? "\(key.description) depends on unregistered \(dependency.description)"
          : nil
      }
    }.sorted()
  }
}

/// Mutable only while the composition root declares registrations.
/// `DependencyContainer.build` finalizes this registry into an immutable snapshot.
public actor DependencyRegistry {
  private var registrationsByContext:
    [DependencyContext: [AnyDependencyKey: DependencyRegistration]] = [:]
  private var duplicateRegistrations: Set<DependencyRegistrationIdentity> = []

  public init() {}

  public func register<Key: DependencyKey>(
    _ key: Key.Type,
    context: DependencyContext = .live,
    lifetime: DependencyLifetime = .singleton,
    dependsOn dependencies: [AnyDependencyKey] = [],
    replacingExisting: Bool = false,
    factory: @escaping @Sendable (DependencyResolver) async throws -> Key.Value
  ) {
    let identifier = AnyDependencyKey(key)
    let identity = DependencyRegistrationIdentity(key: identifier, context: context)
    var contextRegistrations = registrationsByContext[context, default: [:]]

    if contextRegistrations[identifier] != nil {
      guard replacingExisting else {
        duplicateRegistrations.insert(identity)
        return
      }
      duplicateRegistrations.remove(identity)
    }

    contextRegistrations[identifier] = DependencyRegistration(
      lifetime: lifetime,
      factory: { resolver in try await factory(resolver) },
      keyName: String(describing: key),
      dependencies: Set(dependencies)
    )
    registrationsByContext[context] = contextRegistrations
  }

  public func registerWeak<Key: DependencyKey>(
    _ key: Key.Type,
    context: DependencyContext = .live,
    dependsOn dependencies: [AnyDependencyKey] = [],
    replacingExisting: Bool = false,
    factory: @escaping @Sendable (DependencyResolver) async throws -> Key.Value
  ) where Key.Value: AnyObject {
    register(
      key,
      context: context,
      lifetime: .weakReference,
      dependsOn: dependencies,
      replacingExisting: replacingExisting,
      factory: factory
    )
  }

  func finalize(
    context: DependencyContext,
    availableExternalKeys: Set<AnyDependencyKey> = []
  ) throws -> DependencyRegistrationSnapshot {
    let relevantContexts: Set<DependencyContext> = context == .live ? [.live] : [.live, context]
    let duplicates =
      duplicateRegistrations
      .filter { relevantContexts.contains($0.context) }
      .map(\.description)
      .sorted()

    guard duplicates.isEmpty else {
      throw DependencyConfigurationError.duplicateRegistrations(duplicates)
    }

    var selected = registrationsByContext[.live] ?? [:]
    if context != .live {
      selected.merge(registrationsByContext[context] ?? [:]) { _, contextual in contextual }
    }

    switch DependencyGraph(
      registrations: selected,
      availableExternalKeys: availableExternalKeys
    ).validate() {
    case .valid:
      return DependencyRegistrationSnapshot(context: context, registrations: selected)
    case .missing(let missing):
      throw DependencyConfigurationError.missingDependencies(missing)
    case .circular(let cycle):
      throw DependencyConfigurationError.circularDependency(cycle)
    }
  }
}
