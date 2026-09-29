import Foundation
@testable import Moblin
import Testing

struct WhipHttpRedirectSuite {
    private func original() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://ingest.example/whip")!)
        request.httpMethod = "POST"
        request.httpBody = Data("offer".utf8)
        request.setValue("test-session-value", forHTTPHeaderField: "Authorization")
        request.setValue("test-custom-value", forHTTPHeaderField: "X-Custom-Credential")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        return request
    }

    @Test
    func sameOriginRestoresHeadersWithoutChangingMethodOrBody() throws {
        let initial = original()
        let delegate = WhipHttpRedirectDelegate(request: initial)
        var next = try URLRequest(url: #require(URL(string: "https://INGEST.example:443/other")))
        next.httpMethod = initial.httpMethod
        next.httpBody = initial.httpBody
        #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(next.value(forHTTPHeaderField: "X-Custom-Credential") == nil)
        let result = try #require(delegate.redirectedRequest(next, from: initial.url))
        #expect(result.value(forHTTPHeaderField: "Authorization") == "test-session-value")
        #expect(result.value(forHTTPHeaderField: "X-Custom-Credential") == "test-custom-value")
        #expect(result.httpMethod == "POST")
        #expect(result.httpBody == initial.httpBody)
    }

    @Test
    func crossOriginClearsAllSuppliedHeadersForPostAndDelete() throws {
        for method in ["POST", "DELETE"] {
            var initial = original()
            initial.httpMethod = method
            let delegate = WhipHttpRedirectDelegate(request: initial)
            for destination in ["https://other.example/path", "https://ingest.example:444/path"] {
                var next = initial
                next.url = try #require(URL(string: destination))
                next.setValue("test-cookie", forHTTPHeaderField: "Cookie")
                let result = try #require(delegate.redirectedRequest(next, from: initial.url))
                #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(result.value(forHTTPHeaderField: "X-Custom-Credential") == nil)
                #expect(result.value(forHTTPHeaderField: "Cookie") == nil)
                #expect(result.httpMethod == method)
                #expect(result.httpBody == initial.httpBody)
                #expect((result.allHTTPHeaderFields ?? [:]).count == (method == "POST" ? 1 : 0))
            }
        }
    }

    @Test
    func credentialsStayBoundToOriginalOriginAcrossHops() throws {
        let initial = original()
        let delegate = WhipHttpRedirectDelegate(request: initial)
        var other = initial
        other.url = try #require(URL(string: "https://other.example/first"))
        other = try #require(delegate.redirectedRequest(other, from: initial.url))
        var next = other
        next.url = try #require(URL(string: "https://other.example/second"))
        next = try #require(delegate.redirectedRequest(next, from: other.url))
        #expect(next.value(forHTTPHeaderField: "X-Custom-Credential") == nil)
        var back = next
        back.url = initial.url
        back = try #require(delegate.redirectedRequest(back, from: next.url))
        #expect(back.value(forHTTPHeaderField: "X-Custom-Credential") == "test-custom-value")
    }

    @Test
    func unsafeDestinationsAndTlsDowngradesAreRefused() throws {
        let initial = original()
        let delegate = WhipHttpRedirectDelegate(request: initial)
        for destination in ["http://ingest.example/path", "http://other.example/path",
                            "file:///tmp/offer", "https://user@ingest.example/path"]
        {
            var next = initial
            next.url = try #require(URL(string: destination))
            #expect(delegate.redirectedRequest(next, from: initial.url) == nil)
        }
    }

    @Test
    func methodChangingRedirectDoesNotRestoreBodyHeaders() throws {
        var initial = original()
        initial.setValue("5", forHTTPHeaderField: "Content-Length")
        let delegate = WhipHttpRedirectDelegate(request: initial)
        var next = try URLRequest(url: #require(URL(string: "https://ingest.example/other")))
        next.httpMethod = "GET"
        let result = try #require(delegate.redirectedRequest(next, from: initial.url))
        #expect(result.httpMethod == "GET")
        #expect(result.httpBody == nil)
        #expect(result.value(forHTTPHeaderField: "Content-Length") == nil)
        #expect(result.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(result.value(forHTTPHeaderField: "Authorization") == "test-session-value")
    }
}
