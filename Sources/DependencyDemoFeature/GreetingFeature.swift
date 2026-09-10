public protocol GreetingService: Sendable {
  func greeting() -> String
}

public struct GreetingFeature: Sendable {
  private let service: any GreetingService

  public init(service: any GreetingService) {
    self.service = service
  }

  public func message() -> String {
    service.greeting()
  }
}
