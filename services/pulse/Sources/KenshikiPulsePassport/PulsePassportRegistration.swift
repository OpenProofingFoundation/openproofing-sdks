import Foundation
import Security
import KenshikiOperationBinding
#if os(iOS) && canImport(DeviceCheck)
import DeviceCheck
#endif

/// A host-named, device-only Keychain slot. Reference apps choose their own namespace;
/// Pulse injects its existing installation custody through the storage/keys initializer.
public struct PulsePassportRegistrationSlot: Sendable {
    public init(service:String,account:String,group:String) {self.service=service;self.account=account;self.group=group}
    let service: String
    let account: String
    let group: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group,
         kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 1_048_576 else {
            throw PulsePassportRegistrationFailure.credentials
        }
        return data
    }
    func delete() throws {
        let status=SecItemDelete(query as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else {throw PulsePassportRegistrationFailure.credentials}
    }

    func save(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw PulsePassportRegistrationFailure.credentials }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem {
            let status = SecItemUpdate(query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw PulsePassportRegistrationFailure.credentials }
        } else if added != errSecSuccess { throw PulsePassportRegistrationFailure.credentials }
    }
}

public struct PulsePassportRegistrationStorage: Sendable {
    let load: @Sendable () async throws -> Data?
    let save: @Sendable (Data) async throws -> Void
    let delete: @Sendable () async throws -> Void
    public init(load:@escaping @Sendable()async throws->Data?,save:@escaping @Sendable(Data)async throws->Void,delete:@escaping @Sendable()async throws->Void = {throw PulsePassportRegistrationFailure.credentials}) {self.load=load;self.save=save;self.delete=delete}
}

/// Bridges the host's existing erasure barrier without importing its app or legacy SDK.
/// An admitted begin holds one lease until the complete durable mutation finishes.
public struct PulsePassportRegistrationMutationLease:Sendable {
    let begin:@Sendable()async->Bool
    let end:@Sendable()async->Void
    public init(begin:@escaping @Sendable()async->Bool,end:@escaping @Sendable()async->Void) {self.begin=begin;self.end=end}
}

/// Bootstraps only this app's installation. Shared custody owns the one-time attestation lifecycle.
public actor PulsePassportRegistration {
    private let configuration: PulsePassportRegistrationConfiguration
    private let transport: any PulseBoundedHTTPTransport
    private let app: PulsePassportAppMetadata
    private let device: PulsePassportDeviceMetadata
    private let storage: PulsePassportRegistrationStorage
    private let keys: RegisteredKeyEnrollmentPorts
    private let eraseKeys:@Sendable()async throws->Void
    private let mutationLease:PulsePassportRegistrationMutationLease
    private let onCustodyErased:@Sendable() -> Void

    @MainActor public static func live(baseURL:URL,environment:String,applicationIdentifier:String,
        keychainAccessGroup:String,namespace:String,app:PulsePassportAppMetadata,device:PulsePassportDeviceMetadata) throws -> PulsePassportRegistration {
        #if os(iOS) && canImport(DeviceCheck)
        guard DCAppAttestService.shared.isSupported, !namespace.isEmpty,!keychainAccessGroup.isEmpty,
            ["production","development"].contains(environment),
            applicationIdentifier.range(of:"^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$",options:.regularExpression) != nil,
            !applicationIdentifier.hasPrefix("4D9FAKD487.") else {throw PulsePassportRegistrationFailure.configuration}
        let config=PulsePassportRegistrationConfiguration(baseURL:baseURL,appAttestEnvironment:environment,applicationIdentifier:applicationIdentifier)
        try PulseRegistrationRequestAuthority.validate(config)
        return .init(configuration:config,credentialSlot:.init(service:namespace,account:"installation",group:keychainAccessGroup),
            keySlot:.init(service:namespace,account:"registered-key",group:keychainAccessGroup),transport:URLSessionPulseBoundedHTTPTransport(),app:app,device:device)
        #else
        throw PulsePassportRegistrationFailure.unsupported
        #endif
    }

    public init(configuration: PulsePassportRegistrationConfiguration, credentialSlot: PulsePassportRegistrationSlot,
         keySlot: PulsePassportRegistrationSlot, transport: any PulseBoundedHTTPTransport,
         app: PulsePassportAppMetadata, device: PulsePassportDeviceMetadata,
         storage: PulsePassportRegistrationStorage? = nil, keys: RegisteredKeyEnrollmentPorts? = nil, eraseKeys:(@Sendable()async throws->Void)? = nil,
         mutationLease:PulsePassportRegistrationMutationLease = .init(begin:{true},end:{}),
         onCustodyErased:@escaping @Sendable() -> Void = {}) {
        self.configuration = configuration;self.mutationLease=mutationLease;self.onCustodyErased=onCustodyErased
        self.transport = transport; self.app = app; self.device = device
        self.storage = storage ?? .init(load: { try credentialSlot.load() }, save: { try credentialSlot.save($0) },delete:{try credentialSlot.delete()})
        self.keys = keys ?? Self.platformKeys(keySlot)
        if let eraseKeys { self.eraseKeys=eraseKeys }
        else if keys == nil { self.eraseKeys = { @Sendable in
            try keySlot.delete()
            guard try keySlot.load()==nil else {throw PulsePassportRegistrationFailure.credentials}
        } } else { self.eraseKeys = { @Sendable in throw PulsePassportRegistrationFailure.credentials } }
    }

    public init(configuration:PulsePassportRegistrationConfiguration,storage:PulsePassportRegistrationStorage,
        keys:RegisteredKeyEnrollmentPorts,eraseKeys:@escaping @Sendable()async throws->Void,
        transport:any PulseBoundedHTTPTransport = URLSessionPulseBoundedHTTPTransport(),app:PulsePassportAppMetadata,device:PulsePassportDeviceMetadata,
        mutationLease:PulsePassportRegistrationMutationLease = .init(begin:{true},end:{}),
         onCustodyErased:@escaping @Sendable() -> Void = {}) {
        self.configuration=configuration;self.mutationLease=mutationLease;self.onCustodyErased=onCustodyErased
        self.transport=transport;self.app=app;self.device=device
        self.storage=storage;self.keys=keys;self.eraseKeys=eraseKeys
    }

    private static func platformKeys(_ keySlot:PulsePassportRegistrationSlot) -> RegisteredKeyEnrollmentPorts {
        #if os(iOS) && canImport(DeviceCheck)
        return .init(load: { try keySlot.load() }, save: { try keySlot.save($0) },
            generate: { try await DCAppAttestService.shared.generateKey() },
            attest: { try await DCAppAttestService.shared.attestKey($0, clientDataHash: $1) },
            assert: { try await RegisteredAppAttestSigner.shared.assertion(keyID: $0, clientDataHash: $1) })
        #else
        return .init(load:{try keySlot.load()},save:{try keySlot.save($0)},generate:{throw PulsePassportRegistrationFailure.unsupported},attest:{_,_ in throw PulsePassportRegistrationFailure.unsupported},assert:{_,_ in throw PulsePassportRegistrationFailure.unsupported})
        #endif
    }

    private struct KeyIdentity:Equatable {let installationID:String;let keyID:String}
    private enum Mutation {case ensure,recover,deadKey}
    private struct Flight {let id:UUID;let kind:Mutation;let task:Task<PulsePassportCredentials,Error>}
    private var flight:Flight?
    private var custodyGeneration=UUID()
    private(set) var erasing=false
    private func requireGeneration(_ generation:UUID) throws {
        guard !erasing,custodyGeneration==generation else {throw PulsePassportServiceFailure.invalidated}
    }
    private func awaitMutation(_ task:Task<PulsePassportCredentials,Error>,generation:UUID) async throws->PulsePassportCredentials {
        do {
            let value=try await task.value
            try requireGeneration(generation);try Task.checkCancellation()
            return value
        } catch {try requireGeneration(generation);throw error}
    }
    private func mutate(_ kind:Mutation, expected:KeyIdentity? = nil) async throws -> PulsePassportCredentials {
        let generation=custodyGeneration
        try requireGeneration(generation)
        while let running=flight {
            let join = kind == .ensure || kind == running.kind || kind == .recover && running.kind == .deadKey
            if join {return try await awaitMutation(running.task,generation:generation)}
            do {_ = try await running.task.value} catch { /* Requested different mutation still must run. */ }
            try requireGeneration(generation)
            if flight?.id == running.id {flight=nil}
        }
        let id=UUID()
        let task=Task {
            guard await self.mutationLease.begin() else {throw PulsePassportServiceFailure.invalidated}
            do {
                try self.requireGeneration(generation)
                let value:PulsePassportCredentials
                switch kind {case .ensure:value=try await self.performEnsure();case .recover:value=try await self.performRecovery();case .deadKey:value=try await self.replaceDeadKey(expected:expected)}
                await self.mutationLease.end()
                return value
            } catch {
                // Each admitted lease ends exactly once, including generation/cancellation failure.
                await self.mutationLease.end()
                throw error
            }
        }
        flight = .init(id:id,kind:kind,task:task)
        defer {if flight?.id == id {flight=nil}}
        return try await awaitMutation(task,generation:generation)
    }

    /// Close admission and drain admitted work before removing either retained slot.
    /// The host may call this inside its already-raised erasure barrier.
    public func eraseLocalCredentials() async throws {
        try await closeAndDrain()
        defer {erasing=false}
        try await clearLocalCustody()
        // Publish retirement while admission is still closed; a later enrollment must publish after it.
        // The default is intentionally empty for hosts without identity notifications.
        onCustodyErased()
    }

    /// The host retains its existing DELETE authority/wire. This owner binds it to exactly the
    /// retained credentials and prevents a concurrent registration from being erased afterward.
    public func deleteInstallation(using operation:@escaping @Sendable(PulsePassportCredentials)async throws->Void) async throws {
        try await closeAndDrain()
        defer {erasing=false}
        guard await mutationLease.begin() else {throw PulsePassportServiceFailure.invalidated}
        do {
            if let bytes=try await storage.load() {
                let retained=try JSONDecoder().decode(PulsePassportCredentials.self,from:bytes)
                guard retained.backendBaseURL==configuration.baseURL,retained.mode == .appAttest,
                      retained.appAttestEnvironment==configuration.appAttestEnvironment else {throw PulsePassportRegistrationFailure.credentials}
                try Task.checkCancellation()
                try await operation(retained)
                guard let current=try await storage.load(),try JSONDecoder().decode(PulsePassportCredentials.self,from:current)==retained else {throw PulsePassportServiceFailure.invalidated}
            }
            try await clearLocalCustody()
            onCustodyErased()
        } catch {await mutationLease.end();throw error}
        await mutationLease.end()
    }
    private func closeAndDrain() async throws {
        guard !erasing else {throw PulsePassportServiceFailure.invalidated}
        erasing=true;custodyGeneration=UUID()
        if let running=flight {
            running.task.cancel()
            _ = await running.task.result
            if flight?.id==running.id {flight=nil}
        }
    }
    private func clearLocalCustody() async throws {
        try await storage.delete()
        guard try await storage.load()==nil else {throw PulsePassportRegistrationFailure.credentials}
        try await eraseKeys()
        guard try await keys.load()==nil else {throw PulsePassportRegistrationFailure.credentials}
    }
    public func ensure() async throws -> PulsePassportCredentials {try await mutate(.ensure)}
    public func recoverUnknownInstallationBearer() async throws -> PulsePassportCredentials {try await mutate(.recover)}
    public func forceReregister() async throws -> PulsePassportCredentials {try await mutate(.deadKey)}
    public func recoverDeadKey(after error:Error,diagnostic:@escaping @Sendable(PulsePassportDiagnostic)->Void = {_ in}) async throws -> PulsePassportClient {
        guard PulsePassportService.isDeadAppAttestKeyError(error) else {throw error}
        guard let failed=error as? PulsePassportKeyFailure else {throw error}
        let expected=KeyIdentity(installationID:failed.installationID,keyID:failed.keyID)
        guard let current=try await currentKeyIdentity() else {throw PulsePassportServiceFailure.invalidated}
        guard current==expected else {return try await client(diagnostic:diagnostic)}
        _ = try await mutate(.deadKey,expected:expected)
        return try await client(diagnostic:diagnostic)
    }
    private func replaceDeadKey(expected:KeyIdentity?) async throws -> PulsePassportCredentials {
        try Task.checkCancellation()
        if let expected,try await currentKeyIdentity() != expected {return try await performEnsure()}
        try await storage.delete();guard try await storage.load() == nil else {throw PulsePassportRegistrationFailure.credentials}
        try await eraseKeys();guard try await keys.load() == nil else {throw PulsePassportRegistrationFailure.credentials}
        return try await performEnsure()
    }

    private func currentKeyIdentity() async throws -> KeyIdentity? {
        guard let bytes=try await keys.load() else {return nil}
        if let record=try? JSONDecoder().decode(RegisteredKeyEnrollmentRecord.self,from:bytes) {
            guard record.backendBaseURL==configuration.baseURL,record.environment==configuration.appAttestEnvironment else {throw PulsePassportRegistrationFailure.credentials}
            return .init(installationID:"pulse_"+record.clientInstallationID,keyID:record.keyID)
        }
        guard let data=try await storage.load(),let credentials=try? JSONDecoder().decode(PulsePassportCredentials.self,from:data),
              let key=credentials.appAttestKeyID,String(data:bytes,encoding:.utf8)==key else {throw PulsePassportRegistrationFailure.credentials}
        return .init(installationID:credentials.installationID,keyID:key)
    }

    public func client(diagnostic:@escaping @Sendable(PulsePassportDiagnostic)->Void = {_ in}) async throws -> PulsePassportClient {
        let generation=custodyGeneration
        try requireGeneration(generation)
        let credentials = try await ensure()
        try requireGeneration(generation)
        guard let key = credentials.appAttestKeyID else { throw PulsePassportRegistrationFailure.credentials }
        let sign=keys.assert
        return PulsePassportClient(baseURL: configuration.baseURL, deviceID: credentials.installationID,
            attestation: .init(installationToken: { try await self.token(for:credentials,generation:generation,recover:false) }, assert: { digest in
                _ = try await self.token(for:credentials,generation:generation,recover:false)
                let bytes:Data
                do {bytes = try await sign(key, digest)}
                catch {
                    if PulsePassportService.isDeadAppAttestKeyError(error) {
                        throw PulsePassportKeyFailure(installationID:credentials.installationID,keyID:key,underlyingError:error)
                    }
                    throw error
                }
                _ = try await self.token(for:credentials,generation:generation,recover:false)
                return .init(keyID: key, clientDataHash: digest.base64EncodedString(), assertionObject: bytes.base64EncodedString())
            }, recoverInstallationToken: { try await self.token(for:credentials,generation:generation,recover:true) }), transport: transport,diagnostic:diagnostic)
    }


    /// A client must never enroll while merely checking whether its captured identity still holds.
    private func retainedIdentity(for expected:PulsePassportCredentials,generation:UUID) async throws->PulsePassportCredentials {
        try requireGeneration(generation)
        guard let bytes=try await storage.load(),let current=try? JSONDecoder().decode(PulsePassportCredentials.self,from:bytes),
              current.installationID==expected.installationID,current.clientInstallationID==expected.clientInstallationID,
              current.appAttestKeyID==expected.appAttestKeyID,current.backendBaseURL==configuration.baseURL,
              current.appAttestEnvironment==configuration.appAttestEnvironment,current.mode == .appAttest,
              let keyBytes=try await keys.load(),let key=try? JSONDecoder().decode(RegisteredKeyEnrollmentRecord.self,from:keyBytes),
              key.keyID==current.appAttestKeyID,key.clientInstallationID==current.clientInstallationID,
              key.backendBaseURL==configuration.baseURL,key.environment==configuration.appAttestEnvironment,
              key.phase == .registered else {throw PulsePassportServiceFailure.invalidated}
        try requireGeneration(generation)
        return current
    }
    private func token(for expected:PulsePassportCredentials,generation:UUID,recover:Bool) async throws -> String {
        let current=try await retainedIdentity(for:expected,generation:generation)
        guard recover else {return current.token}
        _ = try await recoverUnknownInstallationBearer()
        return try await retainedIdentity(for:expected,generation:generation).token
    }

    private func performRecovery() async throws -> PulsePassportCredentials {
        let original = try await performEnsure()
        let lifecycle = PulseRegistrationLifecycle(configuration: configuration, keys: keys,
            send: { path, schema, bytes in try await self.post(path: path, schema: schema, body: bytes) })
        let candidate = try await lifecycle.candidate(original: original, app: app, device: device)
        guard candidate.installationID == original.installationID,
              candidate.clientInstallationID == original.clientInstallationID,
              candidate.appAttestKeyID == original.appAttestKeyID else { throw PulsePassportRegistrationFailure.credentials }
        guard let current=try await storage.load(),try JSONDecoder().decode(PulsePassportCredentials.self,from:current) == original else {throw PulsePassportRegistrationFailure.credentials}
        try await storage.save(JSONEncoder().encode(candidate))
        try await lifecycle.completed(candidate)
        return candidate
    }

    private func performEnsure() async throws -> PulsePassportCredentials {
        try Task.checkCancellation()
        if let bytes = try await storage.load() {
            let value = try JSONDecoder().decode(PulsePassportCredentials.self, from: bytes)
            guard value.backendBaseURL == configuration.baseURL, value.appAttestEnvironment == configuration.appAttestEnvironment,
                  value.mode == .appAttest, !value.token.isEmpty,
                  value.installationID == "pulse_" + value.clientInstallationID,
                  let key = value.appAttestKeyID, !key.isEmpty,
                  let keyBytes = try await keys.load() else {
                throw PulsePassportRegistrationFailure.credentials
            }
            let record:RegisteredKeyEnrollmentRecord
            if String(data:keyBytes,encoding:.utf8)==key {
                // Exact legacy key reference bound to retained installation; no key is generated.
                record = .init(version:1,keyID:key,backendBaseURL:configuration.baseURL,environment:value.appAttestEnvironment ?? "",clientInstallationID:value.clientInstallationID,phase:.registered)
                try await keys.save(JSONEncoder().encode(record))
            } else {record=try JSONDecoder().decode(RegisteredKeyEnrollmentRecord.self,from:keyBytes)}
            guard record.keyID==key,record.backendBaseURL==configuration.baseURL,
                record.environment==configuration.appAttestEnvironment,record.clientInstallationID==value.clientInstallationID,
                record.phase == .registered || record.phase == .prepared else {throw PulsePassportRegistrationFailure.credentials}
            if record.phase == .prepared {try await RegisteredKeyEnrollmentCustody(ports:keys).completed(record)}
            return value
        }
        let lifecycle = PulseRegistrationLifecycle(configuration: configuration, keys: keys,
            send: { path, schema, bytes in try await self.post(path: path, schema: schema, body: bytes) })
        let value:PulsePassportCredentials
        do {value = try await lifecycle.candidate(original:nil,app:app,device:device)}
        catch {
            if PulsePassportService.isDeadAppAttestKeyError(error),let failed=try await currentKeyIdentity() {
                throw PulsePassportKeyFailure(installationID:failed.installationID,keyID:failed.keyID,underlyingError:error)
            }
            throw error
        }
        try Task.checkCancellation()
        try await storage.save(JSONEncoder().encode(value))
        try await lifecycle.completed(value)
        return value
    }

    private func post(path: String, schema: String, body: Data) async throws -> Data {
        try Task.checkCancellation()
        let url = configuration.baseURL.appendingPathComponent(path)
        let reply = try await transport.post(to: url,
            headers: ["Content-Type": "application/json", "X-Pulse-Schema-Version": schema],
            body: body, maxResponseBytes: 65_536)
        try Task.checkCancellation()
        guard reply.body.count <= 65_536, reply.responseURL == url, reply.mimeType?.lowercased() == "application/json" else {
            throw PulsePassportRegistrationFailure.invalidResponse
        }
        guard (200..<300).contains(reply.statusCode) else {
            let unknown: Bool
            if reply.statusCode == 404, reply.body.count <= 4096,
               (try? CanonicalJSON.canonicalize(reply.body)) != nil,
               let root = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
               Set(root.keys) == ["error"], let error = root["error"] as? [String: Any],
               Set(error.keys).isSubset(of: ["code", "message", "details"]),
               error["code"] as? String == "not_found",
               let details = error["details"] as? [String: Any], Set(details.keys) == ["reason"],
               details["reason"] as? String == "installation_key_not_found" { unknown = true }
            else { unknown = false }
            throw PulseRegistrationHTTPFailure(status: reply.statusCode, unknownKey: unknown)
        }
        _ = try CanonicalJSON.canonicalize(reply.body)
        return reply.body
    }
}
