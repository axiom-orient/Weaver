# Architecture

## Boundary

```text
Application Composition Root
        │
        ▼
DependencyModule
        │
        ▼
DependencyRegistry ── configuration owner
        │ finalize(context)
        ▼
Validated Snapshot
        │
        ▼
DependencyContainer ── runtime/lifetime owner
        │ root resolve
        ▼
Feature / Business Graph
```

Feature/business graph는 Weaver에 역의존하지 않는다.

## 의존 방향

```text
Feature/Business ← concrete implementations ← Composition Root → Weaver
```

Weaver는 application domain을 알지 못하고, application domain은 Weaver runtime을 알 필요가 없다.

## State model

### Registry

Build 동안만 mutable하다.

- registrations grouped by `DependencyContext`
- duplicate `(key, context)` identities

`finalize` 후 snapshot은 immutable하다.

### Container

- selected registrations
- visible keys
- optional parent
- singleton/weak cache
- shared pending construction
- active runtime wait graph

Global container, global current context, global bootstrap generation은 없다.

## Policy / Mechanism

| Policy | Owner | Mechanism |
|---|---|---|
| context selection | Registry finalization | live base + exact override |
| duplicate policy | Registry | reject unless explicit replacement |
| declared graph validity | Registry finalization | DFS + missing-key scan |
| lifetime | registration | Container cache/pending behavior |
| runtime cycle | Container | Task-local path + actor wait graph |
| hierarchy | Container | child-local first, parent delegation |

## Concurrency

Container는 actor다. Cache, pending construction, wait graph의 단일 owner다.

Singleton/weak construction은 container-owned unstructured task로 공유한다. 개별 waiter cancellation은 다른 waiter가 사용하는 construction을 취소하지 않는다. Resolve caller는 자신의 cancellation을 명시적으로 관찰한다.

Transient construction은 공유 pending state에 들어가지 않는다.

## Recovery

Configuration failure는 container를 만들지 않는다. Factory failure는 singleton cache를 만들지 않는다. Build cancellation에는 global commit이 없으므로 rollback할 global state가 없다.
