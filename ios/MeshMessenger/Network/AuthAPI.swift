import Foundation

struct AuthAPI {
    let client: APIClient

    func requestOtp(phoneNumber: String) async throws {
        let resp: RequestOtpResult = try await client.post("auth/request-otp", body: RequestOtpRequest(phoneNumber: phoneNumber), authenticated: false)
        _ = resp
    }

    func verifyOtp(phoneNumber: String, otp: String, username: String?) async throws -> AuthResponse {
        try await client.post("auth/verify-otp", body: VerifyOtpRequest(phoneNumber: phoneNumber, otp: otp, username: username), authenticated: false)
    }

    func refresh(refreshToken: String) async throws -> AuthResponse {
        try await client.post("auth/refresh", body: RefreshRequest(refreshToken: refreshToken), authenticated: false)
    }

    func logout(refreshToken: String) async throws {
        try await client.postNoContent("auth/logout", body: LogoutRequest(refreshToken: refreshToken), authenticated: false)
    }
}

struct RequestOtpResult: Decodable {
    let sent: Bool
    let expiresInMinutes: Int
}
