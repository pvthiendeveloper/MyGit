import Foundation

protocol CredentialRepository: Sendable {
    func token(host: String) -> String?
    func hasToken(host: String) -> Bool
    func setToken(_ token: String, host: String)
    func delete(host: String)
}
