import Foundation

func whipSameOrigin(_ first: URL, _ second: URL) -> Bool {
    let scheme = first.scheme?.lowercased()
    return scheme == second.scheme?.lowercased()
        && first.host?.lowercased() == second.host?.lowercased()
        && (first.port ?? (scheme == "https" ? 443 : 80))
        == (second.port ?? (scheme == "https" ? 443 : 80))
}

final class WhipHttpRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let original: URLRequest

    init(request: URLRequest) {
        original = request
    }

    func redirectedRequest(_ request: URLRequest, from source: URL?) -> URLRequest? {
        guard let origin = original.url, let url = request.url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil,
              !(source?.scheme?.lowercased() == "https" && scheme == "http")
        else {
            return nil
        }
        var request = request
        if whipSameOrigin(origin, url) {
            for (name, value) in original.allHTTPHeaderFields ?? [:] {
                if request.httpMethod != original.httpMethod, name.lowercased().hasPrefix("content-") {
                    continue
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        } else {
            for name in (request.allHTTPHeaderFields ?? [:]).keys {
                request.setValue(nil, forHTTPHeaderField: name)
            }
            guard request.allHTTPHeaderFields?.isEmpty != false else {
                return nil
            }
            if request.httpMethod == "POST" {
                request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    func urlSession(_: URLSession, task _: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(redirectedRequest(request, from: response.url))
    }
}

func whipHttpRequest(request: URLRequest,
                     queue: DispatchQueue,
                     completion: ((Data?, URLResponse?, (any Error)?) -> Void)?)
{
    nonisolated(unsafe) let completion = completion
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        queue.async {
            completion?(data, response, error)
        }
    }
    task.delegate = WhipHttpRedirectDelegate(request: request)
    task.resume()
}
