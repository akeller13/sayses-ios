import Foundation

struct WorkspaceLookupResponse: Codable {
    let found: Bool
    let subdomain: String?
    let workspaceName: String?
    let workspaceUrl: String?
    let apiUrl: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case found
        case subdomain
        case workspaceName = "workspace_name"
        case workspaceUrl = "workspace_url"
        case apiUrl = "api_url"
        case message
    }
}
