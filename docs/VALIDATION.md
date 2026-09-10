# Validation

최종 package 생성 시 실제 로그는 상위 `validation/` 디렉터리에 보존한다.

검증 원칙:

1. `swift-format lint`
2. `swift test`
3. release `swift build -Xswiftc -warnings-as-errors`
4. `swift run DependencyDemoApp`
5. stale global API/source scan
6. feature target dependency boundary 검사
7. package extraction 후 재검증

Apple SDK 검증은 현재 환경에서 NOT_RUN으로 유지한다.
