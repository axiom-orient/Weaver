import DependencyDemoFeature
import Weaver

private struct LiveGreetingService: GreetingService {
  func greeting() -> String { "live" }
}

private struct PreviewGreetingService: GreetingService {
  func greeting() -> String { "preview" }
}

private struct TestGreetingService: GreetingService {
  func greeting() -> String { "test" }
}

private enum GreetingServiceKey: DependencyKey {
  typealias Value = any GreetingService
}

private enum GreetingFeatureKey: DependencyKey {
  typealias Value = GreetingFeature
}

private struct AppModule: DependencyModule {
  func register(in registry: DependencyRegistry) async {
    await registry.register(GreetingServiceKey.self) { _ in
      LiveGreetingService()
    }
    await registry.register(GreetingServiceKey.self, context: .preview) { _ in
      PreviewGreetingService()
    }
    await registry.register(GreetingServiceKey.self, context: .test) { _ in
      TestGreetingService()
    }
    await registry.register(
      GreetingFeatureKey.self,
      dependsOn: [AnyDependencyKey(GreetingServiceKey.self)]
    ) { resolver in
      GreetingFeature(service: try await resolver.resolve(GreetingServiceKey.self))
    }
  }
}

private func compose(_ context: DependencyContext) async throws -> GreetingFeature {
  let container = try await DependencyContainer.build(
    modules: [AppModule()],
    context: context
  )
  return try await container.resolve(GreetingFeatureKey.self)
}

@main
enum DependencyDemoApp {
  static func main() async throws {
    let live = try await compose(.live)
    let preview = try await compose(.preview)
    let test = try await compose(.test)

    print("live=\(live.message()) preview=\(preview.message()) test=\(test.message())")
  }
}
