private enum ResolutionPath {
  @TaskLocal static var keys: [AnyDependencyKey] = []
}

/// Runtime owner for one validated dependency graph.
/// Keep the container in the composition root; inject constructed values into application code.
public actor DependencyContainer: DependencyResolver {
  private final class WeakReference: @unchecked Sendable {
    weak var object: AnyObject?

    init(_ object: AnyObject) { self.object = object }
  }

  private struct CachedSingleton: Sendable {
    let storage: any Sendable

    func value<Value: Sendable>(as _: Value.Type) -> Value? {
      storage as? Value
    }
  }

  private enum CacheEntry {
    case singleton(CachedSingleton)
    case weak(WeakReference)
  }

  private let context: DependencyContext
  private let registrations: [AnyDependencyKey: DependencyRegistration]
  private let visibleKeys: Set<AnyDependencyKey>
  private let parent: DependencyContainer?
  private let logger: DependencyLogger

  private var cache: [AnyDependencyKey: CacheEntry] = [:]
  private var pending: [AnyDependencyKey: Task<any Sendable, Error>] = [:]
  private var activeWaits: [AnyDependencyKey: [AnyDependencyKey: Int]] = [:]

  private init(
    snapshot: DependencyRegistrationSnapshot,
    parent: DependencyContainer? = nil,
    inheritedKeys: Set<AnyDependencyKey> = [],
    logger: DependencyLogger
  ) {
    context = snapshot.context
    registrations = snapshot.registrations
    visibleKeys = inheritedKeys.union(snapshot.keys)
    self.parent = parent
    self.logger = logger
  }

  /// Creates one immutable, validated container for a composition root.
  public static func build(
    modules: [DependencyModule],
    context: DependencyContext = .live,
    logger: DependencyLogger = DefaultDependencyLogger.shared
  ) async throws -> DependencyContainer {
    let registry = DependencyRegistry()
    for module in modules {
      try Task.checkCancellation()
      await module.register(in: registry)
      try Task.checkCancellation()
    }
    let snapshot = try await registry.finalize(context: context)
    return DependencyContainer(snapshot: snapshot, logger: logger)
  }

  /// Resolves composition values. Factories may use the resolver recursively.
  /// The resulting service/feature should receive ordinary constructor arguments, not this container.
  public func resolve<Key: DependencyKey>(_ key: Key.Type) async throws -> Key.Value {
    try Task.checkCancellation()
    let identifier = AnyDependencyKey(key)

    guard let registration = registrations[identifier] else {
      if let parent { return try await parent.resolve(key) }
      throw DependencyError.unregisteredDependency(key: identifier.description)
    }

    if ResolutionPath.keys.contains(identifier) {
      throw DependencyError.circularResolution(
        path: (ResolutionPath.keys + [identifier]).map(\.description)
      )
    }

    let waitSource = try beginWait(to: identifier)
    defer { endWait(from: waitSource, to: identifier) }

    do {
      if let cached = cachedValue(for: identifier, as: Key.Value.self) {
        return cached
      }

      let produced: any Sendable
      switch registration.lifetime {
      case .transient:
        produced = try await createValue(for: identifier, registration: registration)
      case .singleton, .weakReference:
        produced = try await sharedValue(for: identifier, registration: registration)
      }

      try Task.checkCancellation()
      guard let typed = produced as? Key.Value else {
        throw DependencyError.typeMismatch(
          expected: Key.Value.self,
          actual: type(of: produced),
          key: identifier.description
        )
      }
      return typed
    } catch {
      await logger.recordResolutionFailure(for: registration.keyName, error: error)
      throw error
    }
  }

  /// Creates a validated child scope with the same immutable context.
  /// Parent runtime state is not copied; unresolved keys delegate to the parent container.
  public func makeChildContainer(
    _ modules: [DependencyModule]
  ) async throws -> DependencyContainer {
    let registry = DependencyRegistry()
    for module in modules {
      try Task.checkCancellation()
      await module.register(in: registry)
      try Task.checkCancellation()
    }

    let inheritedKeys = visibleKeys
    let snapshot = try await registry.finalize(
      context: context,
      availableExternalKeys: inheritedKeys
    )
    return DependencyContainer(
      snapshot: snapshot,
      parent: self,
      inheritedKeys: inheritedKeys,
      logger: logger
    )
  }

  private func beginWait(to target: AnyDependencyKey) throws -> AnyDependencyKey? {
    guard let source = ResolutionPath.keys.last else { return nil }

    var targets = activeWaits[source, default: [:]]
    targets[target, default: 0] += 1
    activeWaits[source] = targets

    if let path = pathInActiveWaits(from: target, to: source) {
      endWait(from: source, to: target)
      throw DependencyError.circularResolution(
        path: ([source] + path).map(\.description)
      )
    }
    return source
  }

  private func endWait(from source: AnyDependencyKey?, to target: AnyDependencyKey) {
    guard let source, var targets = activeWaits[source], let count = targets[target] else {
      return
    }

    if count == 1 {
      targets.removeValue(forKey: target)
    } else {
      targets[target] = count - 1
    }

    if targets.isEmpty {
      activeWaits.removeValue(forKey: source)
    } else {
      activeWaits[source] = targets
    }
  }

  private func pathInActiveWaits(
    from start: AnyDependencyKey,
    to goal: AnyDependencyKey
  ) -> [AnyDependencyKey]? {
    var visited: Set<AnyDependencyKey> = []

    func dfs(_ current: AnyDependencyKey) -> [AnyDependencyKey]? {
      if current == goal { return [current] }
      guard visited.insert(current).inserted else { return nil }

      let nextKeys = (activeWaits[current] ?? [:])
        .filter { $0.value > 0 }
        .map(\.key)
        .sorted { $0.description < $1.description }
      for next in nextKeys {
        if let suffix = dfs(next) { return [current] + suffix }
      }
      return nil
    }

    return dfs(start)
  }

  private func sharedValue(
    for key: AnyDependencyKey,
    registration: DependencyRegistration
  ) async throws -> any Sendable {
    if let existing = pending[key] {
      let value = try await existing.value
      try Task.checkCancellation()
      return value
    }

    let task = Task<any Sendable, Error> {
      try await self.createValue(for: key, registration: registration)
    }
    pending[key] = task
    defer { pending.removeValue(forKey: key) }

    let value = try await task.value
    try cache(value, for: key, lifetime: registration.lifetime)
    try Task.checkCancellation()
    return value
  }

  private func createValue(
    for key: AnyDependencyKey,
    registration: DependencyRegistration
  ) async throws -> any Sendable {
    try Task.checkCancellation()
    return try await ResolutionPath.$keys.withValue(ResolutionPath.keys + [key]) {
      let value = try await registration.factory(self)
      try Task.checkCancellation()
      return value
    }
  }

  private func cachedValue<Value: Sendable>(
    for key: AnyDependencyKey,
    as _: Value.Type
  ) -> Value? {
    switch cache[key] {
    case .singleton(let cached):
      return cached.value(as: Value.self)
    case .weak(let entry):
      guard let object = entry.object else {
        cache.removeValue(forKey: key)
        return nil
      }
      return object as? Value
    case nil:
      return nil
    }
  }

  private func cache(
    _ value: any Sendable,
    for key: AnyDependencyKey,
    lifetime: DependencyLifetime
  ) throws {
    switch lifetime {
    case .singleton:
      cache[key] = .singleton(CachedSingleton(storage: value))
    case .weakReference:
      guard Mirror(reflecting: value).displayStyle == .class else {
        throw DependencyError.weakNonObject(key: key.description)
      }
      cache[key] = .weak(WeakReference(value as AnyObject))
    case .transient:
      break
    }
  }
}

public enum DependencyError: Error, CustomStringConvertible {
  case unregisteredDependency(key: String)
  case typeMismatch(expected: Any.Type, actual: Any.Type, key: String)
  case weakNonObject(key: String)
  case circularResolution(path: [String])

  public var description: String {
    switch self {
    case .unregisteredDependency(let key):
      "Dependency for \(key) is not registered"
    case .typeMismatch(let expected, let actual, let key):
      "Expected \(expected) but resolved \(actual) for \(key)"
    case .weakNonObject(let key):
      "Weak lifetime requires a class instance for \(key)"
    case .circularResolution(let path):
      "Circular dependency resolution: \(path.joined(separator: " -> "))"
    }
  }
}
