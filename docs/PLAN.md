# Plan

현재 Swift 6.2.1 Linux에서 재현 가능한 core correctness gap은 없다.

## 남은 검증

### Apple SDK validation

- **Current**: Linux build/test/runtime PASS.
- **Gap**: iOS/watchOS/macOS SDK 및 Apple `os.Logger` 경로 NOT_RUN.
- **Preserve**: public DI contract와 platform declarations.
- **Done when**: Apple 환경에서 build/test/demo가 동일 contract로 PASS.

### WeaverMacros package validation

- **Current**: macro sources는 core API에 맞게 갱신됨.
- **Gap**: 현재 환경에서 `swift-syntax` repository fetch/cache 부재로 full SwiftPM test NOT_RUN.
- **Preserve**: core는 macros에 의존하지 않음.
- **Done when**: dependency fetch 가능한 환경에서 macro expansion tests PASS.

새 기능 목록이나 migration 작업은 없다.
