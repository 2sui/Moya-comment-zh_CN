import Foundation
import Alamofire

public typealias Manager = Alamofire.Manager

/// Choice of parameter encoding.
public typealias ParameterEncoding = Alamofire.ParameterEncoding

/// Multipart form
public typealias RequestMultipartFormData = Alamofire.MultipartFormData

/// Multipart form data encoding result.
public typealias MultipartFormDataEncodingResult = Alamofire.Manager.MultipartFormDataEncodingResult

/// Make the Alamofire Request type conform to our type, to prevent leaking Alamofire to plugins.
extension Request: RequestType { }

/// Internal token that can be used to cancel requests
// 间接调用 Alamofire 的 request.cancel() 方法
public final class CancellableToken: Cancellable, CustomDebugStringConvertible {
    let cancelAction: () -> Void
    let request: Request?
    private(set) public var cancelled: Bool = false

    private var lock: dispatch_semaphore_t = dispatch_semaphore_create(1)

    public func cancel() {
        dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER)
        defer { dispatch_semaphore_signal(lock) }
        guard !cancelled else { return }
        cancelled = true
        cancelAction()
    }

    init(action: () -> Void) {
        self.cancelAction = action
        self.request = nil
    }

    init(request: Request) {
        self.request = request
        self.cancelAction = {
            request.cancel()
        }
    }

    public var debugDescription: String {
        guard let request = self.request else {
            return "Empty Request"
        }
        return request.debugDescription
    }

}
