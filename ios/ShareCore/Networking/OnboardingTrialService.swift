//
//  OnboardingTrialService.swift
//  ShareCore
//
//  Registers this device for the Worker's per-device onboarding trial quota.
//  DeviceCheck proves the device is genuine and lets the Worker refuse a
//  second registration after the Keychain device ID is reset.
//

import DeviceCheck
import Foundation

@MainActor
enum OnboardingTrialService {
    // Registration is idempotent on the Worker, so it is only cached for the
    // current launch; a server-side reset recovers on the next launch.
    private static var registeredDeviceID: String?

    /// Device ID to send as `X-Onboarding-Device`, registering it first if needed.
    static func deviceID(using session: URLSession) async throws -> String {
        guard let deviceID = DeviceIdentifierStore.current() else {
            throw LLMServiceError.trialUnavailable
        }
        if registeredDeviceID == deviceID { return deviceID }
        try await register(deviceID: deviceID, using: session)
        registeredDeviceID = deviceID
        return deviceID
    }

    private static func register(deviceID: String, using session: URLSession) async throws {
        guard DCDevice.current.isSupported,
              let token = try? await DCDevice.current.generateToken()
        else {
            throw LLMServiceError.trialUnavailable
        }

        let path = "/onboarding/trial"
        var request = URLRequest(url: CloudServiceConstants.endpoint.appendingPathComponent("onboarding/trial"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        CloudAuthHelper.applyAuth(to: &request, path: path)
        request.httpBody = try JSONEncoder().encode([
            "deviceID": deviceID,
            "deviceToken": token.base64EncodedString(),
        ])

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ... 299).contains(statusCode) else {
            throw LLMServiceError.httpError(statusCode: statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}
