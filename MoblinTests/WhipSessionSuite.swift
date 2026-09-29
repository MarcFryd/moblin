import Foundation
@testable import Moblin
import Testing

struct WhipSessionSuite {
    private let endpoint = URL(string: "https://ingest.example/whip")!
    private let headers = [SettingsHttpHeader(name: "Authorization", value: "test-session-value"),
                           SettingsHttpHeader(name: "X-Test-Session", value: "test-header-value")]

    @Test
    func relativeLocationRetainsSessionHeaders() throws {
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 201, httpVersion: nil,
                                                    headerFields: ["Location": "/sessions/one"]))
        let session = try #require(WhipSession(response: response, endpointUrl: endpoint, headers: headers))
        let request = session.deleteRequest()
        #expect(request.url?.absoluteString == "https://ingest.example/sessions/one")
        #expect(request.httpMethod == "DELETE")
        #expect(request.httpBody == nil)
        for header in headers {
            #expect(request.value(forHTTPHeaderField: header.name) == header.value)
        }
    }

    @Test
    func staleSessionKeepsItsOwnHeaderSnapshot() throws {
        var currentHeaders = headers
        let capturedHeaders = currentHeaders
        currentHeaders[0].value = "replacement-session-value"
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 201, httpVersion: nil,
                                                    headerFields: ["Location": "/sessions/old"]))
        let stale = try #require(WhipSession(response: response, endpointUrl: endpoint,
                                             headers: capturedHeaders))
        #expect(stale.deleteRequest().value(forHTTPHeaderField: "Authorization") == headers[0].value)
        #expect(stale.deleteRequest().value(forHTTPHeaderField: "Authorization") != currentHeaders[0].value)
    }

    @Test
    func defaultPortIsTheSameOrigin() throws {
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 201, httpVersion: nil,
                                                    headerFields: [
                                                        "Location": "https://ingest.example:443/session",
                                                    ]))
        let session = try #require(WhipSession(response: response, endpointUrl: endpoint, headers: headers))
        #expect(session.deleteRequest().value(forHTTPHeaderField: "Authorization") == headers[0].value)
    }

    @Test
    func differentOriginsNeverReceiveConfiguredHeaders() throws {
        for location in ["https://other.example/session", "http://ingest.example/session",
                         "https://ingest.example:444/session", "//other.example/session"]
        {
            let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 201, httpVersion: nil,
                                                        headerFields: ["Location": location]))
            let session = try #require(WhipSession(
                response: response,
                endpointUrl: endpoint,
                headers: headers
            ))
            for header in headers {
                #expect(session.deleteRequest().value(forHTTPHeaderField: header.name) == nil)
            }
        }
    }

    @Test
    func relativeLocationUsesTheFinalResponseUrl() throws {
        let redirected = try #require(URL(string: "https://other.example/publish/whip"))
        let response = try #require(HTTPURLResponse(url: redirected, statusCode: 201, httpVersion: nil,
                                                    headerFields: ["Location": "session/one"]))
        let session = try #require(WhipSession(response: response, endpointUrl: endpoint, headers: headers))
        #expect(session.url.absoluteString == "https://other.example/publish/session/one")
        #expect(session.deleteRequest().value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func missingOrUnsafeLocationsDoNotCreateSessions() throws {
        for fields in [[:], ["Location": ""], ["Location": "file:///tmp/session"],
                       ["Location": "https://user@ingest.example/session"]]
        {
            let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 201,
                                                        httpVersion: nil, headerFields: fields))
            #expect(WhipSession(response: response, endpointUrl: endpoint, headers: headers) == nil)
        }
    }
}
