# Research

확인일: 2026-09-10

## 적용한 판단

- Martin Fowler, *Inversion of Control Containers and the Dependency Injection pattern*
  https://martinfowler.com/articles/injection.html
  Configuration과 service use의 분리를 유지하고, application object가 locator를 직접 호출하지 않는 방향의 근거로 사용했다.

- Martin Fowler, *Dependency Composition*
  https://martinfowler.com/articles/dependency-composition.html
  business logic과 composition/transport concern을 분리하고 dependency contract를 명시적으로 유지하는 방향을 참고했다.

- devxoul/Pure, *Pure DI in Swift*
  https://github.com/devxoul/Pure
  object graph를 composition root에서 완성한다는 경계 원칙을 참고했다. Weaver는 lifetime/context/async graph 기능을 위해 container 자체는 composition root 내부에 유지한다.

- uber/needle
  https://github.com/uber/needle
  hierarchical DI와 compile-time/code-generation 접근을 비교했다. Weaver는 더 작은 runtime typed container를 유지하며 macros를 optional로 둔다.

## 적용하지 않은 것

- 모든 container 제거: Weaver의 async lifetime/context/hierarchy 역할을 없애므로 정체성과 맞지 않는다.
- reflection 기반 자동 injection: dependency edge를 숨기고 runtime failure surface를 늘린다.
- global TaskLocal dependency store: feature/business code에서 ambient lookup을 다시 허용하므로 사용하지 않는다.
