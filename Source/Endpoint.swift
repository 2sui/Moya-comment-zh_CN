import Foundation

/// Used for stubbing responses.
public enum EndpointSampleResponse {

    /// The network returned a response, including status code and data.
    case NetworkResponse(Int, NSData)

    /// The network failed to send the request, or failed to retrieve a response (eg a timeout).
    case NetworkError(NSError)
}


/// Class for reifying a target of the Target enum unto a concrete Endpoint.
public class Endpoint<Target> {
    public typealias SampleResponseClosure = () -> EndpointSampleResponse

    public let URL: String  // 请求地址
    public let method: Moya.Method  // 请求方法
    public let sampleResponseClosure: SampleResponseClosure // 模拟响应闭包，当 MoyaProvider 的 stubClosure 不为 MoyaProvider.NeverStub 时会调用该闭包去模拟网络响应而不会真正请求网络（可用于测试或进行本地响应）
    public let parameters: [String: AnyObject]?
    public let parameterEncoding: Moya.ParameterEncoding
    public let httpHeaderFields: [String: String]?

    /// Main initializer for Endpoint.
    public init(URL: String,
        sampleResponseClosure: SampleResponseClosure,
        method: Moya.Method = Moya.Method.GET,
        parameters: [String: AnyObject]? = nil,
        parameterEncoding: Moya.ParameterEncoding = .URL,
        httpHeaderFields: [String: String]? = nil) {

        // 请求的 URL
        self.URL = URL
        // 模拟本地响应闭包
        self.sampleResponseClosure = sampleResponseClosure
        // 请求方法
        self.method = method
        // 请求参数
        self.parameters = parameters
        // 请求编码
        self.parameterEncoding = parameterEncoding
        // 请求头
        self.httpHeaderFields = httpHeaderFields
    }

    /// Convenience method for creating a new Endpoint with the same properties as the receiver, but with added parameters.
    public func endpointByAddingParameters(parameters: [String: AnyObject]) -> Endpoint<Target> {
        return endpointByAdding(parameters: parameters)
    }

    /// Convenience method for creating a new Endpoint with the same properties as the receiver, but with added HTTP header fields.
    public func endpointByAddingHTTPHeaderFields(httpHeaderFields: [String: String]) -> Endpoint<Target> {
        return endpointByAdding(httpHeaderFields: httpHeaderFields)
    }

    /// Convenience method for creating a new Endpoint with the same properties as the receiver, but with another parameter encoding.
    public func endpointByAddingParameterEncoding(newParameterEncoding: Moya.ParameterEncoding) -> Endpoint<Target> {
        return endpointByAdding(parameterEncoding: newParameterEncoding)
    }

    /// Convenience method for creating a new Endpoint, with changes only to the properties we specify as parameters
    /// 扩展当前 Endpoint， 会根据当前 Endpoint 创建一个新的 Endpoint 并返回。
    public func endpointByAdding(parameters parameters: [String: AnyObject]? = nil, httpHeaderFields: [String: String]? = nil, parameterEncoding: Moya.ParameterEncoding? = nil)  -> Endpoint<Target> {
        let newParameters = addParameters(parameters)
        let newHTTPHeaderFields = addHTTPHeaderFields(httpHeaderFields)
        let newParameterEncoding = parameterEncoding ?? self.parameterEncoding
        return Endpoint(URL: URL, sampleResponseClosure: sampleResponseClosure, method: method, parameters: newParameters, parameterEncoding: newParameterEncoding, httpHeaderFields: newHTTPHeaderFields)
    }

    // 复制当前 parameters 成员，扩展后返回。
    private func addParameters(parameters: [String: AnyObject]?) -> [String: AnyObject]? {
        guard let unwrappedParameters = parameters where unwrappedParameters.isEmpty == false else {
            return self.parameters
        }

        var newParameters = self.parameters ?? [String: AnyObject]()
        unwrappedParameters.forEach { (key, value) in
            newParameters[key] = value
        }
        return newParameters
    }
    
    // 复制当前 httpHeaderFields 成员，扩展后返回。
    private func addHTTPHeaderFields(headers: [String: String]?) -> [String: String]? {
        guard let unwrappedHeaders = headers where unwrappedHeaders.isEmpty == false else {
            return self.httpHeaderFields
        }

        var newHTTPHeaderFields = self.httpHeaderFields ?? [String: String]()
        unwrappedHeaders.forEach { (key, value) in
            newHTTPHeaderFields[key] = value
        }
        return newHTTPHeaderFields
    }
}

/// Extension for converting an Endpoint into an NSURLRequest.
extension Endpoint {
    // 创建 URLRequest 并设置请求方法、请求头和请求编码
    public var urlRequest: NSURLRequest {
        let request: NSMutableURLRequest = NSMutableURLRequest(URL: NSURL(string: URL)!) // swiftlint:disable:this force_unwrapping
        request.HTTPMethod = method.rawValue
        request.allHTTPHeaderFields = httpHeaderFields

        return parameterEncoding.encode(request, parameters: parameters).0
    }
}

/// Required for making Endpoint conform to Equatable.
// 重载复制操作符
public func == <T>(lhs: Endpoint<T>, rhs: Endpoint<T>) -> Bool {
    return lhs.urlRequest.isEqual(rhs.urlRequest)
}

/// Required for using Endpoint as a key type in a Dictionary.
// 获取当前 URLRequest 的 hash 值
extension Endpoint: Equatable, Hashable {
    public var hashValue: Int {
        return urlRequest.hash
    }
}
