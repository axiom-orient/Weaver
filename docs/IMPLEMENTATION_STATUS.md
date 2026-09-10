# Implementation Status

## 제품

Weaver는 composition-root 전용 container를 사용하는 typed async DI library다.

## 실제 구조

| Unit | 역할 | 상태 |
|---|---|---|
| `DependencyInterfaces.swift` | key/context/lifetime/registry/validation contract | REACHABLE |
| `DependencyContainer.swift` | build, resolve, cache, pending, cycle, child scope | REACHABLE |
| `DependencyDemoFeature` | Weaver 비의존 feature 경계 | REACHABLE |
| `DependencyDemoApp` | composition root와 E2E 실행 | REACHABLE |
| `WeaverMacros` | optional registration code generation | EXTERNAL SIBLING |

## Capability

| 기능 | 연결 | 계약 | 검사 |
|---|---|---|---|
| typed async DI | PUBLIC_LIBRARY | SATISFIED | PASS |
| context selection | PUBLIC_LIBRARY | SATISFIED | PASS |
| lifetime 3종 | PUBLIC_LIBRARY | SATISFIED | PASS |
| configuration finalization | PUBLIC_LIBRARY | SATISFIED | PASS |
| runtime cycle/cancellation/retry | PUBLIC_LIBRARY | SATISFIED | PASS |
| child composition | PUBLIC_LIBRARY | SATISFIED | PASS |
| feature/business Weaver isolation | REACHABLE | SATISFIED | PASS |
| Apple SDK runtime | UNKNOWN | UNKNOWN | NOT_RUN |
| WeaverMacros full SwiftPM tests | UNKNOWN | UNKNOWN | NOT_RUN |

## Global state

Global locator, mutable current-context store, bootstrap manager/state는 존재하지 않는다.
