import Foundation
import Testing

@testable import Weaver

actor Counter {
  private var value = 0

  func increment() { value += 1 }

  func incrementAndGet() -> Int {
    value += 1
    return value
  }

  func count() -> Int { value }
}

actor TwoPartyGate {
  private var arrivals = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func arrive() async {
    arrivals += 1
    if arrivals == 2 {
      let pending = waiters
      waiters.removeAll()
      for waiter in pending { waiter.resume() }
      return
    }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

protocol Service: Sendable { var id: UUID { get } }
final class ServiceImpl: Service, @unchecked Sendable { let id = UUID() }

enum ProtocolServiceKey: DependencyKey { typealias Value = any Service }
enum ValueKey: DependencyKey { typealias Value = UUID }

final class WeakService: @unchecked Sendable { let id = UUID() }
protocol WeakProtocol: AnyObject, Sendable { var id: UUID { get } }
final class WeakProtocolService: WeakProtocol, @unchecked Sendable { let id = UUID() }

enum WeakProtocolKey: DependencyKey { typealias Value = any WeakProtocol }
enum WeakKey: DependencyKey { typealias Value = WeakService }
enum AKey: DependencyKey { typealias Value = String }
enum BKey: DependencyKey { typealias Value = String }
enum CKey: DependencyKey { typealias Value = String }
enum OverrideKey: DependencyKey { typealias Value = String }
enum ContextKey: DependencyKey { typealias Value = String }

struct ProtocolModule: DependencyModule {
  let counter: Counter

  func register(in registry: DependencyRegistry) async {
    await registry.register(ProtocolServiceKey.self, lifetime: .singleton) { _ in
      await counter.increment()
      return ServiceImpl()
    }
  }
}

@Suite("DependencySystemTests", .serialized)
struct DependencySystemTests {
  @Test("protocol-typed singleton is cached exactly once")
  func protocolSingleton() async throws {
    let counter = Counter()
    let container = try await DependencyContainer.build(
      modules: [ProtocolModule(counter: counter)]
    )

    let first = try await container.resolve(ProtocolServiceKey.self)
    let second = try await container.resolve(ProtocolServiceKey.self)

    #expect(first.id == second.id)
    #expect(await counter.count() == 1)
  }

  @Test("concurrent singleton requests share one factory")
  func concurrentSingleton() async throws {
    let counter = Counter()
    let container = try await DependencyContainer.build(
      modules: [ProtocolModule(counter: counter)]
    )

    async let a = container.resolve(ProtocolServiceKey.self)
    async let b = container.resolve(ProtocolServiceKey.self)
    async let c = container.resolve(ProtocolServiceKey.self)

    let ids = try await Set([a.id, b.id, c.id])
    #expect(ids.count == 1)
    #expect(await counter.count() == 1)
  }

  @Test("concurrent transient requests never coalesce")
  func concurrentTransient() async throws {
    let counter = Counter()
    struct Module: DependencyModule {
      let counter: Counter

      func register(in registry: DependencyRegistry) async {
        await registry.register(ProtocolServiceKey.self, lifetime: .transient) { _ in
          await counter.increment()
          try await Task.sleep(for: .milliseconds(10))
          return ServiceImpl()
        }
      }
    }

    let container = try await DependencyContainer.build(modules: [Module(counter: counter)])
    async let a = container.resolve(ProtocolServiceKey.self)
    async let b = container.resolve(ProtocolServiceKey.self)
    async let c = container.resolve(ProtocolServiceKey.self)

    let ids = try await Set([a.id, b.id, c.id])
    #expect(ids.count == 3)
    #expect(await counter.count() == 3)
  }

  @Test("weak lifetime recreates a released class instance")
  func weakLifetime() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.registerWeak(WeakKey.self) { _ in WeakService() }
      }
    }

    let container = try await DependencyContainer.build(modules: [Module()])
    var first: WeakService? = try await container.resolve(WeakKey.self)
    weak var weakFirst = first
    let firstID = first?.id
    first = nil

    for _ in 0..<100 where weakFirst != nil { await Task.yield() }
    #expect(weakFirst == nil)

    let second = try await container.resolve(WeakKey.self)
    #expect(second.id != firstID)
  }

  @Test("weak lifetime supports a class instance behind a protocol existential")
  func weakProtocolExistential() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(WeakProtocolKey.self, lifetime: .weakReference) { _ in
          WeakProtocolService()
        }
      }
    }

    let container = try await DependencyContainer.build(modules: [Module()])
    var first: (any WeakProtocol)? = try await container.resolve(WeakProtocolKey.self)
    weak var weakFirst = first as AnyObject
    let firstID = first?.id
    first = nil

    for _ in 0..<100 where weakFirst != nil { await Task.yield() }
    #expect(weakFirst == nil)

    let second = try await container.resolve(WeakProtocolKey.self)
    #expect(second.id != firstID)
  }

  @Test("weak lifetime rejects value instances")
  func weakRejectsValue() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(ValueKey.self, lifetime: .weakReference) { _ in UUID() }
      }
    }

    let container = try await DependencyContainer.build(modules: [Module()])
    do {
      _ = try await container.resolve(ValueKey.self)
      Issue.record("Expected weakNonObject")
    } catch let error as DependencyError {
      guard case .weakNonObject = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  @Test("runtime cycle is rejected even when graph metadata omits it")
  func runtimeCycle() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(AKey.self) { resolver in
          _ = try await resolver.resolve(BKey.self)
          return "A"
        }
        await registry.register(BKey.self) { resolver in
          _ = try await resolver.resolve(AKey.self)
          return "B"
        }
      }
    }

    let container = try await DependencyContainer.build(modules: [Module()])
    do {
      _ = try await container.resolve(AKey.self)
      Issue.record("Expected circularResolution")
    } catch let error as DependencyError {
      guard case .circularResolution(let path) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(path.first?.contains("AKey") == true)
      #expect(path.last?.contains("AKey") == true)
    }
  }

  @Test("concurrent root resolutions reject a cross-task cycle instead of deadlocking")
  func concurrentRuntimeCycle() async throws {
    let gate = TwoPartyGate()
    struct Module: DependencyModule {
      let gate: TwoPartyGate

      func register(in registry: DependencyRegistry) async {
        await registry.register(AKey.self) { resolver in
          await gate.arrive()
          _ = try await resolver.resolve(BKey.self)
          return "A"
        }
        await registry.register(BKey.self) { resolver in
          await gate.arrive()
          _ = try await resolver.resolve(AKey.self)
          return "B"
        }
      }
    }

    let container = try await DependencyContainer.build(modules: [Module(gate: gate)])
    async let a = container.resolve(AKey.self)
    async let b = container.resolve(BKey.self)

    do {
      _ = try await (a, b)
      Issue.record("Expected cross-task circularResolution")
    } catch let error as DependencyError {
      guard case .circularResolution = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  @Test("child registration overrides parent without copying parent state")
  func childOverride() async throws {
    struct ParentModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(OverrideKey.self) { _ in "parent" }
      }
    }
    struct ChildModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(OverrideKey.self) { _ in "child" }
      }
    }

    let parent = try await DependencyContainer.build(modules: [ParentModule()])
    let child = try await parent.makeChildContainer([ChildModule()])

    #expect(try await parent.resolve(OverrideKey.self) == "parent")
    #expect(try await child.resolve(OverrideKey.self) == "child")
  }

  @Test("duplicate registration in the active context fails finalization")
  func duplicateRegistrationFails() async throws {
    struct FirstModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(OverrideKey.self) { _ in "first" }
      }
    }
    struct SecondModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(OverrideKey.self) { _ in "second" }
      }
    }

    do {
      _ = try await DependencyContainer.build(modules: [FirstModule(), SecondModule()])
      Issue.record("Expected duplicateRegistrations")
    } catch let error as DependencyConfigurationError {
      guard case .duplicateRegistrations(let keys) = error else {
        Issue.record("Unexpected configuration error: \(error)")
        return
      }
      #expect(keys == ["OverrideKey@live"])
    }
  }

  @Test("explicit replacement intentionally resolves a duplicate registration")
  func explicitReplacement() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(OverrideKey.self) { _ in "first" }
        await registry.register(OverrideKey.self, replacingExisting: true) { _ in "replacement" }
      }
    }

    let container = try await DependencyContainer.build(modules: [Module()])
    #expect(try await container.resolve(OverrideKey.self) == "replacement")
  }

  @Test("root finalization rejects a declared missing dependency")
  func rootMissingDependencyFails() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(
          AKey.self,
          dependsOn: [AnyDependencyKey(BKey.self)]
        ) { _ in "A" }
      }
    }

    do {
      _ = try await DependencyContainer.build(modules: [Module()])
      Issue.record("Expected missingDependencies")
    } catch let error as DependencyConfigurationError {
      guard case .missingDependencies(let missing) = error else {
        Issue.record("Unexpected configuration error: \(error)")
        return
      }
      #expect(missing.contains { $0.contains("BKey") })
    }
  }

  @Test("root finalization rejects a declared circular dependency")
  func rootDeclaredCycleFails() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(AKey.self, dependsOn: [AnyDependencyKey(BKey.self)]) { _ in "A" }
        await registry.register(BKey.self, dependsOn: [AnyDependencyKey(AKey.self)]) { _ in "B" }
      }
    }

    do {
      _ = try await DependencyContainer.build(modules: [Module()])
      Issue.record("Expected circularDependency")
    } catch let error as DependencyConfigurationError {
      guard case .circularDependency(let cycle) = error else {
        Issue.record("Unexpected configuration error: \(error)")
        return
      }
      #expect(cycle.count >= 3)
    }
  }

  @Test("context-specific registration overrides live while live remains the fallback")
  func contextSelection() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(ContextKey.self) { _ in "live" }
        await registry.register(ContextKey.self, context: .preview) { _ in "preview" }
      }
    }

    let live = try await DependencyContainer.build(modules: [Module()], context: .live)
    let preview = try await DependencyContainer.build(modules: [Module()], context: .preview)
    let test = try await DependencyContainer.build(modules: [Module()], context: .test)

    #expect(try await live.resolve(ContextKey.self) == "live")
    #expect(try await preview.resolve(ContextKey.self) == "preview")
    #expect(try await test.resolve(ContextKey.self) == "live")
  }

  @Test("context-specific graph validation uses the selected implementation")
  func contextualGraphValidation() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(AKey.self) { _ in "live-A" }
        await registry.register(
          AKey.self,
          context: .preview,
          dependsOn: [AnyDependencyKey(CKey.self)]
        ) { _ in "preview-A" }
      }
    }

    _ = try await DependencyContainer.build(modules: [Module()], context: .live)

    do {
      _ = try await DependencyContainer.build(modules: [Module()], context: .preview)
      Issue.record("Expected preview missingDependencies")
    } catch let error as DependencyConfigurationError {
      guard case .missingDependencies(let missing) = error else {
        Issue.record("Unexpected configuration error: \(error)")
        return
      }
      #expect(missing.contains { $0.contains("CKey") })
    }
  }

  @Test("duplicate registration in an unrelated context does not invalidate another context")
  func unrelatedContextDuplicateIsInactive() async throws {
    struct Module: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(ContextKey.self) { _ in "live" }
        await registry.register(ContextKey.self, context: .preview) { _ in "preview-1" }
        await registry.register(ContextKey.self, context: .preview) { _ in "preview-2" }
      }
    }

    let live = try await DependencyContainer.build(modules: [Module()], context: .live)
    #expect(try await live.resolve(ContextKey.self) == "live")

    do {
      _ = try await DependencyContainer.build(modules: [Module()], context: .preview)
      Issue.record("Expected preview duplicateRegistrations")
    } catch let error as DependencyConfigurationError {
      guard case .duplicateRegistrations(let keys) = error else {
        Issue.record("Unexpected configuration error: \(error)")
        return
      }
      #expect(keys == ["ContextKey@preview"])
    }
  }

  @Test("child finalization validates dependencies visible from its parent in the same context")
  func childCanDependOnParent() async throws {
    struct ParentModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(BKey.self) { _ in "live-B" }
        await registry.register(BKey.self, context: .preview) { _ in "preview-B" }
      }
    }
    struct ChildModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(
          AKey.self,
          dependsOn: [AnyDependencyKey(BKey.self)]
        ) { resolver in
          "A->\(try await resolver.resolve(BKey.self))"
        }
      }
    }

    let parent = try await DependencyContainer.build(
      modules: [ParentModule()],
      context: .preview
    )
    let child = try await parent.makeChildContainer([ChildModule()])

    #expect(try await child.resolve(AKey.self) == "A->preview-B")
  }

  @Test("child finalization rejects dependencies absent from child and parent")
  func childMissingDependencyFails() async throws {
    struct ParentModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(OverrideKey.self) { _ in "parent" }
      }
    }
    struct InvalidChildModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(AKey.self, dependsOn: [AnyDependencyKey(BKey.self)]) { _ in "A" }
      }
    }

    let parent = try await DependencyContainer.build(modules: [ParentModule()])
    do {
      _ = try await parent.makeChildContainer([InvalidChildModule()])
      Issue.record("Expected missingDependencies")
    } catch let error as DependencyConfigurationError {
      guard case .missingDependencies(let missing) = error else {
        Issue.record("Unexpected configuration error: \(error)")
        return
      }
      #expect(missing.contains { $0.contains("BKey") })
    }
  }

  @Test("cancelling one singleton waiter does not cancel shared construction")
  func singletonWaiterCancellation() async throws {
    let counter = Counter()
    struct Module: DependencyModule {
      let counter: Counter

      func register(in registry: DependencyRegistry) async {
        await registry.register(ProtocolServiceKey.self) { _ in
          await counter.increment()
          try await Task.sleep(for: .milliseconds(30))
          return ServiceImpl()
        }
      }
    }

    let container = try await DependencyContainer.build(modules: [Module(counter: counter)])
    let cancelledWaiter = Task { try await container.resolve(ProtocolServiceKey.self) }
    await Task.yield()
    cancelledWaiter.cancel()
    let surviving = try await container.resolve(ProtocolServiceKey.self)

    do {
      _ = try await cancelledWaiter.value
      Issue.record("Expected cancelled waiter to throw")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected cancellation error: \(error)")
    }

    let cached = try await container.resolve(ProtocolServiceKey.self)
    #expect(cached.id == surviving.id)
    #expect(await counter.count() == 1)
  }

  @Test("failed singleton construction is not cached and can retry")
  func failedSingletonRetries() async throws {
    let counter = Counter()
    enum ProbeError: Error { case firstAttempt }
    struct Module: DependencyModule {
      let counter: Counter

      func register(in registry: DependencyRegistry) async {
        await registry.register(ProtocolServiceKey.self) { _ in
          if await counter.incrementAndGet() == 1 { throw ProbeError.firstAttempt }
          return ServiceImpl()
        }
      }
    }

    let container = try await DependencyContainer.build(modules: [Module(counter: counter)])
    do {
      _ = try await container.resolve(ProtocolServiceKey.self)
      Issue.record("Expected first construction to fail")
    } catch ProbeError.firstAttempt {
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    _ = try await container.resolve(ProtocolServiceKey.self)
    #expect(await counter.count() == 2)
  }

  @Test("cancelled container construction produces no global state to recover")
  func cancelledBuild() async {
    struct SlowModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        try? await Task.sleep(for: .milliseconds(100))
        await registry.register(OverrideKey.self) { _ in "never-current" }
      }
    }

    let build = Task {
      try await DependencyContainer.build(modules: [SlowModule()])
    }
    await Task.yield()
    build.cancel()

    do {
      _ = try await build.value
      Issue.record("Expected CancellationError")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected cancellation error: \(error)")
    }

    struct FreshModule: DependencyModule {
      func register(in registry: DependencyRegistry) async {
        await registry.register(OverrideKey.self) { _ in "fresh" }
      }
    }

    do {
      let fresh = try await DependencyContainer.build(modules: [FreshModule()])
      #expect(try await fresh.resolve(OverrideKey.self) == "fresh")
    } catch {
      Issue.record("Fresh composition should not depend on a cancelled build: \(error)")
    }
  }
}
