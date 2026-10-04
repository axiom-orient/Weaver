# Specification

## 필수 기능

### Typed key

```swift
public protocol DependencyKey: Sendable {
    associatedtype Value: Sendable
}
```

Key는 composition layer가 소유한다.

### Registration

`DependencyRegistry.register`는 key, context, lifetime, declared dependency edges와 async factory를 받는다.

동일 `(key, context)`의 중복은 기본 오류다. 의도된 교체만 `replacingExisting: true`로 허용한다.

### Context

지원 context는 `.live`, `.preview`, `.test`다.

선택 규칙은 하나다.

1. `.live` registrations를 base로 선택한다.
2. 요청 context가 `.live`가 아니면 동일 key의 exact-context registration으로 덮는다.
3. unrelated context registration은 활성 graph에 포함하지 않는다.
4. 선택된 graph만 missing/cycle validation 대상이다.

### Build

```swift
DependencyContainer.build(modules:context:logger:)
```

은 module registration을 수행하고 cancellation을 검사한 뒤 configuration을 finalize한다. validation을 통과한 경우에만 container를 반환한다.

### Resolve

`resolve(Key.self)`는 `Key.Value`를 반환한다.

- singleton: container 안에서 성공한 첫 생성 결과를 재사용한다.
- weakReference: class instance만 weak cache하고 해제 후 재생성한다.
- transient: resolve마다 독립 생성한다.

동시 singleton/weak 생성은 같은 pending construction을 공유한다. transient는 공유하지 않는다.

### Child

Child는 parent와 같은 context를 사용한다. Child 등록이 같은 key의 parent 등록보다 우선한다. Parent registration/cache/pending state를 복사하지 않는다. Child graph는 parent-visible key를 external dependency로 검증한다.

## 오류

- `DependencyConfigurationError.duplicateRegistrations`
- `DependencyConfigurationError.missingDependencies`
- `DependencyConfigurationError.circularDependency`
- `DependencyError.unregisteredDependency`
- `DependencyError.typeMismatch`
- `DependencyError.weakNonObject`
- `DependencyError.circularResolution`
- `CancellationError`
- factory가 던진 원래 오류

## 수용 기준

- Feature/business target은 Weaver를 import하지 않고 동작할 수 있어야 한다.
- root composition만 container를 생성·resolve할 수 있는 사용 예제를 제공한다.
- context별 implementation 선택은 global state 변경 없이 서로 독립적이어야 한다.
- declared graph 오류는 factory 실행 전에 실패해야 한다.
- undeclared runtime cycle은 deadlock 대신 오류로 실패해야 한다.

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

## Context 사용 예제

Context는 global mutable state가 아니라 **container 생성 configuration**입니다.

```swift
let preview = try await DependencyContainer.build(
    modules: [AppModule()],
    context: .preview
)
```

동일 key의 `.preview` 등록이 있으면 그것을 선택하고, 없으면 `.live` 등록을 사용합니다. 각 container의 context는 생성 후 변경되지 않습니다.
