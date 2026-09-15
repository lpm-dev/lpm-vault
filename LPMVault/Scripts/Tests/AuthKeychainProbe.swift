import Foundation

enum AuthSessionCoordinatorError: Error {
    case credentialStorage(String)
}

@main
struct AuthKeychainProbe {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1].hasPrefix("lpm-cli.test.") else {
            fatalError("Only isolated test services are accepted")
        }
        let backend = KeychainAuthCredentialBackend(service: arguments[1])
        guard try backend.read(account: arguments[2]) == "lpm_access_token" else {
            fatalError("Swift could not read the Rust test credential")
        }
        try backend.write("swift_interop_token", account: arguments[2])
    }
}
