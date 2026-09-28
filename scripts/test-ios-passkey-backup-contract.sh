#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/fearless-iOS/fearless/Common/Model/PasskeyBackupContract.swift"

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "[ios-passkey-contract-test][error] Missing source file: $SOURCE_FILE" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

test_file="$tmp_dir/main.swift"
binary="$tmp_dir/passkey-contract-test"

cat > "$test_file" <<'SWIFT'
import CloudKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[ios-passkey-contract-test][error] \(message)\n".utf8))
    exit(1)
}

func expectThrow(_ label: String, _ block: () throws -> Void) {
    do {
        try block()
        fail("\(label) did not throw")
    } catch {
        return
    }
}

func expectAsyncThrow(_ label: String, _ block: () async throws -> Void) async {
    do {
        try await block()
        fail("\(label) did not throw")
    } catch {
        return
    }
}

func expectNoThrow(_ label: String, _ block: () throws -> Void) {
    do {
        try block()
    } catch {
        fail("\(label) unexpectedly threw: \(error)")
    }
}

func expectAsyncNoThrow(_ label: String, _ block: () async throws -> Void) async {
    do {
        try await block()
    } catch {
        fail("\(label) unexpectedly threw: \(error)")
    }
}

final class FakePasskeyBackupCloudKitDatabase: PasskeyBackupCloudKitDatabase {
    private(set) var savedRecordNames: [String] = []
    private(set) var deletedRecordNames: [String] = []
    var records: [String: CKRecord] = [:]

    func saveRecord(_ record: CKRecord) async throws {
        records[record.recordID.recordName] = record
        savedRecordNames.append(record.recordID.recordName)
    }

    func fetchRecord(recordID: CKRecord.ID) async throws -> CKRecord? {
        records[recordID.recordName]
    }

    func deleteRecord(recordID: CKRecord.ID) async throws {
        records.removeValue(forKey: recordID.recordName)
        deletedRecordNames.append(recordID.recordName)
    }
}

final class FakePasskeyBackupCloudKitAccountStatusProvider: PasskeyBackupCloudKitAccountStatusProvider {
    private(set) var calls = 0
    private var statuses: [CKAccountStatus]

    init(statuses: [CKAccountStatus] = [.available]) {
        self.statuses = statuses
    }

    func accountStatus() async throws -> CKAccountStatus {
        calls += 1
        guard !statuses.isEmpty else {
            return .available
        }

        return statuses.removeFirst()
    }
}

final class FakePasskeyBackupHTTPTransport: PasskeyBackupHTTPTransport {
    private(set) var requests: [PasskeyBackupHTTPRequest] = []
    private var responses: [PasskeyBackupHTTPResponse]

    init(responses: [PasskeyBackupHTTPResponse] = []) {
        self.responses = responses
    }

    func execute(_ request: PasskeyBackupHTTPRequest) async throws -> PasskeyBackupHTTPResponse {
        requests.append(request)

        guard !responses.isEmpty else {
            fail("unexpected HTTP request: \(request)")
        }

        return responses.removeFirst()
    }
}

final class FakePasskeyBackupAuthorizationProvider: PasskeyBackupAuthorizationProvider {
    private(set) var requests: [PasskeyBackupAuthorizationRequest] = []

    func authorizationToken(for request: PasskeyBackupAuthorizationRequest) async throws -> String {
        requests.append(request)
        return "test.authorization-token_123"
    }
}

final class FakePasskeyBackupChallengeService: PasskeyBackupChallengeService {
    var registrationChallengeResult: PasskeyBackupRegistrationChallenge?
    var registrationResult: PasskeyBackupChallengeResult?
    var assertionChallengeResult: PasskeyBackupAssertionChallenge?
    var assertionResult: PasskeyBackupChallengeResult?
    var credentialListResult: PasskeyBackupCredentialListResult?
    var revokeCredentialResult: PasskeyBackupCredentialRevokeResult?
    var revokeAllResult: PasskeyBackupCredentialRevokeResult?
    var revokeAllError: Error?

    private(set) var registrationWalletId: String?
    private(set) var registrationAccountName: String?
    private(set) var registrationDisplayName: String?
    private(set) var completedRegistrationId: String?
    private(set) var completedRegistrationCredential: String?
    private(set) var assertionStorageKey: String?
    private(set) var completedAssertionId: String?
    private(set) var completedAssertionCredential: String?
    private(set) var listedCredentialsStorageKey: String?
    private(set) var revokedCredentialStorageKey: String?
    private(set) var revokedCredentialId: String?
    private(set) var revokedAllStorageKey: String?

    func registrationChallenge(
        walletId: String,
        accountName: String,
        displayName: String
    ) async throws -> PasskeyBackupRegistrationChallenge {
        registrationWalletId = walletId
        registrationAccountName = accountName
        registrationDisplayName = displayName

        guard let registrationChallengeResult else {
            fail("missing fake registration challenge")
        }

        return registrationChallengeResult
    }

    func completeRegistration(
        registrationId: String,
        credentialResponseJSON: String
    ) async throws -> PasskeyBackupChallengeResult {
        completedRegistrationId = registrationId
        completedRegistrationCredential = credentialResponseJSON

        guard let registrationResult else {
            fail("missing fake registration result")
        }

        return registrationResult
    }

    func assertionChallenge(storageKey: String) async throws -> PasskeyBackupAssertionChallenge {
        assertionStorageKey = storageKey

        guard let assertionChallengeResult else {
            fail("missing fake assertion challenge")
        }

        return assertionChallengeResult
    }

    func completeAssertion(
        assertionId: String,
        credentialResponseJSON: String
    ) async throws -> PasskeyBackupChallengeResult {
        completedAssertionId = assertionId
        completedAssertionCredential = credentialResponseJSON

        guard let assertionResult else {
            fail("missing fake assertion result")
        }

        return assertionResult
    }

    func listCredentials(storageKey: String) async throws -> PasskeyBackupCredentialListResult {
        listedCredentialsStorageKey = storageKey
        if let credentialListResult {
            return credentialListResult
        }
        return try PasskeyBackupCredentialListResult(storageKey: storageKey, credentials: [])
    }

    func revokeCredential(
        storageKey: String,
        credentialId: String
    ) async throws -> PasskeyBackupCredentialRevokeResult {
        revokedCredentialStorageKey = storageKey
        revokedCredentialId = credentialId
        if let revokeCredentialResult {
            return revokeCredentialResult
        }
        return try PasskeyBackupCredentialRevokeResult(
            storageKey: storageKey,
            credentialId: credentialId,
            remainingCredentials: 0
        )
    }

    func revokeAllCredentials(storageKey: String) async throws -> PasskeyBackupCredentialRevokeResult {
        revokedAllStorageKey = storageKey
        if let revokeAllError {
            throw revokeAllError
        }
        if let revokeAllResult {
            return revokeAllResult
        }
        return try PasskeyBackupCredentialRevokeResult(
            storageKey: storageKey,
            credentialId: nil,
            remainingCredentials: 0
        )
    }
}

final class FakePasskeyBackupCloudStorage: PasskeyBackupCloudStorage {
    private(set) var savedRecords: [PasskeyBackupEncryptedRecord] = []
    private(set) var loadedStorageKeys: [String] = []
    private(set) var deletedStorageKeys: [String] = []
    var records: [String: PasskeyBackupEncryptedRecord] = [:]

    func savePasskeyBackup(_ record: PasskeyBackupEncryptedRecord) async throws {
        records[record.storageKey] = record
        savedRecords.append(record)
    }

    func loadPasskeyBackup(storageKey: String) async throws -> PasskeyBackupEncryptedRecord? {
        loadedStorageKeys.append(storageKey)
        return records[storageKey]
    }

    func deletePasskeyBackup(storageKey: String) async throws {
        deletedStorageKeys.append(storageKey)
        records.removeValue(forKey: storageKey)
    }
}

func jsonResponse(_ json: String, statusCode: Int = 200) -> PasskeyBackupHTTPResponse {
    PasskeyBackupHTTPResponse(statusCode: statusCode, body: Data(json.utf8))
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func canonicalEncryptedEnvelope() -> Data {
    let vector = "RlBCS0FFQUQBAQwQAAAAHQABAgMEBQYHCAkKCxJCbuS78BFnbl_ULhb12v1I5M7-G-ZXHqwrFsgsJiQcEPtBrkqPDXxWvxW4BQ"
    do {
        return try PasskeyBackupContract.decodeBase64URL(vector)
    } catch {
        fail("canonical FPBKAEAD v1 fixture did not decode: \(error)")
    }
}

struct SharedVectorRecoverablePasskeyBackupKeyProvider: RecoverablePasskeyBackupKeyProvider {
    func backupKey(for _: PasskeyBackupEnvelopeMetadata) async throws -> Data {
        Data((1 ... 32).map { UInt8($0) })
    }
}

func jsonObject(from data: Data?) -> [String: Any] {
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("request body was not a JSON object")
    }

    return object
}

func encryptedRecord(
    storageKey: String = "wallet-1234",
    walletId: String = "wallet-001",
    accountName: String = "alice@example.com",
    createdAtMillis: Int64 = 1_767_225_600_000,
    encryptedPayload: Data = canonicalEncryptedEnvelope()
) throws -> PasskeyBackupEncryptedRecord {
    try PasskeyBackupEncryptedRecord(
        storageKey: storageKey,
        walletId: walletId,
        accountName: accountName,
        createdAtMillis: createdAtMillis,
        encryptedPayload: encryptedPayload
    )
}

func pendingRegistration(
    challenge: PasskeyBackupRegistrationChallenge,
    walletId: String = "wallet-001",
    accountName: String = "alice@example.com"
) throws -> PendingPasskeyBackupRegistration {
    try PendingPasskeyBackupRegistration(
        challenge: challenge,
        walletId: walletId,
        accountName: accountName
    )
}

func addValidCloudKitPasskeyMetadata(
    to record: CKRecord,
    storageKey: String,
    walletId: String = "wallet-001",
    accountName: String = "alice@example.com",
    createdAtMillis: Int64 = 1_767_225_600_000,
    schemaVersion: Int = PasskeyBackupContract.schemaVersion
) {
    record[CloudKitPasskeyBackupCloudStorage.storageKeyField] = storageKey as NSString
    record[CloudKitPasskeyBackupCloudStorage.walletIdField] = walletId as NSString
    record[CloudKitPasskeyBackupCloudStorage.accountNameField] = accountName as NSString
    record[CloudKitPasskeyBackupCloudStorage.createdAtMillisField] =
        NSNumber(value: createdAtMillis)
    record[CloudKitPasskeyBackupCloudStorage.schemaVersionField] = NSNumber(value: schemaVersion)
}

@main
enum PasskeyBackupContractTestRunner {
    static func main() async {
        expectNoThrow("registration credential serializer emits standard WebAuthn JSON") {
            let json = try PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data([0xfb, 0xff]),
                clientDataJSON: Data([0x00, 0x01]),
                attestationObject: Data([0x02, 0x03]),
                authenticatorData: Data([0x04, 0x05])
            )
            let credential = jsonObject(from: Data(json.utf8))
            guard let response = credential["response"] as? [String: Any],
                  let extensions = credential["clientExtensionResults"] as? [String: Any] else {
                fail("registration credential response was not an object: \(json)")
            }

            guard Set(credential.keys) == Set([
                "id", "rawId", "response", "type",
                "clientExtensionResults", "authenticatorAttachment"
            ]),
            credential["id"] as? String == "-_8",
            credential["rawId"] as? String == "-_8",
            credential["type"] as? String == "public-key",
            credential["authenticatorAttachment"] as? String == "platform",
            extensions.isEmpty,
            Set(response.keys) == Set([
                "clientDataJSON", "attestationObject", "authenticatorData"
            ]),
            response["clientDataJSON"] as? String == "AAE",
            response["attestationObject"] as? String == "AgM",
            response["authenticatorData"] as? String == "BAU" else {
                fail("unexpected registration credential JSON: \(json)")
            }
        }

        expectNoThrow("assertion credential serializer emits standard WebAuthn JSON") {
            let assertionUserHandle = Data((0 ..< 32).map { UInt8($0) })
            let json = try PasskeyCredentialResponseSerializer.assertionJSON(
                credentialID: Data([0x01]),
                clientDataJSON: Data([0x02]),
                authenticatorData: Data([0x03]),
                signature: Data([0x04]),
                userHandle: assertionUserHandle
            )
            let credential = jsonObject(from: Data(json.utf8))
            guard let response = credential["response"] as? [String: Any] else {
                fail("assertion credential response was not an object: \(json)")
            }

            guard Set(response.keys) == Set([
                "clientDataJSON", "authenticatorData", "signature", "userHandle"
            ]),
            response["clientDataJSON"] as? String == "Ag",
            response["authenticatorData"] as? String == "Aw",
            response["signature"] as? String == "BA",
            response["userHandle"] as? String == base64URL(assertionUserHandle) else {
                fail("unexpected assertion credential JSON: \(json)")
            }
        }

        expectThrow("registration serializer rejects empty credential id") {
            _ = try PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data(),
                clientDataJSON: Data([1]),
                attestationObject: Data([2])
            )
        }

        expectThrow("registration serializer rejects empty client data") {
            _ = try PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data([1]),
                clientDataJSON: Data(),
                attestationObject: Data([2])
            )
        }

        expectThrow("registration serializer rejects empty attestation") {
            _ = try PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data([1]),
                clientDataJSON: Data([2]),
                attestationObject: Data()
            )
        }

        expectThrow("registration serializer rejects present-but-empty authenticator data") {
            _ = try PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data([1]),
                clientDataJSON: Data([2]),
                attestationObject: Data([3]),
                authenticatorData: Data()
            )
        }

        expectThrow("assertion serializer rejects empty authenticator data") {
            _ = try PasskeyCredentialResponseSerializer.assertionJSON(
                credentialID: Data([1]),
                clientDataJSON: Data([2]),
                authenticatorData: Data(),
                signature: Data([3]),
                userHandle: Data(repeating: 4, count: 32)
            )
        }

        expectThrow("assertion serializer rejects empty signature") {
            _ = try PasskeyCredentialResponseSerializer.assertionJSON(
                credentialID: Data([1]),
                clientDataJSON: Data([2]),
                authenticatorData: Data([3]),
                signature: Data(),
                userHandle: Data(repeating: 4, count: 32)
            )
        }

        expectThrow("assertion serializer rejects present-but-empty user handle") {
            _ = try PasskeyCredentialResponseSerializer.assertionJSON(
                credentialID: Data([1]),
                clientDataJSON: Data([2]),
                authenticatorData: Data([3]),
                signature: Data([4]),
                userHandle: Data()
            )
        }

        expectThrow("serializer rejects oversized credential id") {
            _ = try PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data(repeating: 1, count: 385),
                clientDataJSON: Data([2]),
                attestationObject: Data([3])
            )
        }

        expectThrow("serializer rejects oversized client data") {
            _ = try PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data([1]),
                clientDataJSON: Data(repeating: 2, count: 6_145),
                attestationObject: Data([3])
            )
        }

        expectThrow("serializer rejects oversized attestation") {
            _ = try PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data([1]),
                clientDataJSON: Data([2]),
                attestationObject: Data(repeating: 3, count: 24_577)
            )
        }

        expectThrow("serializer rejects 31-byte user handle") {
            _ = try PasskeyCredentialResponseSerializer.assertionJSON(
                credentialID: Data([1]),
                clientDataJSON: Data([2]),
                authenticatorData: Data([3]),
                signature: Data([4]),
                userHandle: Data(repeating: 5, count: 31)
            )
        }

        expectThrow("serializer rejects 33-byte user handle") {
            _ = try PasskeyCredentialResponseSerializer.assertionJSON(
                credentialID: Data([1]),
                clientDataJSON: Data([2]),
                authenticatorData: Data([3]),
                signature: Data([4]),
                userHandle: Data(repeating: 5, count: 33)
            )
        }

        expectNoThrow("serializer accepts service field boundaries") {
            _ = try PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data(repeating: 1, count: 384),
                clientDataJSON: Data(repeating: 2, count: 6_144),
                attestationObject: Data(repeating: 3, count: 24_576),
                authenticatorData: Data(repeating: 4, count: 24_576)
            )
            _ = try PasskeyCredentialResponseSerializer.assertionJSON(
                credentialID: Data(repeating: 1, count: 384),
                clientDataJSON: Data(repeating: 2, count: 6_144),
                authenticatorData: Data(repeating: 3, count: 24_576),
                signature: Data(repeating: 4, count: 24_576),
                userHandle: Data(repeating: 5, count: 32)
            )
        }

        expectNoThrow("default relying party") {
            try PasskeyBackupContract.validateRelyingPartyId()
        }

        expectNoThrow("authorization request accepts exact ceremony paths") {
            let digest = base64URL(Data(repeating: 0, count: 32))
            let paths = [
                PasskeyBackupAuthorizationRequest.registrationChallengePath,
                PasskeyBackupAuthorizationRequest.registrationCompletePath,
                PasskeyBackupAuthorizationRequest.assertionChallengePath,
                PasskeyBackupAuthorizationRequest.assertionCompletePath
            ]
            for path in paths {
                _ = try PasskeyBackupAuthorizationRequest(
                    method: "POST",
                    path: path,
                    bodySha256: digest
                )
            }
        }

        let authorizationDigest = base64URL(Data(repeating: 0, count: 32))
        let invalidAuthorizationPaths = [
            "/api/passkey-backup/v1/registration/challenge/extra",
            "/api/passkey-backup/v1/registration/../assertion/challenge",
            "/api/passkey-backup/v1/%2e%2e/admin",
            "/api/passkey-backup/v1/admin",
            "/api/passkey-backup/v1/assertion/challenge?scope=admin",
            "//api/passkey-backup/v1/assertion/challenge",
            "https://backup.fearlesswallet.io/api/passkey-backup/v1/assertion/challenge",
            ""
        ]
        for path in invalidAuthorizationPaths {
            expectThrow("authorization request rejects non-ceremony path: \(path)") {
                _ = try PasskeyBackupAuthorizationRequest(
                    method: "POST",
                    path: path,
                    bodySha256: authorizationDigest
                )
            }
        }

        let invalidAuthorizationDigests = [
            String(authorizationDigest.dropLast()),
            authorizationDigest + "=",
            String(authorizationDigest.dropLast()) + "B",
            String(authorizationDigest.dropLast()) + "+",
            " " + authorizationDigest,
            ""
        ]
        for digest in invalidAuthorizationDigests {
            expectThrow("authorization request rejects noncanonical body digest") {
                _ = try PasskeyBackupAuthorizationRequest(
                    method: "POST",
                    path: PasskeyBackupAuthorizationRequest.assertionChallengePath,
                    bodySha256: digest
                )
            }
        }

        expectNoThrow("release challenge service URL") {
            guard PasskeyBackupReleaseConfig.challengeServiceBaseURL.absoluteString == "https://backup.fearlesswallet.io" else {
                fail("unexpected passkey challenge service URL")
            }
            guard PasskeyBackupReleaseConfig.challengeServiceBaseURL.scheme == "https" else {
                fail("passkey challenge service URL must be HTTPS")
            }
            guard PasskeyBackupReleaseConfig.isPasskeyBackupEnabled == false else {
                fail("passkey backup must be disabled by default")
            }
        }

        expectThrow("unsupported relying party") {
            try PasskeyBackupContract.validateRelyingPartyId("example.com")
        }

        expectThrow("short challenge") {
            try PasskeyBackupContract.validateChallenge(Data(repeating: 0, count: 15))
        }

        expectThrow("oversized challenge") {
            try PasskeyBackupContract.validateChallenge(Data(repeating: 0, count: 1025))
        }

        expectThrow("short user id") {
            try PasskeyBackupContract.validateUserId(Data(repeating: 0, count: 31))
        }

        expectThrow("oversized user id") {
            try PasskeyBackupContract.validateUserId(Data(repeating: 0, count: 33))
        }

        expectNoThrow("valid account name") {
            let normalized = try PasskeyBackupContract.validateAccountName(" user@example.com ")
            guard normalized == "user@example.com" else {
                fail("account name was not normalized")
            }
        }

        expectThrow("blank account name") {
            _ = try PasskeyBackupContract.validateAccountName("   ")
        }

        expectThrow("account name with whitespace") {
            _ = try PasskeyBackupContract.validateAccountName("user example.com")
        }

        expectThrow("account name without email shape") {
            _ = try PasskeyBackupContract.validateAccountName("user")
        }

        expectThrow("mismatched account name") {
            _ = try PasskeyBackupContract.validateMatchingAccountName(
                expected: "alice@example.com",
                actual: "mallory@example.com"
            )
        }

        expectThrow("path traversal storage key") {
            _ = try PasskeyBackupContract.validateStorageKey("../wallet")
        }

        expectThrow("empty encrypted payload") {
            _ = try PasskeyBackupEncryptedRecord(
                storageKey: "wallet-1234",
                walletId: "wallet-001",
                accountName: "alice@example.com",
                createdAtMillis: 1_767_225_600_000,
                encryptedPayload: Data()
            )
        }

        expectThrow("arbitrary nonempty encrypted payload is not a canonical v1 envelope") {
            _ = try PasskeyBackupEncryptedRecord(
                storageKey: "wallet-1234",
                walletId: "wallet-001",
                accountName: "alice@example.com",
                createdAtMillis: 1_767_225_600_000,
                encryptedPayload: Data([1, 2, 3])
            )
        }

        expectThrow("unsupported schema version") {
            _ = try PasskeyBackupEncryptedRecord(
                storageKey: "wallet-1234",
                walletId: "wallet-001",
                accountName: "alice@example.com",
                createdAtMillis: 1_767_225_600_000,
                encryptedPayload: canonicalEncryptedEnvelope(),
                schemaVersion: PasskeyBackupContract.schemaVersion + 1
            )
        }

        expectThrow("invalid encrypted record wallet id") {
            _ = try encryptedRecord(walletId: " ")
        }

        expectThrow("invalid encrypted record account name") {
            _ = try encryptedRecord(accountName: "alice example.com")
        }

        expectThrow("invalid encrypted record creation time") {
            _ = try encryptedRecord(createdAtMillis: 0)
        }

        expectNoThrow("valid encrypted record") {
            let record = try PasskeyBackupEncryptedRecord(
                storageKey: " wallet-1234 ",
                walletId: " wallet-001 ",
                accountName: " alice@example.com ",
                createdAtMillis: 1_767_225_600_000,
                encryptedPayload: canonicalEncryptedEnvelope()
            )
            guard record.storageKey == "wallet-1234",
                  record.walletId == "wallet-001",
                  record.accountName == "alice@example.com",
                  record.createdAtMillis == 1_767_225_600_000 else {
                fail("encrypted record metadata was not normalized")
            }
        }

        let database = FakePasskeyBackupCloudKitDatabase()
        let accountStatusProvider = FakePasskeyBackupCloudKitAccountStatusProvider()
        let storage = CloudKitPasskeyBackupCloudStorage(
            database: database,
            accountStatusProvider: accountStatusProvider
        )
        let record = try! encryptedRecord()

        await expectAsyncNoThrow("save and load CloudKit passkey backup") {
            try await storage.savePasskeyBackup(record)
            let loaded = try await storage.loadPasskeyBackup(storageKey: "wallet-1234")

            guard loaded == record else {
                fail("loaded record did not match saved record")
            }

            guard database.savedRecordNames == ["wallet-1234"] else {
                fail("unexpected saved record names: \(database.savedRecordNames)")
            }
        }

        await expectAsyncNoThrow("delete CloudKit passkey backup") {
            try await storage.deletePasskeyBackup(storageKey: "wallet-1234")
            let loaded = try await storage.loadPasskeyBackup(storageKey: "wallet-1234")

            guard loaded == nil else {
                fail("deleted backup was still loadable")
            }

            guard database.deletedRecordNames == ["wallet-1234"] else {
                fail("unexpected deleted record names: \(database.deletedRecordNames)")
            }
        }

        await expectAsyncThrow("CloudKit load rejects wrong record type") {
            database.records["wallet-5678"] = CKRecord(
                recordType: "WrongType",
                recordID: CKRecord.ID(recordName: "wallet-5678")
            )
            _ = try await storage.loadPasskeyBackup(storageKey: "wallet-5678")
        }

        await expectAsyncThrow("CloudKit load rejects missing encrypted payload") {
            let malformed = CKRecord(
                recordType: CloudKitPasskeyBackupCloudStorage.recordType,
                recordID: CKRecord.ID(recordName: "wallet-9012")
            )
            addValidCloudKitPasskeyMetadata(to: malformed, storageKey: "wallet-9012")
            database.records["wallet-9012"] = malformed
            _ = try await storage.loadPasskeyBackup(storageKey: "wallet-9012")
        }

        await expectAsyncThrow("CloudKit load rejects unsupported schema version") {
            let malformed = CKRecord(
                recordType: CloudKitPasskeyBackupCloudStorage.recordType,
                recordID: CKRecord.ID(recordName: "wallet-3456")
            )
            malformed[CloudKitPasskeyBackupCloudStorage.encryptedPayloadField] = Data([1]) as NSData
            addValidCloudKitPasskeyMetadata(
                to: malformed,
                storageKey: "wallet-3456",
                schemaVersion: PasskeyBackupContract.schemaVersion + 1
            )
            database.records["wallet-3456"] = malformed
            _ = try await storage.loadPasskeyBackup(storageKey: "wallet-3456")
        }

        await expectAsyncThrow("CloudKit load rejects missing storage metadata") {
            let malformed = CKRecord(
                recordType: CloudKitPasskeyBackupCloudStorage.recordType,
                recordID: CKRecord.ID(recordName: "wallet-2222")
            )
            malformed[CloudKitPasskeyBackupCloudStorage.encryptedPayloadField] = Data([1]) as NSData
            database.records["wallet-2222"] = malformed
            _ = try await storage.loadPasskeyBackup(storageKey: "wallet-2222")
        }

        await expectAsyncThrow("CloudKit load rejects mismatched storage metadata") {
            let malformed = CKRecord(
                recordType: CloudKitPasskeyBackupCloudStorage.recordType,
                recordID: CKRecord.ID(recordName: "wallet-3333")
            )
            malformed[CloudKitPasskeyBackupCloudStorage.encryptedPayloadField] = Data([1]) as NSData
            addValidCloudKitPasskeyMetadata(to: malformed, storageKey: "wallet-4444")
            database.records["wallet-3333"] = malformed
            _ = try await storage.loadPasskeyBackup(storageKey: "wallet-3333")
        }

        await expectAsyncThrow("CloudKit load rejects invalid account metadata") {
            let malformed = CKRecord(
                recordType: CloudKitPasskeyBackupCloudStorage.recordType,
                recordID: CKRecord.ID(recordName: "wallet-5555")
            )
            malformed[CloudKitPasskeyBackupCloudStorage.encryptedPayloadField] = Data([1]) as NSData
            addValidCloudKitPasskeyMetadata(
                to: malformed,
                storageKey: "wallet-5555",
                accountName: "alice example.com"
            )
            database.records["wallet-5555"] = malformed
            _ = try await storage.loadPasskeyBackup(storageKey: "wallet-5555")
        }

        await expectAsyncThrow("CloudKit load rejects invalid creation timestamp metadata") {
            let malformed = CKRecord(
                recordType: CloudKitPasskeyBackupCloudStorage.recordType,
                recordID: CKRecord.ID(recordName: "wallet-6666")
            )
            malformed[CloudKitPasskeyBackupCloudStorage.encryptedPayloadField] = Data([1]) as NSData
            addValidCloudKitPasskeyMetadata(
                to: malformed,
                storageKey: "wallet-6666",
                createdAtMillis: 0
            )
            database.records["wallet-6666"] = malformed
            _ = try await storage.loadPasskeyBackup(storageKey: "wallet-6666")
        }

        await expectAsyncThrow("CloudKit load rejects invalid storage keys before fetch") {
            _ = try await storage.loadPasskeyBackup(storageKey: "../wallet")
        }

        guard accountStatusProvider.calls == 11 else {
            fail("unexpected CloudKit account status call count: \(accountStatusProvider.calls)")
        }

        let unavailableDatabase = FakePasskeyBackupCloudKitDatabase()
        let unavailableStatusProvider = FakePasskeyBackupCloudKitAccountStatusProvider(statuses: [
            .noAccount,
            .restricted,
            .couldNotDetermine
        ])
        let unavailableStorage = CloudKitPasskeyBackupCloudStorage(
            database: unavailableDatabase,
            accountStatusProvider: unavailableStatusProvider
        )

        await expectAsyncThrow("CloudKit save rejects unavailable account before write") {
            try await unavailableStorage.savePasskeyBackup(record)
        }

        await expectAsyncThrow("CloudKit load rejects unavailable account before fetch") {
            _ = try await unavailableStorage.loadPasskeyBackup(storageKey: "wallet-1234")
        }

        await expectAsyncThrow("CloudKit delete rejects unavailable account before delete") {
            try await unavailableStorage.deletePasskeyBackup(storageKey: "wallet-1234")
        }

        guard unavailableDatabase.savedRecordNames.isEmpty,
              unavailableDatabase.deletedRecordNames.isEmpty,
              unavailableDatabase.records.isEmpty else {
            fail("unavailable CloudKit account touched the database")
        }

        let invalidKeyStatusProvider = FakePasskeyBackupCloudKitAccountStatusProvider(statuses: [.noAccount])
        let invalidKeyStorage = CloudKitPasskeyBackupCloudStorage(
            database: FakePasskeyBackupCloudKitDatabase(),
            accountStatusProvider: invalidKeyStatusProvider
        )

        await expectAsyncThrow("CloudKit invalid storage key rejects before account status") {
            _ = try await invalidKeyStorage.loadPasskeyBackup(storageKey: "../wallet")
        }

        guard invalidKeyStatusProvider.calls == 0 else {
            fail("invalid storage key should not query CloudKit account status")
        }

        let authorizationProvider = FakePasskeyBackupAuthorizationProvider()

        expectThrow("challenge service rejects non HTTPS base URL") {
            _ = try HTTPPasskeyBackupChallengeService(
                baseURL: "http://backup.fearlesswallet.io",
                transport: FakePasskeyBackupHTTPTransport(),
                authorizationProvider: authorizationProvider
            )
        }

        expectThrow("challenge service rejects query base URL") {
            _ = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io?env=dev",
                transport: FakePasskeyBackupHTTPTransport(),
                authorizationProvider: authorizationProvider
            )
        }

        for baseURL in [
            " https://backup.fearlesswallet.io",
            "https://backup.fearlesswallet.io ",
            "https://backup.fearlesswallet.io:443",
            "https://backup.fearlesswallet.io/api",
            "https://backup.fearlesswallet.io//",
            "https://BACKUP.fearlesswallet.io"
        ] {
            expectThrow("challenge service rejects noncanonical base URL: \(baseURL)") {
                _ = try HTTPPasskeyBackupChallengeService(
                    baseURL: baseURL,
                    transport: FakePasskeyBackupHTTPTransport(),
                    authorizationProvider: authorizationProvider
                )
            }
        }

        let registrationChallenge = Data((0 ..< 32).map { UInt8($0) })
        let registrationUserId = Data((32 ..< 64).map { UInt8($0) })
        let registrationTransport = FakePasskeyBackupHTTPTransport(
            responses: [
                jsonResponse(
                    """
                    {
                      "registrationId": "registration-1234",
                      "challenge": "\(base64URL(registrationChallenge))",
                      "userId": "\(base64URL(registrationUserId))",
                      "userName": "alice@example.com",
                      "displayName": "Alice",
                      "storageKey": "wallet-1234",
                      "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                      "schemaVersion": \(PasskeyBackupContract.schemaVersion)
                    }
                    """
                )
            ]
        )
        let registrationService = try! HTTPPasskeyBackupChallengeService(
            baseURL: "https://backup.fearlesswallet.io/",
            transport: registrationTransport,
            authorizationProvider: authorizationProvider
        )

        await expectAsyncNoThrow("registration challenge posts wallet metadata") {
            let result = try await registrationService.registrationChallenge(
                walletId: " wallet-001 ",
                accountName: " alice@example.com ",
                displayName: " Alice "
            )

            guard result.registrationId == "registration-1234",
                  result.challenge == registrationChallenge,
                  result.userId == registrationUserId,
                  result.userName == "alice@example.com",
                  result.displayName == "Alice",
                  result.storageKey == "wallet-1234" else {
                fail("unexpected registration challenge result: \(result)")
            }

            guard registrationTransport.requests.count == 1 else {
                fail("unexpected registration request count: \(registrationTransport.requests.count)")
            }

            let request = registrationTransport.requests[0]
            guard request.method == "POST",
                  request.url.absoluteString ==
                    "https://backup.fearlesswallet.io/api/passkey-backup/v1/registration/challenge",
                  request.headers["Content-Type"] == "application/json; charset=utf-8" else {
                fail("unexpected registration request: \(request)")
            }

            let body = jsonObject(from: request.body)
            guard body["walletId"] as? String == "wallet-001",
                  body["accountName"] as? String == "alice@example.com",
                  body["displayName"] as? String == "Alice",
                  body["rpId"] as? String == PasskeyBackupContract.PASSKEY_RP_ID,
                  (body["schemaVersion"] as? NSNumber)?.intValue == PasskeyBackupContract.schemaVersion else {
                fail("unexpected registration request body: \(body)")
            }
        }

        let completeRegistrationTransport = FakePasskeyBackupHTTPTransport(
            responses: [
                jsonResponse(
                    """
                    {
                      "storageKey": "wallet-1234",
                      "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                      "schemaVersion": \(PasskeyBackupContract.schemaVersion)
                    }
                    """
                )
            ]
        )
        let completeRegistrationService = try! HTTPPasskeyBackupChallengeService(
            baseURL: "https://backup.fearlesswallet.io",
            transport: completeRegistrationTransport,
            authorizationProvider: authorizationProvider
        )

        await expectAsyncNoThrow("complete registration posts credential object") {
            let result = try await completeRegistrationService.completeRegistration(
                registrationId: " registration-1234 ",
                credentialResponseJSON: #"{"id":"Y3JlZC0x","response":{"clientDataJSON":"abc"}}"#
            )

            guard result.storageKey == "wallet-1234" else {
                fail("unexpected complete registration result: \(result)")
            }

            let request = completeRegistrationTransport.requests[0]
            guard request.url.absoluteString ==
                "https://backup.fearlesswallet.io/api/passkey-backup/v1/registration/complete" else {
                fail("unexpected complete registration URL: \(request.url)")
            }

            let body = jsonObject(from: request.body)
            let credential = body["credential"] as? [String: Any]
            guard body["registrationId"] as? String == "registration-1234",
                  credential?["id"] as? String == "Y3JlZC0x" else {
                fail("unexpected complete registration body: \(body)")
            }
        }

        let assertionChallenge = Data((64 ..< 96).map { UInt8($0) })
        let assertionTransport = FakePasskeyBackupHTTPTransport(
            responses: [
                jsonResponse(
                    """
                    {
                      "assertionId": "assertion-1234",
                      "challenge": "\(base64URL(assertionChallenge))",
                      "storageKey": "wallet-1234",
                      "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                      "schemaVersion": \(PasskeyBackupContract.schemaVersion)
                    }
                    """
                )
            ]
        )
        let assertionService = try! HTTPPasskeyBackupChallengeService(
            baseURL: "https://backup.fearlesswallet.io",
            transport: assertionTransport,
            authorizationProvider: authorizationProvider
        )

        await expectAsyncNoThrow("assertion challenge posts storage key") {
            let result = try await assertionService.assertionChallenge(storageKey: " wallet-1234 ")

            guard result.assertionId == "assertion-1234",
                  result.challenge == assertionChallenge,
                  result.storageKey == "wallet-1234" else {
                fail("unexpected assertion challenge result: \(result)")
            }

            let request = assertionTransport.requests[0]
            guard request.url.absoluteString ==
                "https://backup.fearlesswallet.io/api/passkey-backup/v1/assertion/challenge" else {
                fail("unexpected assertion challenge URL: \(request.url)")
            }

            let body = jsonObject(from: request.body)
            guard body["storageKey"] as? String == "wallet-1234",
                  body["rpId"] as? String == PasskeyBackupContract.PASSKEY_RP_ID,
                  (body["schemaVersion"] as? NSNumber)?.intValue == PasskeyBackupContract.schemaVersion else {
                fail("unexpected assertion request body: \(body)")
            }
        }

        let completeAssertionTransport = FakePasskeyBackupHTTPTransport(
            responses: [
                jsonResponse(
                    """
                    {
                      "storageKey": "wallet-1234",
                      "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                      "schemaVersion": \(PasskeyBackupContract.schemaVersion)
                    }
                    """
                )
            ]
        )
        let completeAssertionService = try! HTTPPasskeyBackupChallengeService(
            baseURL: "https://backup.fearlesswallet.io",
            transport: completeAssertionTransport,
            authorizationProvider: authorizationProvider
        )

        await expectAsyncNoThrow("complete assertion posts credential object") {
            let result = try await completeAssertionService.completeAssertion(
                assertionId: " assertion-1234 ",
                credentialResponseJSON: #"{"id":"Y3JlZC0x","response":{"authenticatorData":"abc"}}"#
            )

            guard result.storageKey == "wallet-1234" else {
                fail("unexpected complete assertion result: \(result)")
            }

            let request = completeAssertionTransport.requests[0]
            guard request.url.absoluteString ==
                "https://backup.fearlesswallet.io/api/passkey-backup/v1/assertion/complete" else {
                fail("unexpected complete assertion URL: \(request.url)")
            }

            let body = jsonObject(from: request.body)
            let credential = body["credential"] as? [String: Any]
            guard body["assertionId"] as? String == "assertion-1234",
                  credential?["id"] as? String == "Y3JlZC0x" else {
                fail("unexpected complete assertion body: \(body)")
            }
        }

        await expectAsyncThrow("registration challenge rejects wrong relying party") {
            let transport = FakePasskeyBackupHTTPTransport(
                responses: [
                    jsonResponse(
                        """
                        {
                          "registrationId": "registration-1234",
                          "challenge": "\(base64URL(registrationChallenge))",
                          "userId": "\(base64URL(registrationUserId))",
                          "userName": "alice@example.com",
                          "displayName": "Alice",
                          "storageKey": "wallet-1234",
                          "rpId": "example.com",
                          "schemaVersion": \(PasskeyBackupContract.schemaVersion)
                        }
                        """
                    )
                ]
            )
            let service = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io",
                transport: transport,
                authorizationProvider: authorizationProvider
            )
            _ = try await service.registrationChallenge(walletId: "wallet-001", accountName: "alice@example.com", displayName: "Alice")
        }

        await expectAsyncThrow("registration challenge rejects unsupported schema") {
            let transport = FakePasskeyBackupHTTPTransport(
                responses: [
                    jsonResponse(
                        """
                        {
                          "registrationId": "registration-1234",
                          "challenge": "\(base64URL(registrationChallenge))",
                          "userId": "\(base64URL(registrationUserId))",
                          "userName": "alice@example.com",
                          "displayName": "Alice",
                          "storageKey": "wallet-1234",
                          "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                          "schemaVersion": \(PasskeyBackupContract.schemaVersion + 1)
                        }
                        """
                    )
                ]
            )
            let service = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io",
                transport: transport,
                authorizationProvider: authorizationProvider
            )
            _ = try await service.registrationChallenge(walletId: "wallet-001", accountName: "alice@example.com", displayName: "Alice")
        }

        await expectAsyncThrow("registration challenge rejects invalid base64url") {
            let transport = FakePasskeyBackupHTTPTransport(
                responses: [
                    jsonResponse(
                        """
                        {
                          "registrationId": "registration-1234",
                          "challenge": "not base64url",
                          "userId": "\(base64URL(registrationUserId))",
                          "userName": "alice@example.com",
                          "displayName": "Alice",
                          "storageKey": "wallet-1234",
                          "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                          "schemaVersion": \(PasskeyBackupContract.schemaVersion)
                        }
                        """
                    )
                ]
            )
            let service = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io",
                transport: transport,
                authorizationProvider: authorizationProvider
            )
            _ = try await service.registrationChallenge(walletId: "wallet-001", accountName: "alice@example.com", displayName: "Alice")
        }

        await expectAsyncThrow("registration challenge rejects short user id") {
            let transport = FakePasskeyBackupHTTPTransport(
                responses: [
                    jsonResponse(
                        """
                        {
                          "registrationId": "registration-1234",
                          "challenge": "\(base64URL(registrationChallenge))",
                          "userId": "\(base64URL(Data((0 ..< 15).map { UInt8($0) })))",
                          "userName": "alice@example.com",
                          "displayName": "Alice",
                          "storageKey": "wallet-1234",
                          "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                          "schemaVersion": \(PasskeyBackupContract.schemaVersion)
                        }
                        """
                    )
                ]
            )
            let service = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io",
                transport: transport,
                authorizationProvider: authorizationProvider
            )
            _ = try await service.registrationChallenge(walletId: "wallet-001", accountName: "alice@example.com", displayName: "Alice")
        }

        await expectAsyncThrow("assertion challenge rejects mismatched storage key") {
            let transport = FakePasskeyBackupHTTPTransport(
                responses: [
                    jsonResponse(
                        """
                        {
                          "assertionId": "assertion-1234",
                          "challenge": "\(base64URL(assertionChallenge))",
                          "storageKey": "wallet-5678",
                          "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                          "schemaVersion": \(PasskeyBackupContract.schemaVersion)
                        }
                        """
                    )
                ]
            )
            let service = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io",
                transport: transport,
                authorizationProvider: authorizationProvider
            )
            _ = try await service.assertionChallenge(storageKey: "wallet-1234")
        }

        await expectAsyncThrow("challenge service rejects malformed JSON responses") {
            let transport = FakePasskeyBackupHTTPTransport(
                responses: [PasskeyBackupHTTPResponse(statusCode: 200, body: Data(#"{"not":"#.utf8))]
            )
            let service = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io",
                transport: transport,
                authorizationProvider: authorizationProvider
            )
            _ = try await service.assertionChallenge(storageKey: "wallet-1234")
        }

        await expectAsyncThrow("challenge service rejects empty responses") {
            let transport = FakePasskeyBackupHTTPTransport(
                responses: [PasskeyBackupHTTPResponse(statusCode: 200, body: Data())]
            )
            let service = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io",
                transport: transport,
                authorizationProvider: authorizationProvider
            )
            _ = try await service.assertionChallenge(storageKey: "wallet-1234")
        }

        await expectAsyncThrow("challenge service fails closed on HTTP errors") {
            let transport = FakePasskeyBackupHTTPTransport(
                responses: [PasskeyBackupHTTPResponse(statusCode: 503, body: Data())]
            )
            let service = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io",
                transport: transport,
                authorizationProvider: authorizationProvider
            )
            _ = try await service.assertionChallenge(storageKey: "wallet-1234")
        }

        for statusCode in [201, 204] {
            await expectAsyncThrow("challenge service rejects HTTP \(statusCode)") {
                let transport = FakePasskeyBackupHTTPTransport(
                    responses: [
                        jsonResponse(
                            """
                            {
                              "assertionId": "assertion-1234",
                              "challenge": "\(base64URL(assertionChallenge))",
                              "storageKey": "wallet-1234",
                              "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                              "schemaVersion": \(PasskeyBackupContract.schemaVersion)
                            }
                            """,
                            statusCode: statusCode
                        )
                    ]
                )
                let service = try HTTPPasskeyBackupChallengeService(
                    baseURL: "https://backup.fearlesswallet.io",
                    transport: transport,
                    authorizationProvider: authorizationProvider
                )
                _ = try await service.assertionChallenge(storageKey: "wallet-1234")
            }
        }

        await expectAsyncThrow("challenge service rejects unknown response fields") {
            let transport = FakePasskeyBackupHTTPTransport(
                responses: [
                    jsonResponse(
                        """
                        {
                          "assertionId": "assertion-1234",
                          "challenge": "\(base64URL(assertionChallenge))",
                          "storageKey": "wallet-1234",
                          "rpId": "\(PasskeyBackupContract.PASSKEY_RP_ID)",
                          "schemaVersion": \(PasskeyBackupContract.schemaVersion),
                          "unexpected": true
                        }
                        """
                    )
                ]
            )
            let service = try HTTPPasskeyBackupChallengeService(
                baseURL: "https://backup.fearlesswallet.io",
                transport: transport,
                authorizationProvider: authorizationProvider
            )
            _ = try await service.assertionChallenge(storageKey: "wallet-1234")
        }

        let localValidationTransport = FakePasskeyBackupHTTPTransport()
        let localValidationService = try! HTTPPasskeyBackupChallengeService(
            baseURL: "https://backup.fearlesswallet.io",
            transport: localValidationTransport,
            authorizationProvider: authorizationProvider
        )

        await expectAsyncThrow("challenge service rejects invalid ceremony ids before network") {
            _ = try await localValidationService.completeAssertion(
                assertionId: "../assertion",
                credentialResponseJSON: #"{"id":"Y3JlZC0x"}"#
            )
        }

        await expectAsyncThrow("challenge service rejects credential arrays before network") {
            _ = try await localValidationService.completeRegistration(
                registrationId: "registration-1234",
                credentialResponseJSON: #"["not-an-object"]"#
            )
        }

        await expectAsyncThrow("challenge service rejects invalid account names before network") {
            _ = try await localValidationService.registrationChallenge(
                walletId: "wallet-001",
                accountName: "alice example.com",
                displayName: "Alice"
            )
        }

        await expectAsyncThrow("assertion challenge rejects invalid storage keys before network") {
            _ = try await localValidationService.assertionChallenge(storageKey: "../wallet")
        }

        guard localValidationTransport.requests.isEmpty else {
            fail("invalid local challenge inputs reached network: \(localValidationTransport.requests)")
        }

        let workflowRegistrationChallenge = try! PasskeyBackupRegistrationChallenge(
            registrationId: "registration-1234",
            challenge: registrationChallenge,
            userId: registrationUserId,
            userName: "alice@example.com",
            displayName: "Alice",
            storageKey: "wallet-1234"
        )
        let workflowAssertionChallenge = try! PasskeyBackupAssertionChallenge(
            assertionId: "assertion-1234",
            challenge: assertionChallenge,
            storageKey: "wallet-1234"
        )

        await expectAsyncThrow("workflow fails closed while passkey backup is disabled") {
            let service = FakePasskeyBackupChallengeService()
            service.registrationChallengeResult = workflowRegistrationChallenge
            service.registrationResult = try PasskeyBackupChallengeResult(storageKey: "wallet-1234")
            service.assertionChallengeResult = workflowAssertionChallenge
            service.assertionResult = try PasskeyBackupChallengeResult(storageKey: "wallet-1234")
            let storage = FakePasskeyBackupCloudStorage()
            storage.records["wallet-1234"] = try encryptedRecord()
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: storage
            )

            _ = try await workflow.beginRegistration(
                walletId: "wallet-001",
                accountName: "alice@example.com",
                displayName: "Alice"
            )
        }

        await expectAsyncNoThrow("disabled workflow does not call challenge service or storage") {
            let service = FakePasskeyBackupChallengeService()
            service.registrationChallengeResult = workflowRegistrationChallenge
            service.registrationResult = try PasskeyBackupChallengeResult(storageKey: "wallet-1234")
            service.assertionChallengeResult = workflowAssertionChallenge
            service.assertionResult = try PasskeyBackupChallengeResult(storageKey: "wallet-1234")
            let storage = FakePasskeyBackupCloudStorage()
            storage.records["wallet-1234"] = try encryptedRecord()
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: storage
            )

            await expectAsyncThrow("disabled finish registration") {
                _ = try await workflow.finishRegistration(
                    pending: try pendingRegistration(challenge: workflowRegistrationChallenge),
                    credentialResponseJSON: #"{"id":"Y3JlZC0x"}"#,
                    encryptedPayload: Data([1])
                )
            }
            await expectAsyncThrow("disabled begin restore") {
                _ = try await workflow.beginRestore(storageKey: "wallet-1234")
            }
            await expectAsyncThrow("disabled finish restore") {
                _ = try await workflow.finishRestore(
                    pending: PendingPasskeyBackupAssertion(challenge: workflowAssertionChallenge),
                    credentialResponseJSON: #"{"id":"Y3JlZC0x"}"#
                )
            }
            await expectAsyncThrow("disabled delete") {
                try await workflow.deleteBackup(storageKey: "wallet-1234")
            }

            guard service.registrationWalletId == nil,
                  service.completedRegistrationId == nil,
                  service.assertionStorageKey == nil,
                  service.completedAssertionId == nil,
                  service.listedCredentialsStorageKey == nil,
                  service.revokedCredentialStorageKey == nil,
                  service.revokedAllStorageKey == nil,
                  storage.savedRecords.isEmpty,
                  storage.loadedStorageKeys.isEmpty,
                  storage.deletedStorageKeys.isEmpty else {
                fail("disabled workflow reached challenge service or storage")
            }
        }

        await expectAsyncNoThrow("workflow begins registration from challenge service") {
            let service = FakePasskeyBackupChallengeService()
            service.registrationChallengeResult = workflowRegistrationChallenge
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: FakePasskeyBackupCloudStorage(),
                isReleaseEnabled: true
            )

            let pending = try await workflow.beginRegistration(
                walletId: " wallet-001 ",
                accountName: " alice@example.com ",
                displayName: " Alice "
            )

            guard pending.registrationId == "registration-1234",
                  pending.storageKey == "wallet-1234",
                  pending.challenge == registrationChallenge,
                  pending.userId == registrationUserId,
                  pending.userName == "alice@example.com",
                  pending.displayName == "Alice" else {
                fail("unexpected workflow registration pending state: \(pending)")
            }

            guard service.registrationWalletId == "wallet-001",
                  service.registrationAccountName == "alice@example.com",
                  service.registrationDisplayName == " Alice " else {
                fail("workflow did not pass registration metadata to challenge service")
            }
        }

        let invalidSelectedAccountService = FakePasskeyBackupChallengeService()
        invalidSelectedAccountService.registrationChallengeResult = workflowRegistrationChallenge
        let invalidSelectedAccountWorkflow = try! PasskeyBackupWorkflow(
            challengeService: invalidSelectedAccountService,
            cloudStorage: FakePasskeyBackupCloudStorage(),
            isReleaseEnabled: true
        )

        await expectAsyncThrow("workflow rejects invalid selected account before challenge service") {
            _ = try await invalidSelectedAccountWorkflow.beginRegistration(
                walletId: "wallet-001",
                accountName: "alice example.com",
                displayName: "Alice"
            )
        }

        guard invalidSelectedAccountService.registrationWalletId == nil else {
            fail("invalid account reached challenge service")
        }

        let mismatchedAccountService = FakePasskeyBackupChallengeService()
        mismatchedAccountService.registrationChallengeResult = try! PasskeyBackupRegistrationChallenge(
            registrationId: "registration-1234",
            challenge: registrationChallenge,
            userId: registrationUserId,
            userName: "mallory@example.com",
            displayName: "Mallory",
            storageKey: "wallet-1234"
        )
        let mismatchedAccountStorage = FakePasskeyBackupCloudStorage()
        let mismatchedAccountWorkflow = try! PasskeyBackupWorkflow(
            challengeService: mismatchedAccountService,
            cloudStorage: mismatchedAccountStorage,
            isReleaseEnabled: true
        )

        await expectAsyncThrow("workflow rejects mismatched registration account before backup") {
            _ = try await mismatchedAccountWorkflow.beginRegistration(
                walletId: "wallet-001",
                accountName: "alice@example.com",
                displayName: "Alice"
            )
        }

        guard mismatchedAccountService.registrationAccountName == "alice@example.com",
              mismatchedAccountStorage.savedRecords.isEmpty else {
            fail("mismatched account produced side effects")
        }

        await expectAsyncNoThrow("legacy raw registration requires explicit authenticated metadata") {
            let service = FakePasskeyBackupChallengeService()
            service.registrationResult = try PasskeyBackupChallengeResult(storageKey: "wallet-1234")
            let storage = FakePasskeyBackupCloudStorage()
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: storage,
                isReleaseEnabled: true
            )

            await expectAsyncThrow("legacy raw registration fails before ceremony") {
                _ = try await workflow.finishRegistration(
                    pending: try pendingRegistration(challenge: workflowRegistrationChallenge),
                    credentialResponseJSON: #"{"id":"Y3JlZC0x"}"#,
                    encryptedPayload: canonicalEncryptedEnvelope()
                )
            }

            guard service.completedRegistrationId == nil,
                  storage.savedRecords.isEmpty else {
                fail("legacy raw registration reached ceremony or cloud storage")
            }
        }

        await expectAsyncNoThrow("workflow finishes registration and saves authenticated encrypted record") {
            let service = FakePasskeyBackupChallengeService()
            service.registrationResult = try PasskeyBackupChallengeResult(storageKey: "wallet-1234")
            let storage = FakePasskeyBackupCloudStorage()
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: storage,
                backupKeyProvider: SharedVectorRecoverablePasskeyBackupKeyProvider(),
                isReleaseEnabled: true,
                createdAtMillisProvider: { 1_767_225_600_000 }
            )
            let encryptedPayload = canonicalEncryptedEnvelope()
            let record = try encryptedRecord(encryptedPayload: encryptedPayload)

            let saved = try await workflow.finishRegistrationWithEncryptedRecord(
                pending: try pendingRegistration(challenge: workflowRegistrationChallenge),
                credentialResponseJSON: #"{"id":"Y3JlZC0x"}"#,
                record: record
            )

            guard service.completedRegistrationId == "registration-1234",
                  service.completedRegistrationCredential == #"{"id":"Y3JlZC0x"}"#,
                  saved.storageKey == "wallet-1234",
                  saved.walletId == "wallet-001",
                  saved.accountName == "alice@example.com",
                  saved.createdAtMillis == 1_767_225_600_000,
                  saved.encryptedPayload == encryptedPayload,
                  storage.savedRecords == [saved] else {
                fail("workflow did not save completed registration backup")
            }
        }

        let mismatchedRegistrationStorage = FakePasskeyBackupCloudStorage()
        await expectAsyncThrow("workflow rejects mismatched registration storage key") {
            let service = FakePasskeyBackupChallengeService()
            service.registrationResult = try PasskeyBackupChallengeResult(storageKey: "wallet-5678")
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: mismatchedRegistrationStorage,
                backupKeyProvider: SharedVectorRecoverablePasskeyBackupKeyProvider(),
                isReleaseEnabled: true
            )
            _ = try await workflow.finishRegistrationWithEncryptedRecord(
                pending: try pendingRegistration(challenge: workflowRegistrationChallenge),
                credentialResponseJSON: #"{"id":"Y3JlZC0x"}"#,
                record: try encryptedRecord()
            )
        }
        guard mismatchedRegistrationStorage.savedRecords.isEmpty else {
            fail("workflow saved registration backup after storage-key mismatch")
        }

        await expectAsyncNoThrow("workflow begins restore from assertion challenge") {
            let service = FakePasskeyBackupChallengeService()
            service.assertionChallengeResult = workflowAssertionChallenge
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: FakePasskeyBackupCloudStorage(),
                isReleaseEnabled: true
            )

            let pending = try await workflow.beginRestore(storageKey: " wallet-1234 ")

            guard service.assertionStorageKey == "wallet-1234",
                  pending.assertionId == "assertion-1234",
                  pending.storageKey == "wallet-1234",
                  pending.challenge == assertionChallenge else {
                fail("unexpected workflow assertion pending state: \(pending)")
            }
        }

        await expectAsyncNoThrow("workflow finishes restore and loads encrypted backup") {
            let encryptedPayload = canonicalEncryptedEnvelope()
            let restoredRecord = try encryptedRecord(encryptedPayload: encryptedPayload)
            let service = FakePasskeyBackupChallengeService()
            service.assertionResult = try PasskeyBackupChallengeResult(storageKey: "wallet-1234")
            let storage = FakePasskeyBackupCloudStorage()
            storage.records["wallet-1234"] = restoredRecord
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: storage,
                isReleaseEnabled: true
            )

            let restored = try await workflow.finishRestore(
                pending: PendingPasskeyBackupAssertion(challenge: workflowAssertionChallenge),
                credentialResponseJSON: #"{"id":"Y3JlZC0x"}"#
            )

            guard service.completedAssertionId == "assertion-1234",
                  service.completedAssertionCredential == #"{"id":"Y3JlZC0x"}"#,
                  storage.loadedStorageKeys == ["wallet-1234"],
                  restored == restoredRecord else {
                fail("workflow did not load completed assertion backup")
            }
        }

        let mismatchedAssertionStorage = FakePasskeyBackupCloudStorage()
        await expectAsyncThrow("workflow rejects mismatched restore storage key") {
            let service = FakePasskeyBackupChallengeService()
            service.assertionResult = try PasskeyBackupChallengeResult(storageKey: "wallet-5678")
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: mismatchedAssertionStorage,
                isReleaseEnabled: true
            )
            _ = try await workflow.finishRestore(
                pending: PendingPasskeyBackupAssertion(challenge: workflowAssertionChallenge),
                credentialResponseJSON: #"{"id":"Y3JlZC0x"}"#
            )
        }
        guard mismatchedAssertionStorage.loadedStorageKeys.isEmpty else {
            fail("workflow loaded cloud backup after restore storage-key mismatch")
        }

        await expectAsyncThrow("workflow fails closed when restored cloud backup is missing") {
            let service = FakePasskeyBackupChallengeService()
            service.assertionResult = try PasskeyBackupChallengeResult(storageKey: "wallet-1234")
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: FakePasskeyBackupCloudStorage(),
                isReleaseEnabled: true
            )
            _ = try await workflow.finishRestore(
                pending: PendingPasskeyBackupAssertion(challenge: workflowAssertionChallenge),
                credentialResponseJSON: #"{"id":"Y3JlZC0x"}"#
            )
        }

        await expectAsyncNoThrow("workflow forwards normalized credential list and revoke lifecycle operations") {
            let service = FakePasskeyBackupChallengeService()
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: FakePasskeyBackupCloudStorage(),
                isReleaseEnabled: true
            )
            let credentialId = "Y3JlZC0x"

            let listed = try await workflow.listCredentials(storageKey: " wallet-1234 ")
            let revoked = try await workflow.revokeCredential(
                storageKey: " wallet-1234 ",
                credentialId: credentialId
            )

            guard listed.storageKey == "wallet-1234",
                  listed.credentials.isEmpty,
                  revoked.storageKey == "wallet-1234",
                  revoked.credentialId == credentialId,
                  revoked.remainingCredentials == 0,
                  service.listedCredentialsStorageKey == "wallet-1234",
                  service.revokedCredentialStorageKey == "wallet-1234",
                  service.revokedCredentialId == credentialId else {
                fail("workflow lifecycle operations drifted from the normalized service contract")
            }
        }

        await expectAsyncNoThrow("workflow keeps cloud backup when server revoke-all fails") {
            let service = FakePasskeyBackupChallengeService()
            service.revokeAllError = PasskeyBackupError.unavailableAuthorization
            let storage = FakePasskeyBackupCloudStorage()
            storage.records["wallet-1234"] = try encryptedRecord()
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: storage,
                isReleaseEnabled: true
            )

            await expectAsyncThrow("server-first delete authorization failure") {
                try await workflow.deleteBackup(storageKey: "wallet-1234")
            }

            guard service.revokedAllStorageKey == "wallet-1234",
                  storage.deletedStorageKeys.isEmpty,
                  storage.records["wallet-1234"] != nil else {
                fail("workflow deleted cloud backup before server revoke-all succeeded")
            }
        }

        await expectAsyncNoThrow("workflow normalizes delete storage key") {
            let service = FakePasskeyBackupChallengeService()
            let storage = FakePasskeyBackupCloudStorage()
            storage.records["wallet-1234"] = try encryptedRecord()
            let workflow = try PasskeyBackupWorkflow(
                challengeService: service,
                cloudStorage: storage,
                isReleaseEnabled: true
            )

            try await workflow.deleteBackup(storageKey: " wallet-1234 ")

            guard service.revokedAllStorageKey == "wallet-1234",
                  storage.deletedStorageKeys == ["wallet-1234"],
                  storage.records["wallet-1234"] == nil else {
                fail("workflow did not revoke server credentials before normalized cloud deletion")
            }
        }

        expectThrow("workflow rejects unsupported relying party") {
            _ = try PasskeyBackupWorkflow(
                challengeService: FakePasskeyBackupChallengeService(),
                cloudStorage: FakePasskeyBackupCloudStorage(),
                relyingPartyId: "example.com"
            )
        }

        if let outputDirectory = ProcessInfo.processInfo.environment["IOS_PASSKEY_SERIALIZER_OUTPUT_DIR"] {
            let registrationClientDataJSON = Data(
                #"{"type":"webauthn.create","challenge":"challenge-123","origin":"https://fearlesswallet.io","crossOrigin":false}"#.utf8
            )
            let assertionClientDataJSON = Data(
                #"{"type":"webauthn.get","challenge":"challenge-456","origin":"https://fearlesswallet.io","crossOrigin":false}"#.utf8
            )
            let registrationJSON = try! PasskeyCredentialResponseSerializer.registrationJSON(
                credentialID: Data([1, 2, 3]),
                clientDataJSON: registrationClientDataJSON,
                attestationObject: Data([7, 8, 9]),
                authenticatorData: Data([10, 11, 12])
            )
            let assertionJSON = try! PasskeyCredentialResponseSerializer.assertionJSON(
                credentialID: Data([1, 2, 3]),
                clientDataJSON: assertionClientDataJSON,
                authenticatorData: Data([7, 8, 9]),
                signature: Data([10, 11, 12]),
                userHandle: Data((0 ..< 32).map { UInt8($0 + 13) })
            )
            try! registrationJSON.write(
                toFile: "\(outputDirectory)/registration-credential.json",
                atomically: true,
                encoding: .utf8
            )
            try! assertionJSON.write(
                toFile: "\(outputDirectory)/assertion-credential.json",
                atomically: true,
                encoding: .utf8
            )
        }

        print("[ios-passkey-contract-test] all tests passed")
    }
}
SWIFT

xcrun swiftc -parse-as-library "$SOURCE_FILE" "$test_file" -o "$binary"
IOS_PASSKEY_SERIALIZER_OUTPUT_DIR="$tmp_dir" "$binary"

VALIDATION_JS="$ROOT_DIR/services/passkey-backup-challenge-service/src/validation.js" \
  SERIALIZER_OUTPUT_DIR="$tmp_dir" \
  node --input-type=module <<'JAVASCRIPT'
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const validation = await import(pathToFileURL(process.env.VALIDATION_JS).href);
const registration = JSON.parse(
  fs.readFileSync(`${process.env.SERIALIZER_OUTPUT_DIR}/registration-credential.json`, 'utf8'),
);
const assertion = JSON.parse(
  fs.readFileSync(`${process.env.SERIALIZER_OUTPUT_DIR}/assertion-credential.json`, 'utf8'),
);

validation.validateCredentialResponse(registration, 'registration');
validation.validateCredentialResponse(assertion, 'authentication');
validation.validateClientDataJSON(
  registration.response.clientDataJSON,
  'webauthn.create',
  'challenge-123',
  new Set(['https://fearlesswallet.io']),
);
validation.validateClientDataJSON(
  assertion.response.clientDataJSON,
  'webauthn.get',
  'challenge-456',
  new Set(['https://fearlesswallet.io']),
);
console.log('[ios-passkey-contract-test] generated credentials match service validation');
JAVASCRIPT
