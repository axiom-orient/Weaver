# Weaver 분석

## Verdict

- **Identity**: 서비스의 생성·선택·수명을 호출 코드에서 분리하고 typed async 해석으로 연결하는 작은 Swift DI 라이브러리.
- **Caller**: application composition root와 composition factory.
- **Value**: async object graph 조립, context 선택, lifetime ownership, validation을 feature/business code 밖으로 이동한다.
- **Current**: global locator/state 없이 container-local composition으로 수렴했다.
- **Direction**: **MAINTAIN**. 새 correctness gap이 확인되기 전까지 runtime 구조를 더 늘리지 않는다.
- **Confidence**: HIGH for Swift 6.2.1 Linux execution; Apple SDK paths are NOT_RUN.

## 책임 경계

| Surface·활성 조건 | Caller→Handler | Input·검증 | State/Effect owner | Output·Failure | 근거 |
|---|---|---|---|---|---|
| Root composition | composition root → `DependencyContainer.build` | modules/context, cancellation, registry finalization | Registry(configuration), Container(runtime) | validated container / configuration or cancellation error | `DependencyContainer.swift` |
| Registration | Module → `DependencyRegistry.register` | typed Key, context, lifetime, declared edges | Registry | pending configuration | `DependencyInterfaces.swift` |
| Resolution | composition root/factory → `resolve` | typed Key, runtime cycle, cancellation | Container | `Key.Value` / `DependencyError` | `DependencyContainer.swift` |
| Lifetime | `resolve` → cache/pending | selected registration lifetime | Container | reused/new/released value | `DependencyContainer.swift` |
| Context selection | `finalize(context:)` | exact context then live fallback | Registry | immutable selected snapshot | `DependencyInterfaces.swift` |
| Child scope | composition root → `makeChildContainer` | same context, parent-visible keys | child Container; parent remains separate | validated child / configuration error | `DependencyContainer.swift` |

## 실제 경로

```text
Input: modules + context
→ Registry registration
→ select context registrations (live base + exact override)
→ duplicate/missing/declared-cycle validation
→ immutable snapshot
→ Container
→ root resolve
→ factory(resolver)
→ nested typed resolves
→ lifetime effect/cache
→ constructed root
→ feature/business code
```

Feature/business code는 위 마지막 결과만 받으며 Weaver runtime을 호출하지 않는다.

## State / Contract / Effect owner

| Concern | Authoritative owner |
|---|---|
| mutable registration configuration | `DependencyRegistry` |
| context selection policy | `DependencyRegistry.finalize` |
| selected immutable graph | `DependencyRegistrationSnapshot` |
| cache / pending construction / runtime wait graph | `DependencyContainer` |
| parent fallback | child `DependencyContainer` |
| application dependency ownership | application object graph |

Global manager, global context, mutable bootstrap state는 존재하지 않는다.

## 기능 현황

| 기능 | 연결 상태 | 계약 충족 상태 | 검증·적용 범위 | 근거 |
|---|---|---|---|---|
| typed async registration/resolution | PUBLIC_LIBRARY | SATISFIED | Swift test/runtime | Registry/Container |
| singleton | PUBLIC_LIBRARY | SATISFIED | protocol existential + concurrency | tests |
| weakReference | PUBLIC_LIBRARY | SATISFIED | concrete class + protocol existential + value rejection | tests |
| transient | PUBLIC_LIBRARY | SATISFIED | concurrent non-coalescing | tests |
| live/preview/test selection | PUBLIC_LIBRARY | SATISFIED | exact override + live fallback | tests |
| duplicate/missing/cycle validation | PUBLIC_LIBRARY | SATISFIED | root/context/child | tests |
| runtime/cross-task cycle | PUBLIC_LIBRARY | SATISFIED | undeclared and concurrent cycle | tests |
| child scope | PUBLIC_LIBRARY | SATISFIED | override + parent-visible dependency | tests |
| feature/business isolation | REACHABLE | SATISFIED | package target graph + demo runtime | `Package.swift`, demo |
| Apple SDK execution | UNKNOWN | UNKNOWN | NOT_RUN | environment |

## 실패·취소·복구

- 잘못된 configuration은 container 생성 전에 `DependencyConfigurationError`로 실패한다.
- 미선언 runtime cycle도 `DependencyError.circularResolution`으로 종료된다.
- 한 singleton waiter의 cancellation은 container-owned shared construction을 취소하지 않는다.
- 실패한 singleton 결과는 cache되지 않아 다음 resolve가 재시도한다.
- container build cancellation은 global commit 대상이 없으므로 stale-bootstrap recovery state 자체가 존재하지 않는다.

## 정리 판단

- **KEEP**: typed keys/modules/registry/container/resolver, 세 lifetime, context, validation, child scope, logger, optional macros.
- **INTEGRATE**: context selection과 graph validation은 `DependencyRegistry.finalize(context:)`가 단독 소유한다.
- **REMOVE**: composition root 밖에서 dependency runtime을 조회하게 만드는 global/ambient access structure는 없다.

## Findings

현재 실행 환경에서 새 material correctness defect는 재현되지 않았다. 남은 UNKNOWN은 Apple SDK 및 WeaverMacros 원격 `swift-syntax` package 실행 검증이다.
