import Foundation
import Result

/// Closure to be executed when a request has completed.
public typealias Completion = (result: Result<Moya.Response, Moya.Error>) -> ()

/// Closure to be executed when a request has completed.
public typealias ProgressBlock = (progress: ProgressResponse) -> Void

public struct ProgressResponse {
    public let totalBytes: Int64
    public let bytesExpected: Int64
    public let response: Response?
    
    init(totalBytes: Int64 = 0, bytesExpected: Int64 = 0, response: Response? = nil) {
        self.totalBytes = totalBytes
        self.bytesExpected = bytesExpected
        self.response = response
    }
    
    public var progress: Double {
        return bytesExpected > 0 ? min(Double(totalBytes) / Double(bytesExpected), 1.0) : 1.0
    }
    
    public var completed: Bool {
        return totalBytes >= bytesExpected && response != nil
    }
}

/// Represents an HTTP method.
public enum Method: String {
    case GET, POST, PUT, DELETE, OPTIONS, HEAD, PATCH, TRACE, CONNECT
}

public enum StubBehavior {
    case Never
    case Immediate
    case Delayed(seconds: NSTimeInterval)
}


public struct MultipartFormData {
    public enum FormDataProvider {
        case Data(NSData)
        case File(NSURL)
        case Stream(NSInputStream, UInt64)
    }
    
    public init(provider: FormDataProvider, name: String, fileName: String = "", mimeType: String = "") {
        self.provider = provider
        self.name = name
        self.fileName = fileName
        self.mimeType = mimeType
    }
    
    public let provider: FormDataProvider
    public let name: String
    public let fileName: String
    public let mimeType: String
}

/// Protocol to define the base URL, path, method, parameters and sample data for a target.
public protocol TargetType {
    var baseURL: NSURL { get }
    var path: String { get }
    var method: Moya.Method { get }
    var parameters: [String: AnyObject]? { get }
    var sampleData: NSData { get }
    var multipartBody: [MultipartFormData]? { get }
}

extension TargetType {
    internal var isMultipartUpload: Bool {
        guard let mBody = multipartBody else { return false }
        return (method == .POST || method == .PUT) && !mBody.isEmpty
    }
}

public enum StructTarget: TargetType {
    case Struct(TargetType)

    public init(_ target: TargetType) {
        self = StructTarget.Struct(target)
    }

    public var path: String {
        return target.path
    }

    public var baseURL: NSURL {
        return target.baseURL
    }

    public var method: Moya.Method {
        return target.method
    }

    public var parameters: [String: AnyObject]? {
        return target.parameters
    }

    public var sampleData: NSData {
        return target.sampleData
    }
    
    public var multipartBody: [MultipartFormData]? {
        return target.multipartBody
    }
    
    // 获取到关联的 target
    public var target: TargetType {
        switch self {
        case .Struct(let t): return t
        }
    }
}

/// Protocol to define the opaque type returned from a request
public protocol Cancellable {
    var cancelled: Bool { get }
    func cancel()
}

/// Request provider class. Requests should be made through this class only.
public class MoyaProvider<Target: TargetType> {

    /// Closure that defines the endpoints for the provider.
    public typealias EndpointClosure = Target -> Endpoint<Target>

    /// Closure that decides if and what request should be performed
    // 根据 RequestClosure 处理后的结果 RequestResult，如果 result 为 Success 则在内部执行实际的网络请求操作，否则放弃
    // 旧版本中没有改闭包定义
    public typealias RequestResultClosure = Result<NSURLRequest, Moya.Error> -> Void

    /// Closure that resolves an Endpoint into an RequestResult.
    public typealias RequestClosure = (Endpoint<Target>, RequestResultClosure) -> Void

    /// Closure that decides if/how a request should be stubbed.
    // 请求桩
    public typealias StubClosure = Target -> Moya.StubBehavior
    
    // 根据 target 生成 Endpoint
    public let endpointClosure: EndpointClosure
    // 将 Endpoint 转化为 Result<NSURLRequest, Moya.Error> 参数传给 RequestResultClosure；请求发起前的处理，如用户验证等。旧版本中 RequestResultClosure 为 NSURLRequest -> Void。这里可以根据需要将 Result 设置为 .Success 或 .Error 来决定当前请求要不要被发送。
    public let requestClosure: RequestClosure
    // 本地响应闭包
    public let stubClosure: StubClosure
    public let manager: Manager

    /// A list of plugins
    /// e.g. for logging, network activity indicator or credentials
    public let plugins: [PluginType]

    public let trackInflights: Bool

    public private(set) var inflightRequests = Dictionary<Endpoint<Target>, [Moya.Completion]>()

    /// Initializes a provider.
    // 提供创建 provider 所需要的的各种闭包
    public init(endpointClosure: EndpointClosure = MoyaProvider.DefaultEndpointMapping,
        requestClosure: RequestClosure = MoyaProvider.DefaultRequestMapping,
        stubClosure: StubClosure = MoyaProvider.NeverStub,
        manager: Manager = MoyaProvider<Target>.DefaultAlamofireManager(),
        plugins: [PluginType] = [],
        trackInflights: Bool = false) {

            self.endpointClosure = endpointClosure
            self.requestClosure = requestClosure
            self.stubClosure = stubClosure
            self.manager = manager
            self.plugins = plugins
            self.trackInflights = trackInflights
    }

    /// Returns an Endpoint based on the token, method, and parameters by invoking the endpointsClosure.
    // 根据初始化指定的生成 Endpoint 闭包生成对应的 Endpoint
    public func endpoint(token: Target) -> Endpoint<Target> {
        return endpointClosure(token)
    }

    /// Designated request-making method with queue option. Returns a Cancellable token to cancel the request later.
    public func request(target: Target, queue: dispatch_queue_t?, progress: Moya.ProgressBlock? = nil, completion: Moya.Completion) -> Cancellable {
        if target.isMultipartUpload {
            return requestMultipart(target, queue: queue, progress: progress, completion: completion)
        } else {
            return requestNormal(target, queue: queue, completion: completion)
        }
    }
    
    internal func requestNormal(target: Target, queue: dispatch_queue_t?, completion: Moya.Completion) -> Cancellable {
        let endpoint = self.endpoint(target) // 调用 endpointClosure
        let stubBehavior = self.stubClosure(target) // 调用stubClosure，设置本地响应（如果为 .Never 则为正常网络响应）
        var cancellableToken = CancellableWrapper()

        if trackInflights {
            objc_sync_enter(self)
            var inflightCompletionBlocks = self.inflightRequests[endpoint]
            inflightCompletionBlocks?.append(completion)
            self.inflightRequests[endpoint] = inflightCompletionBlocks
            objc_sync_exit(self)

            if inflightCompletionBlocks != nil {
                return cancellableToken
            } else {
                objc_sync_enter(self)
                self.inflightRequests[endpoint] = [completion]
                objc_sync_exit(self)
            }
        }

        let performNetworking = { (requestResult: Result<NSURLRequest, Moya.Error>) in
            if cancellableToken.cancelled { return }

            var request: NSURLRequest!

            // 通过值捕获保存请求结束时的完成闭包 completion
            
            switch requestResult {
            case .Success(let urlRequest):
                request = urlRequest
            case .Failure(let error):
                completion(result: .Failure(error))
                return
            }

            switch stubBehavior {
            case .Never:
                cancellableToken.innerCancellable = self.sendRequest(target, request: request, queue: queue, completion: { result in
                    // sendRequest 会发起请求，并对响应进行预处理（转为 result）
                    if self.trackInflights {
                        self.inflightRequests[endpoint]?.forEach({ $0(result: result) })

                        objc_sync_enter(self)
                        self.inflightRequests.removeValueForKey(endpoint)
                        objc_sync_exit(self)
                    } else {
                        // 将转换后的 result 传给完成闭包 completion
                        completion(result: result)
                    }
                })
            default:
                cancellableToken.innerCancellable = self.stubRequest(target, request: request, completion: { result in
                    if self.trackInflights {
                        self.inflightRequests[endpoint]?.forEach({ $0(result: result) })

                        objc_sync_enter(self)
                        self.inflightRequests.removeValueForKey(endpoint)
                        objc_sync_exit(self)
                    } else {
                        completion(result: result)
                    }
                }, endpoint: endpoint, stubBehavior: stubBehavior)
            }
        }

        requestClosure(endpoint, performNetworking)

        return cancellableToken
    }
    
    internal func requestMultipart(target: Target, queue: dispatch_queue_t?, progress: Moya.ProgressBlock? = nil, completion: Moya.Completion) -> Cancellable {
        guard let multipartBody = target.multipartBody where multipartBody.count > 0 else {
            fatalError("\(target) is not a multipart upload target.")
        }
        
        let endpoint = self.endpoint(target)
        let stubBehavior = self.stubClosure(target)
        var cancellableToken = CancellableWrapper()
        
        let performNetworking = { (requestResult: Result<NSURLRequest, Moya.Error>) in
            if cancellableToken.cancelled { return }
            
            var request: NSURLRequest!
            
            switch requestResult {
            case .Success(let urlRequest):
                request = urlRequest
            case .Failure(let error):
                completion(result: .Failure(error))
                return
            }
            
            switch stubBehavior {
            case .Never:
                cancellableToken = self.sendUpload(target, request: request, queue: queue, multipartBody: multipartBody, progress: progress, completion: { result in
                    if self.trackInflights {
                        self.inflightRequests[endpoint]?.forEach({ $0(result: result) })
                        
                        objc_sync_enter(self)
                        self.inflightRequests.removeValueForKey(endpoint)
                        objc_sync_exit(self)
                    } else {
                        completion(result: result)
                    }
                })
            default:
                cancellableToken.innerCancellable = self.stubRequest(target, request: request, completion: { result in
                    if self.trackInflights {
                        self.inflightRequests[endpoint]?.forEach({ $0(result: result) })
                        
                        objc_sync_enter(self)
                        self.inflightRequests.removeValueForKey(endpoint)
                        objc_sync_exit(self)
                    } else {
                        completion(result: result)
                    }
                }, endpoint: endpoint, stubBehavior: stubBehavior)
            }
        }
        
        requestClosure(endpoint, performNetworking)
        
        return cancellableToken
    }
    
    /// Designated request-making method. Returns a Cancellable token to cancel the request later.
    public func request(target: Target, completion: Moya.Completion) -> Cancellable {
        return self.request(target, queue: nil, completion: completion)
    }

    /// When overriding this method, take care to `notifyPluginsOfImpendingStub` and to perform the stub using the `createStubFunction` method.
    /// Note: this was previously in an extension, however it must be in the original class declaration to allow subclasses to override.
    internal func stubRequest(target: Target, request: NSURLRequest, completion: Moya.Completion, endpoint: Endpoint<Target>, stubBehavior: Moya.StubBehavior) -> CancellableToken {
        let cancellableToken = CancellableToken { }
        notifyPluginsOfImpendingStub(request, target: target)
        let plugins = self.plugins
        let stub: () -> () = createStubFunction(cancellableToken, forTarget: target, withCompletion: completion, endpoint: endpoint, plugins: plugins)
        switch stubBehavior {
        case .Immediate:
            stub()
        case .Delayed(let delay):
            let killTimeOffset = Int64(CDouble(delay) * CDouble(NSEC_PER_SEC))
            let killTime = dispatch_time(DISPATCH_TIME_NOW, killTimeOffset)
            dispatch_after(killTime, dispatch_get_main_queue()) {
                stub()
            }
        case .Never:
            fatalError("Method called to stub request when stubbing is disabled.")
        }

        return cancellableToken
    }
}

/// Mark: Defaults

public extension MoyaProvider {

    // These functions are default mappings to MoyaProvider's properties: endpoints, requests, manager, etc.
    // 生成默认的 Endpoint
    public final class func DefaultEndpointMapping(target: Target) -> Endpoint<Target> {
        // 获取 Target 中的 url
        let url = target.baseURL.URLByAppendingPathComponent(target.path).absoluteString
        return Endpoint(URL: url, sampleResponseClosure: {.NetworkResponse(200, target.sampleData)}, method: target.method, parameters: target.parameters)
    }

    // 这里没有做处理，只是把 endpoint 直接转为 Result<NSURLRequest, Moya.Error> 类型
    public final class func DefaultRequestMapping(endpoint: Endpoint<Target>, closure: RequestResultClosure) {
        return closure(.Success(endpoint.urlRequest))
    }

    // 获取 AlamofireManager
    public final class func DefaultAlamofireManager() -> Manager {
        let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
        configuration.HTTPAdditionalHeaders = Manager.defaultHTTPHeaders

        let manager = Manager(configuration: configuration)
        manager.startRequestsImmediately = false
        return manager
    }
}

/// Mark: Stubbing

public extension MoyaProvider {

    // Swift won't let us put the StubBehavior enum inside the provider class, so we'll
    // at least add some class functions to allow easy access to common stubbing closures.

    public final class func NeverStub(_: Target) -> Moya.StubBehavior {
        return .Never
    }

    public final class func ImmediatelyStub(_: Target) -> Moya.StubBehavior {
        return .Immediate
    }

    public final class func DelayedStub(seconds: NSTimeInterval) -> (Target) -> Moya.StubBehavior {
        return { _ in return .Delayed(seconds: seconds) }
    }
}

internal extension MoyaProvider {
    
    private func sendUpload(target: Target, request: NSURLRequest, queue: dispatch_queue_t?, multipartBody:[MultipartFormData], progress: Moya.ProgressBlock? = nil, completion: Moya.Completion) -> CancellableWrapper {
        var cancellable = CancellableWrapper()
        let plugins = self.plugins
        
        let multipartFormData = { (form: RequestMultipartFormData) -> Void in
            for bodyPart in multipartBody {
                switch bodyPart.provider {
                case .Data(let data):
                    form.appendBodyPart(data: data, name: bodyPart.name, fileName: bodyPart.fileName, mimeType: bodyPart.mimeType)
                case .File(let url):
                    form.appendBodyPart(fileURL: url, name: bodyPart.name, fileName: bodyPart.fileName, mimeType: bodyPart.mimeType)
                case .Stream(let stream, let length):
                    form.appendBodyPart(stream: stream, length: length, name: bodyPart.name, fileName: bodyPart.fileName, mimeType: bodyPart.mimeType)
                }
            }
            
            if let parameters = target.parameters {
                parameters
                    .flatMap{ (key, value) in multipartQueryComponents(key, value) }
                    .forEach{ (key, value) in
                        let data = value.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
                        form.appendBodyPart(data: data!, name: key)
                }
            }
        }
        
        manager.upload(request, multipartFormData: multipartFormData) {(result: MultipartFormDataEncodingResult) in
            switch result {
            case .Success(let alamoRequest, _, _):
                // Give plugins the chance to alter the outgoing request
                plugins.forEach { $0.willSendRequest(alamoRequest, target: target) }
                
                // Perform the actual request
                alamoRequest
                    .progress { (bytesWritten, totalBytesWritten, totalBytesExpected) in
                        let sendProgress: () -> () = {
                            progress?(progress: ProgressResponse(totalBytes: totalBytesWritten, bytesExpected: totalBytesExpected))
                        }
                        
                        if let queue = queue {
                            dispatch_async(queue, sendProgress)
                        }
                        else {
                            sendProgress()
                        }
                    }
                    .response(queue: queue) { (_, response: NSHTTPURLResponse?, data: NSData?, error: NSError?) -> () in
                        let result = convertResponseToResult(response, data: data, error: error)
                        // Inform all plugins about the response
                        plugins.forEach { $0.didReceiveResponse(result, target: target) }
                        completion(result: result)
                }
                
                if cancellable.cancelled { return }
                
                alamoRequest.resume()
                
                cancellable.innerCancellable = CancellableToken(request: alamoRequest)
            case .Failure(let error):
                completion(result: .Failure(Moya.Error.Underlying(error as NSError)))
            }
        }
        
        return cancellable
    }


    // 发送网络请求
    func sendRequest(target: Target, request: NSURLRequest, queue: dispatch_queue_t?, completion: Moya.Completion) -> CancellableToken {
        // 由于初始化时默认 manager.startRequestsImmediately 已被设为 false，所以不会立即发起请求（使用自定义 manager 且未将 startRequestsImmediately 设为 false 时， plugins 的 willSendRequest 和 didReceiveResponse 可能会有问题）
        let alamoRequest = manager.request(request)
        let plugins = self.plugins

        // Give plugins the chance to alter the outgoing request
      plugins.forEach { $0.willSendRequest(alamoRequest, target: target) }

        // Perform the actual request
        // 将相应闭包加入 Alamofire task 的队列， 请求结束后会调用
        alamoRequest.response(queue: queue) { (_, response: NSHTTPURLResponse?, data: NSData?, error: NSError?) -> () in
            // 先将响应进行预处理
            let result = convertResponseToResult(response, data: data, error: error)
            // Inform all plugins about the response
            plugins.forEach { $0.didReceiveResponse(result, target: target) }
            completion(result: result)
        }

        alamoRequest.resume()

        // CancellableToken 会绑定对应的 alamoRequest，当调用 CancellableToken.cancel() 时实际会调用 alamoRequest.cancel() 方法结束请求
        return CancellableToken(request: alamoRequest)
    }

    /// Creates a function which, when called, executes the appropriate stubbing behavior for the given parameters.
    // 生成 stub function，这里会根据 TargetType 的 SampleResponce 直接调用对应的 Responce 而不会进行实际的网络请求
    internal final func createStubFunction(token: CancellableToken, forTarget target: Target, withCompletion completion: Moya.Completion, endpoint: Endpoint<Target>, plugins: [PluginType]) -> (() -> ()) {
        return {
            if token.cancelled {
                let error = Moya.Error.Underlying(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil))
                plugins.forEach { $0.didReceiveResponse(.Failure(error), target: target) }
                completion(result: .Failure(error))
                return
            }

            switch endpoint.sampleResponseClosure() {
            case .NetworkResponse(let statusCode, let data):
                let response = Moya.Response(statusCode: statusCode, data: data, response: nil)
                plugins.forEach { $0.didReceiveResponse(.Success(response), target: target) }
                completion(result: .Success(response))
            case .NetworkError(let error):
                let error = Moya.Error.Underlying(error)
                plugins.forEach { $0.didReceiveResponse(.Failure(error), target: target) }
                completion(result: .Failure(error))
            }
        }
    }

    /// Notify all plugins that a stub is about to be performed. You must call this if overriding `stubRequest`.
    internal final func notifyPluginsOfImpendingStub(request: NSURLRequest, target: Target) {
        let alamoRequest = manager.request(request)
        plugins.forEach { $0.willSendRequest(alamoRequest, target: target) }
    }
}

public func convertResponseToResult(response: NSHTTPURLResponse?, data: NSData?, error: NSError?) ->
    Result<Moya.Response, Moya.Error> {
    switch (response, data, error) {
    case let (.Some(response), .Some(data), .None):
        let response = Moya.Response(statusCode: response.statusCode, data: data, response: response)
        return .Success(response)
    case let (_, _, .Some(error)):
        let error = Moya.Error.Underlying(error)
        return .Failure(error)
    default:
        let error = Moya.Error.Underlying(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: nil))
        return .Failure(error)
    }
}

internal class CancellableWrapper: Cancellable {
    internal var innerCancellable: Cancellable = SimpleCancellable()

    var cancelled: Bool { return innerCancellable.cancelled ?? false }

    internal func cancel() {
        innerCancellable.cancel()
    }
}

internal class SimpleCancellable: Cancellable {
    var cancelled = false
    func cancel() {
        cancelled = true
    }
}

/**
 Encode parameters for multipart/form-data
 */
private func multipartQueryComponents(key: String, _ value: AnyObject) -> [(String, String)] {
    var components: [(String, String)] = []
    
    if let dictionary = value as? [String: AnyObject] {
        for (nestedKey, value) in dictionary {
            components += multipartQueryComponents("\(key)[\(nestedKey)]", value)
        }
    } else if let array = value as? [AnyObject] {
        for value in array {
            components += multipartQueryComponents("\(key)[]", value)
        }
    } else {
        components.append((key, "\(value)"))
    }
    
    return components
}
