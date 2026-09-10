# Identity and Evolution

## 정체성

Weaver는 **서비스의 생성·선택·수명을 호출 코드에서 분리하고 typed async 해석으로 연결하는 작은 Swift DI 라이브러리**다.

사용자는 application composition root다. Weaver의 책임은 typed registration, context별 implementation selection, graph validation, async construction, lifetime 관리와 child composition이다.

Feature/business code는 container, resolver, global dependency registry를 사용하지 않는다. 완성된 dependency를 initializer/factory 인자로 받는다.

비목표는 전역 service locator, application state container, 자동 reflection 기반 injection, framework-specific view injection, persistence/network orchestration이다.

## 변하면 안 되는 것

- Container는 composition root 안에 머문다.
- Feature/business code에 Weaver runtime dependency를 요구하지 않는다.
- dependency identity와 resolution 결과는 typed `DependencyKey.Value` 계약을 따른다.
- async factory와 `.singleton/.weakReference/.transient`의 의미를 보존한다.
- configuration 오류는 container 생성 전에 명시적으로 실패한다.
- runtime cycle/cancellation/factory failure를 성공처럼 숨기지 않는다.
- context는 container creation configuration이며 생성 후 바뀌지 않는다.

## 변경 가능한 것

위 불변조건을 보존한다면 내부 cache representation, graph-validation algorithm, logger implementation, macro syntax, diagnostics, platform minimum version은 교체할 수 있다.

새 context나 lifetime은 실제 사용 사례와 명확한 ownership semantics가 있을 때만 추가한다.

## 발전 방향

우선순위는 정확한 object graph → 명시적 composition boundary → 최소 runtime state → 진단 품질 순이다.

Macros는 선택 기능이며 core runtime 계약을 생성하는 얇은 편의 계층이어야 한다. Compile-time code generation을 위해 runtime core를 복잡하게 만들지 않는다.

Feature/business 코드에서 container 접근을 다시 허용하는 편의 기능은 정체성보다 우선하지 않는다.
