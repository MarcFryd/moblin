import Foundation

struct WhipSession {
    let url: URL
    private let headers: [SettingsHttpHeader]

    init?(response: HTTPURLResponse, endpointUrl: URL, headers: [SettingsHttpHeader]) {
        guard let location = response.value(forHTTPHeaderField: "Location"), !location.isEmpty,
              let url = URL(string: location, relativeTo: response.url ?? endpointUrl)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil
        else {
            return nil
        }
        self.url = url
        self.headers = whipSameOrigin(endpointUrl, url) ? headers : []
    }

    func deleteRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }
}
