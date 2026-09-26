import AVFoundation
@preconcurrency import CallKit
import Foundation
import Models
import PushKit
import os

/// Wraps CXProvider so incoming calls ring when the app is closed or locked (CALL-2).
@MainActor
public final class CallKitProvider: NSObject {
    public struct IncomingCall: Sendable, Hashable {
        public var uuid: UUID
        public var callId: String
        public var nudgeId: String?
        public var callerName: String
    }

    private let provider: CXProvider
    private let controller = CXCallController()
    public private(set) var calls: [UUID: IncomingCall] = [:]
    private let log = Logger(subsystem: "app.nudge", category: "callkit")
    private var delegateBridge: ProviderDelegateBridge?

    public var onAnswer: ((IncomingCall) -> Void)?
    public var onEnd: ((IncomingCall) -> Void)?
    public var onMute: ((Bool) -> Void)?
    public var onAudioActivated: (() -> Void)?

    public override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        let bridge = ProviderDelegateBridge(owner: self)
        delegateBridge = bridge // CXProvider holds its delegate weakly
        provider.setDelegate(bridge, queue: .main)
    }

    /// Must be called for every VoIP push, synchronously, or iOS kills the app.
    public func reportIncoming(callId: String, nudgeId: String?, callerName: String, completion: @escaping @Sendable () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = true
        update.supportsGrouping = false
        update.supportsHolding = false
        calls[uuid] = IncomingCall(uuid: uuid, callId: callId, nudgeId: nudgeId, callerName: callerName)
        provider.reportNewIncomingCall(with: uuid, update: update) { [log] error in
            if let error { log.error("report incoming failed: \(String(describing: error), privacy: .public)") }
            completion()
        }
    }

    /// Reports an invalid VoIP push as an immediately-ended call (Apple requires a report either way).
    public func reportAndEndInvalid(completion: @escaping @Sendable () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.localizedCallerName = "Nudge"
        provider.reportNewIncomingCall(with: uuid, update: update) { [provider] _ in
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            completion()
        }
    }

    public func endCall(callId: String) {
        guard let entry = calls.first(where: { $0.value.callId == callId }) else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: entry.key))) { _ in }
        calls[entry.key] = nil
    }

    public func reportRemoteEnded(callId: String) {
        guard let entry = calls.first(where: { $0.value.callId == callId }) else { return }
        provider.reportCall(with: entry.key, endedAt: Date(), reason: .remoteEnded)
        calls[entry.key] = nil
    }

    fileprivate func answered(_ uuid: UUID) {
        if let call = calls[uuid] { onAnswer?(call) }
    }

    fileprivate func ended(_ uuid: UUID) {
        if let call = calls.removeValue(forKey: uuid) { onEnd?(call) }
    }
}

/// Non-isolated delegate that hops to the main actor.
private final class ProviderDelegateBridge: NSObject, CXProviderDelegate, @unchecked Sendable {
    weak var owner: CallKitProvider?
    init(owner: CallKitProvider) { self.owner = owner }

    func providerDidReset(_ provider: CXProvider) {}

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let uuid = action.callUUID
        MainActor.assumeIsolated { owner?.answered(uuid) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        MainActor.assumeIsolated { owner?.ended(uuid) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let muted = action.isMuted
        MainActor.assumeIsolated { owner?.onMute?(muted) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { owner?.onAudioActivated?() }
    }
}

/// PushKit registration + incoming VoIP payload handling (SPEC §3.9).
@MainActor
public final class VoIPPushHandler: NSObject {
    private let registry = PKPushRegistry(queue: .main)
    private let callKit: CallKitProvider
    public private(set) var token: String?
    public var onToken: ((String) -> Void)?
    private var bridge: RegistryBridge?

    public init(callKit: CallKitProvider) {
        self.callKit = callKit
        super.init()
    }

    public func register() {
        let bridge = RegistryBridge(owner: self)
        self.bridge = bridge
        registry.delegate = bridge
        registry.desiredPushTypes = [.voIP]
    }

    public struct Payload: Sendable, Hashable {
        public var callId: String
        public var nudgeId: String?
        public var callerName: String

        public init?(_ dict: [AnyHashable: Any]) {
            guard (dict["type"] as? String) == PushKind.callIncoming.rawValue, let callId = dict["callId"] as? String else { return nil }
            self.callId = callId
            self.nudgeId = dict["nudgeId"] as? String
            self.callerName = (dict["callerName"] as? String) ?? "Nudge"
        }
    }

    fileprivate func didUpdate(token data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        token = hex
        onToken?(hex)
    }

    fileprivate func didReceive(_ dict: [AnyHashable: Any], completion: @escaping @Sendable () -> Void) {
        if let p = Payload(dict) {
            callKit.reportIncoming(callId: p.callId, nudgeId: p.nudgeId, callerName: p.callerName, completion: completion)
        } else {
            callKit.reportAndEndInvalid(completion: completion)
        }
    }
}

private final class RegistryBridge: NSObject, PKPushRegistryDelegate, @unchecked Sendable {
    weak var owner: VoIPPushHandler?
    init(owner: VoIPPushHandler) { self.owner = owner }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let data = pushCredentials.token
        MainActor.assumeIsolated { owner?.didUpdate(token: data) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        nonisolated(unsafe) let dict = payload.dictionaryPayload
        nonisolated(unsafe) let done = completion
        MainActor.assumeIsolated { owner?.didReceive(dict, completion: { done() }) }
    }
}
