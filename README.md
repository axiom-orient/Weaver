# Weaver

Weaver는 **서비스의 생성·선택·수명을 호출 코드에서 분리하고 typed async 해석으로 연결하는 작은 Swift DI 라이브러리**입니다.

`DependencyContainer`는 composition root 안에서만 사용합니다. Feature/business 타입은 Weaver, container, resolver를 알 필요가 없으며 일반 생성자나 factory 인자로 완성된 의존성을 받습니다.

## 핵심 흐름

```text
DependencyModule
→ DependencyRegistry
→ context 선택 + graph finalization
→ DependencyContainer
→ root resolve
→ 완성된 feature/business graph
```

Container 내부 factory만 `DependencyResolver`를 사용합니다.

## 기능

- Swift 6 typed async registration / resolution
- `.singleton`, `.weakReference`, `.transient`
- `.live`, `.preview`, `.test` context별 구현 선택
- non-live context에 등록이 없으면 `.live` 등록으로 명시적 fallback
- duplicate/missing/declared-cycle fail-fast validation
- runtime cycle detection과 concurrent singleton construction coalescing
- child scope와 parent resolution
- optional `WeaverMacros`

## 사용

```swift
import Weaver

protocol APIClient: Sendable {}
struct LiveAPIClient: APIClient {}
struct PreviewAPIClient: APIClient {}

struct Feature: Sendable {
    let api: any APIClient
}

enum APIClientKey: DependencyKey {
    typealias Value = any APIClient
}

enum FeatureKey: DependencyKey {
    typealias Value = Feature
}

struct AppModule: DependencyModule {
    func register(in registry: DependencyRegistry) async {
        await registry.register(APIClientKey.self) { _ in
            LiveAPIClient()
        }
        await registry.register(APIClientKey.self, context: .preview) { _ in
            PreviewAPIClient()
        }
        await registry.register(
            FeatureKey.self,
            dependsOn: [AnyDependencyKey(APIClientKey.self)]
        ) { resolver in
            Feature(api: try await resolver.resolve(APIClientKey.self))
        }
    }
}

let container = try await DependencyContainer.build(
    modules: [AppModule()],
    context: .live
)
let feature = try await container.resolve(FeatureKey.self)
```

`feature`에는 container나 resolver를 전달하지 않습니다.

## Context

Context는 global mutable state가 아니라 **container 생성 configuration**입니다.

```swift
let preview = try await DependencyContainer.build(
    modules: [AppModule()],
    context: .preview
)
```

동일 key의 `.preview` 등록이 있으면 그것을 선택하고, 없으면 `.live` 등록을 사용합니다. 각 container의 context는 생성 후 변경되지 않습니다.

## 검증

```bash
swift test
swift build -c release -Xswiftc -warnings-as-errors
swift run DependencyDemoApp
```

`DependencyDemoFeature` target은 Weaver에 의존하지 않습니다. Demo app의 composition root만 Weaver를 import합니다.

## 정본

- [IDENTITY_AND_EVOLUTION](docs/IDENTITY_AND_EVOLUTION.md)
- [SPEC](docs/SPEC.md)
- [ARCHITECTURE](docs/ARCHITECTURE.md)
- [IMPLEMENTATION_STATUS](docs/IMPLEMENTATION_STATUS.md)
- [PLAN](docs/PLAN.md)
- [VALIDATION](docs/VALIDATION.md)
- [RESEARCH](docs/RESEARCH.md)
- [ANALYSIS](ANALYSIS.md)

## License

MIT
