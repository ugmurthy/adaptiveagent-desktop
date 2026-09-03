import XCTest
@testable import AdaptiveAgentDesktop

final class ProtocolTests: XCTestCase {
    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object(["name": .string("agent"), "items": .array([.number(1), .bool(true), .null])])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testRequestEncodingUsesJSONRPCStringIDAndNewline() throws {
        let data = try ProtocolCodec.encodeRequest(
            id: .string("11111111-2222-3333-4444-555555555555"),
            method: "agent/run",
            params: ["goal": .string("Ship it")]
        )
        XCTAssertEqual(data.last, 0x0A)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(data.dropLast()))
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["jsonrpc"], .string("2.0"))
        XCTAssertEqual(object["id"], .string("11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(object["method"], .string("agent/run"))
        XCTAssertEqual(object["params"]?.objectValue?["goal"], .string("Ship it"))
        XCTAssertNil(object["version"])
        XCTAssertNil(object["type"])
    }

    func testRuntimeInitializationEncodesGatewayURLWithProtocolKey() throws {
        let managedRoot = "/tmp/adaptive-agent-managed-attachments"
        let parameters = RuntimeInitializationParameters(
            inferenceMode: "local",
            gatewayURL: "ws://127.0.0.1:3006/rpc",
            requireRunPermit: true,
            managedAttachmentRoot: managedRoot
        )
        let encoded = try JSONValue.encode(parameters)
        let fields = try XCTUnwrap(encoded.objectValue)

        XCTAssertEqual(fields["inferenceMode"], .string("local"))
        XCTAssertEqual(fields["gatewayUrl"], .string("ws://127.0.0.1:3006/rpc"))
        XCTAssertEqual(fields["requireRunPermit"], .bool(true))
        XCTAssertEqual(fields["managedAttachmentRoot"], .string(managedRoot))
        XCTAssertNil(fields["gatewayURL"])
        XCTAssertNil(fields["inferenceTier"])
    }

    func testAttachmentDescriptorEncodingAndOptionalRuntimeCapabilities() throws {
        let descriptor = AttachmentDescriptor(
            attachmentId: "attachment-1",
            kind: .image,
            stagedRelativePath: "attachment-1/report.pdf",
            name: "report.pdf",
            mimeType: "application/pdf",
            sizeBytes: 123,
            sha256: String(repeating: "a", count: 64),
            audioFormat: .wav
        )
        XCTAssertEqual(descriptor.protocolValue.objectValue?["stagedRelativePath"], .string("attachment-1/report.pdf"))
        XCTAssertEqual(descriptor.protocolValue.objectValue?["sizeBytes"], .number(123))
        XCTAssertEqual(descriptor.protocolValue.objectValue?["kind"], .string("image"))
        XCTAssertNil(descriptor.protocolValue.objectValue?["audioFormat"])

        let audio = AttachmentDescriptor(
            attachmentId: "attachment-2",
            kind: .audio,
            stagedRelativePath: "attachment-2/recording.mp3",
            name: "recording.mp3",
            mimeType: "audio/mpeg",
            sizeBytes: 456,
            sha256: String(repeating: "b", count: 64),
            audioFormat: .mp3
        )
        XCTAssertEqual(audio.protocolValue.objectValue?["kind"], .string("audio"))
        XCTAssertEqual(audio.protocolValue.objectValue?["audioFormat"], .string("mp3"))

        let fixture = JSONValue.object([
            "agent": .object(["id": .string("default"), "name": .string("Default")]),
            "runtimeMode": .string("memory"),
            "workspaceRoot": .string("/tmp"),
            "shellCwd": .string("/tmp"),
            "registeredToolNames": .array([]),
            "attachments": .object([
                "enabled": .bool(true),
                "maxFileBytes": .number(10 * 1024 * 1024),
                "maxAttachmentCount": .number(8),
                "maxSubmissionBytes": .number(40 * 1024 * 1024),
                "acceptedKinds": .array([.string("file"), .string("image"), .string("audio")]),
                "supportedImageMimeTypes": .array([.string("image/png")]),
                "supportedAudioMimeTypes": .array([.string("audio/mpeg")]),
                "supportedAudioFormats": .array([.string("mp3")]),
                "supportedGenericMimeTypes": .array([.string("application/pdf")]),
                "routing": .object([
                    "taskGeneric": .string("direct"), "chatGeneric": .string("direct"),
                    "taskImage": .string("direct"), "taskAudio": .string("direct"),
                    "chatImage": .string("direct"), "chatAudio": .string("direct")
                ])
            ])
        ])
        let decoded = try fixture.decode(RuntimeInitializationResult.self)
        XCTAssertEqual(decoded.attachments?.enabled, true)
        XCTAssertEqual(decoded.attachments?.maxAttachmentCount, 8)
        XCTAssertEqual(decoded.attachments?.supportedAudioFormats, [.mp3])

        var legacyFields = try XCTUnwrap(fixture.objectValue?["attachments"]?.objectValue)
        legacyFields.removeValue(forKey: "supportedImageMimeTypes")
        legacyFields.removeValue(forKey: "supportedAudioMimeTypes")
        legacyFields.removeValue(forKey: "supportedAudioFormats")
        var legacyFixture = try XCTUnwrap(fixture.objectValue)
        legacyFixture["attachments"] = .object(legacyFields)
        let legacy = try JSONValue.object(legacyFixture).decode(RuntimeInitializationResult.self)
        XCTAssertNil(legacy.attachments?.supportedImageMimeTypes)
        XCTAssertNil(legacy.attachments?.supportedAudioMimeTypes)
        XCTAssertNil(legacy.attachments?.supportedAudioFormats)

        var withoutCapabilities = try XCTUnwrap(fixture.objectValue)
        withoutCapabilities.removeValue(forKey: "attachments")
        XCTAssertNil(try JSONValue.object(withoutCapabilities).decode(RuntimeInitializationResult.self).attachments)
    }

    func testAttachmentStoreCreatesImmutableHashedSnapshot() async throws {
        let base = try temporaryDirectoryURL()
        let root = base.appendingPathComponent("managed", isDirectory: true)
        let source = base.appendingPathComponent("quarterly report.txt")
        try Data("hello".utf8).write(to: source)
        let store = try AttachmentStore(rootURL: root)

        let imported = try await store.importFiles([source], existing: [])
        let descriptor = try XCTUnwrap(imported.first)
        XCTAssertEqual(descriptor.kind, .file)
        XCTAssertEqual(descriptor.name, "quarterly_report.txt")
        XCTAssertEqual(descriptor.sizeBytes, 5)
        XCTAssertEqual(descriptor.sha256, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(descriptor.stagedRelativePath, "\(descriptor.attachmentId)/\(descriptor.name)")

        let staged = root
            .appendingPathComponent(descriptor.attachmentId, isDirectory: true)
            .appendingPathComponent(descriptor.name)
        try Data("changed".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: staged), Data("hello".utf8))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o400)
    }

    func testAttachmentStoreRejectsSymlinksDirectoriesAndLimits() async throws {
        let base = try temporaryDirectoryURL()
        let store = try AttachmentStore(rootURL: base.appendingPathComponent("managed", isDirectory: true))
        let regular = base.appendingPathComponent("regular.txt")
        try Data("safe".utf8).write(to: regular)
        let symlink = base.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)

        await assertThrows({ try await store.importFiles([symlink], existing: []) }) { error in
            guard case .invalidFile = error as? AttachmentStoreError else {
                return XCTFail("expected invalidFile, got \(error)")
            }
        }
        await assertThrows { try await store.importFiles([base], existing: []) }

        let dummy = (0..<AttachmentStore.maximumAttachmentCount).map { index in
            AttachmentDescriptor(
                attachmentId: "id-\(index)", kind: .file, stagedRelativePath: "id-\(index)/f",
                name: "f", mimeType: nil, sizeBytes: 1, sha256: String(repeating: "0", count: 64)
            )
        }
        await assertThrows({ try await store.importFiles([regular], existing: dummy) }) { error in
            XCTAssertEqual(error as? AttachmentStoreError, .tooManyFiles)
        }

        let oversized = base.appendingPathComponent("oversized.bin")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(AttachmentStore.maximumFileBytes + 1))
        try handle.close()
        await assertThrows({ try await store.importFiles([oversized], existing: []) }) { error in
            guard case .fileTooLarge = error as? AttachmentStoreError else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
        }
    }

    func testAttachmentStoreInfersAndValidatesImageAndAudioMedia() async throws {
        let base = try temporaryDirectoryURL()
        let store = try AttachmentStore(rootURL: base.appendingPathComponent("managed", isDirectory: true))
        let image = base.appendingPathComponent("pixel.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!.write(to: image)
        let audio = base.appendingPathComponent("silence.wav")
        try waveData().write(to: audio)
        let capabilities = try mediaAttachmentCapabilities()

        let images = try await store.importFiles([image], existing: [], kind: .image, capabilities: capabilities)
        XCTAssertEqual(images.first?.kind, .image)
        XCTAssertEqual(images.first?.mimeType, "image/png")
        XCTAssertNil(images.first?.audioFormat)

        let audioFiles = try await store.importFiles([audio], existing: images, kind: .audio, capabilities: capabilities)
        XCTAssertEqual(audioFiles.first?.kind, .audio)
        XCTAssertEqual(audioFiles.first?.mimeType, "audio/wav")
        XCTAssertEqual(audioFiles.first?.audioFormat, .wav)

        let disguised = base.appendingPathComponent("not-an-image.png")
        try Data("not image data".utf8).write(to: disguised)
        await assertThrows({
            try await store.importFiles([disguised], existing: [], kind: .image, capabilities: capabilities)
        }) { error in
            guard case .mediaTypeMismatch = error as? AttachmentStoreError else {
                return XCTFail("expected mediaTypeMismatch, got \(error)")
            }
        }

        let fileOnly = try JSONDecoder().decode(
            AttachmentCapabilities.self,
            from: Data(#"{"enabled":true,"maxFileBytes":10485760,"maxAttachmentCount":8,"maxSubmissionBytes":41943040,"acceptedKinds":["file"],"supportedGenericMimeTypes":["application/json"]}"#.utf8)
        )
        await assertThrows({
            try await store.importFiles([image], existing: [], kind: .image, capabilities: fileOnly)
        }) { error in
            XCTAssertEqual(error as? AttachmentStoreError, .unsupportedKind(.image))
        }

        var unsupportedImageFields = try XCTUnwrap(try JSONValue.encode(capabilities).objectValue)
        unsupportedImageFields["supportedImageMimeTypes"] = .array([.string("image/jpeg")])
        let unsupportedImage = try JSONValue.object(unsupportedImageFields).decode(AttachmentCapabilities.self)
        await assertThrows({
            try await store.importFiles([image], existing: [], kind: .image, capabilities: unsupportedImage)
        }) { error in
            XCTAssertEqual(error as? AttachmentStoreError, .unsupportedType("pixel.png", .image))
        }
    }

    func testAttachmentStoreStartupCleanupPreservesOwnedFiles() async throws {
        let base = try temporaryDirectoryURL()
        let root = base.appendingPathComponent("managed", isDirectory: true)
        let first = base.appendingPathComponent("first.txt")
        let second = base.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let store = try AttachmentStore(rootURL: root)
        let descriptors = try await store.importFiles([first, second], existing: [])
        try await store.markOwned([descriptors[1]])

        try await store.cleanAbandonedDrafts()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(descriptors[0].attachmentId).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(descriptors[1].attachmentId).path))
    }

    func testReadyNotificationRequiresNoIDAndExactStringVersion() throws {
        let message = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":12}}"#.utf8))
        XCTAssertEqual(message, .ready(RuntimeReady(protocolVersion: "1.17", bridgeVersion: "0.1.0", pid: 12)))

        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","id":"ready","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":12}}"#.utf8)))
        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":1.17,"bridgeVersion":"0.1.0","pid":12}}"#.utf8)))
    }

    func testResponsesPreserveIDTypesAndDecodeProtocolErrorCode() throws {
        let stringID = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","id":"1","result":{"runId":"r"}}"#.utf8))
        XCTAssertEqual(stringID, .success(id: .string("1"), result: .object(["runId": .string("r")])))

        let numericID = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8))
        XCTAssertEqual(numericID, .success(id: .number(1), result: .null))

        let failure = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","id":"e","error":{"code":-32602,"message":"Invalid parameters","data":{"protocolCode":"INVALID_PARAMS"}}}"#.utf8))
        XCTAssertEqual(failure, .failure(
            id: .string("e"),
            error: JSONRPCErrorObject(
                code: -32602,
                message: "Invalid parameters",
                data: .object(["protocolCode": .string("INVALID_PARAMS")])
            )
        ))
    }

    func testNotificationsAreDistinctFromResponses() throws {
        let event = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"agent/event","params":{"type":"run.started"}}"#.utf8))
        XCTAssertEqual(event, .notification(method: "agent/event", params: .object(["type": .string("run.started")])))

        let output = try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"cli/output","params":{"stream":"stdout","line":"ok"}}"#.utf8))
        XCTAssertEqual(output, .notification(method: "cli/output", params: .object(["stream": .string("stdout"), "line": .string("ok")])))
    }

    func testLegacyMessagesAndBatchesAreRejected() {
        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"{"version":1,"id":"hello","type":"hello"}"#.utf8)))
        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"[{"jsonrpc":"2.0","id":1,"result":null}]"#.utf8)))
        XCTAssertThrowsError(try ProtocolCodec.decodeMessage(Data(#"{"jsonrpc":"2.0","method":"agent/event","id":1,"params":{}}"#.utf8)))
    }

    func testNDJSONBufferHandlesFragmentedAndMultipleMessages() throws {
        var buffer = NDJSONBuffer()
        XCTAssertTrue(try buffer.append(Data(#"{"jsonrpc":"2.0""#.utf8)).isEmpty)
        let lines = try buffer.append(Data("}\n{\"jsonrpc\":\"2.0\"}\npartial".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, [#"{"jsonrpc":"2.0"}"#, #"{"jsonrpc":"2.0"}"#])
        XCTAssertEqual(try buffer.append(Data(" line\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["partial line"])
    }

    func testNDJSONBufferRejectsOversizedLines() throws {
        var buffer = NDJSONBuffer(maximumLineBytes: 4)
        XCTAssertEqual(try buffer.append(Data("1234\n".utf8)), [Data("1234".utf8)])
        XCTAssertThrowsError(try buffer.append(Data("12345".utf8)))
    }

    @MainActor
    func testAppModelAcceptsSQLiteSettingsAndUsesLaunchDirectory() async throws {
        let workspace = try temporaryDirectoryURL()
        let settings = workspace.appendingPathComponent("agent.settings.json")
        try #"""
        {
          "runtime": { "mode": "sqlite" },
          "model": {
            "overrideProvider": "openrouter",
            "overrideModel": "qwen/qwen3.5-27b",
            "overrideApiKeyEnv": "OPENROUTER_API_KEY"
          },
          "interaction": {
            "autoApprove": false,
            "approvalMode": "auto",
            "interactive": true,
            "clarificationMode": "fail"
          },
          "inference": { "mode": "gateway", "tier": "high" },
          "gateway": {
            "url": "ws://127.0.0.1:3006/rpc",
            "accessTokenEnv": "ADAPTIVE_AGENT_ACCESS_TOKEN",
            "requireRunPermit": true
          }
        }
        """#.write(to: settings, atomically: true, encoding: .utf8)
        let requestLog = temporaryFileURL(named: "app-model-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize)
      printf '{"jsonrpc":"2.0","id":"%s","result":{"agent":{"id":"default","name":"Default Agent"},"runtimeMode":"memory","workspaceRoot":"%s","shellCwd":"%s","registeredToolNames":["write_file"]}}\n' "$id" \#(shellQuote(workspace.path)) \#(shellQuote(workspace.path))
      ;;
    runtime/info) printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","initialized":true,"clientInfo":{"name":"adaptive-agent-desktop"},"runtimeMode":"memory","agentId":"default","workspaceRoot":"%s","connections":{"sqlite":{"configured":true,"state":"connected"},"gateway":{"configured":false,"state":"not_configured"}}}}\n' "$id" \#(shellQuote(workspace.path)) ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        let model = AppModel(client: client, workingDirectoryURL: workspace)

        XCTAssertEqual(model.workspacePath, workspace.standardizedFileURL.path)
        XCTAssertEqual(model.settingsConfigPath, settings.path)
        XCTAssertEqual(model.configuredRuntimeMode, "sqlite")
        XCTAssertEqual(model.configuredProvider, "openrouter")
        XCTAssertEqual(model.configuredModel, "qwen/qwen3.5-27b")
        XCTAssertEqual(model.configuredApprovalMode, "auto", "approvalMode should take precedence over legacy autoApprove")
        XCTAssertEqual(model.configuredClarificationMode, "fail")
        XCTAssertEqual(model.configuredInferenceMode, "gateway")
        XCTAssertEqual(model.configuredInferenceTier, "high")
        XCTAssertEqual(model.configuredGatewayURL, "ws://127.0.0.1:3006/rpc")
        XCTAssertTrue(model.configuredRequireRunPermit)
        XCTAssertNil(model.settingsConfigurationError)

        model.selectInferenceMode("local")
        XCTAssertEqual(model.configuredInferenceMode, "local")
        XCTAssertFalse(model.configuredRequireRunPermit)

        model.bootstrap()
        for _ in 0..<100 where !model.isConnected {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isConnected, model.status)
        XCTAssertFalse(model.attachmentsEnabled, "Fixtures without attachment capabilities must remain text-only")
        XCTAssertFalse(model.attachmentEnabled(for: .image))
        XCTAssertFalse(model.attachmentEnabled(for: .audio))
        XCTAssertTrue(model.attachmentUnavailableReason(for: .image)?.contains("does not report") == true)
        XCTAssertTrue(model.attachmentUnavailableReason(for: .audio)?.contains("does not report") == true)
        XCTAssertEqual(model.agentName, "Default Agent")
        XCTAssertEqual(model.effectiveWorkspaceRoot, workspace.path)

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let runtimeInitialize = try XCTUnwrap(requests.first {
            $0.objectValue?["method"] == .string("runtime/initialize")
        })
        let params = try XCTUnwrap(runtimeInitialize.objectValue?["params"]?.objectValue)
        XCTAssertEqual(params["cwd"], .string(workspace.path))
        XCTAssertEqual(params["settingsConfigPath"], .string(settings.path))
        XCTAssertEqual(params["runtimeMode"], .string("sqlite"))
        XCTAssertEqual(params["provider"], .string("openrouter"))
        XCTAssertEqual(params["model"], .string("qwen/qwen3.5-27b"))
        XCTAssertEqual(params["approvalMode"], .string("auto"))
        XCTAssertEqual(params["clarificationMode"], .string("fail"))
        XCTAssertNil(params["overrideApiKeyEnv"])
        XCTAssertNil(params["apiKey"])
        XCTAssertNil(params["agentConfigPath"])
        XCTAssertEqual(params["inferenceMode"], .string("local"))
        XCTAssertNil(params["inferenceTier"])
        XCTAssertEqual(params["gatewayUrl"], .string("ws://127.0.0.1:3006/rpc"))
        XCTAssertEqual(params["requireRunPermit"], .bool(false))
        XCTAssertNil(params["gatewayURL"])
        XCTAssertNil(params["accessTokenEnv"])
        await model.shutdown()
    }

    @MainActor
    func testAppModelAppliesTokenBeforeTypedInitializationAndLoadsRuntimeInfo() async throws {
        let workspace = try temporaryDirectoryURL()
        let requestLog = temporaryFileURL(named: "app-model-auth-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    auth/updateAccessToken) printf '{"jsonrpc":"2.0","id":"%s","result":{"updated":true}}\n' "$id" ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{"agent":{"id":"default","name":"Default Agent"},"runtimeMode":"memory","workspaceRoot":"%s","shellCwd":"%s","registeredToolNames":[],"inferenceMode":"gateway","inferenceTier":"high"}}\n' "$id" \#(shellQuote(workspace.path)) \#(shellQuote(workspace.path)) ;;
    runtime/info) printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","initialized":true,"clientInfo":{"name":"adaptive-agent-desktop","version":"1.0.2"},"runtimeMode":"memory","agentId":"default","workspaceRoot":"%s","inferenceMode":"gateway","inferenceTier":"high","connections":{"sqlite":{"configured":true,"state":"connected"},"gateway":{"configured":true,"state":"connected"}}}}\n' "$id" \#(shellQuote(workspace.path)) ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let model = AppModel(
            client: RuntimeClient(executableURL: executable, responseTimeout: .seconds(2)),
            workingDirectoryURL: workspace
        )
        let accessToken = "secret-ui-access-token"
        model.accessTokenDraft = accessToken
        model.configuredInferenceMode = "gateway"
        model.configuredInferenceTier = "high"
        model.configuredGatewayURL = "wss://gateway.example.com/rpc"
        model.bootstrap()
        for _ in 0..<100 where model.runtimeInfoSnapshot == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(model.isConnected, model.status)
        XCTAssertEqual(model.runtimeInfoSnapshot?.initialized, true)
        XCTAssertEqual(model.runtimeInfoSnapshot?.inferenceMode, "gateway")
        XCTAssertEqual(model.runtimeInfoSnapshot?.inferenceTier, "high")
        XCTAssertEqual(model.runtimeInfoSnapshot?.connections?.gateway?.state, "connected")
        XCTAssertEqual(model.runtimeInfoSnapshot?.connections?.sqlite?.state, "connected")
        XCTAssertFalse(model.status.contains(accessToken))
        XCTAssertFalse(model.events.joined().contains(accessToken))

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(requests.prefix(4).compactMap { $0.objectValue?["method"]?.stringValue }, [
            "initialize", "auth/updateAccessToken", "runtime/initialize", "runtime/info"
        ])
        let auth = try XCTUnwrap(requests.first { $0.objectValue?["method"] == .string("auth/updateAccessToken") })
        XCTAssertEqual(auth.objectValue?["params"]?.objectValue?["accessToken"], .string(accessToken))
        let runtimeInitialize = try XCTUnwrap(requests.first { $0.objectValue?["method"] == .string("runtime/initialize") })
        XCTAssertEqual(runtimeInitialize.objectValue?["params"]?.objectValue?["inferenceMode"], .string("gateway"))
        XCTAssertEqual(runtimeInitialize.objectValue?["params"]?.objectValue?["inferenceTier"], .string("high"))
        XCTAssertEqual(runtimeInitialize.objectValue?["params"]?.objectValue?["gatewayUrl"], .string("wss://gateway.example.com/rpc"))
        XCTAssertNil(runtimeInitialize.objectValue?["params"]?.objectValue?["accessToken"])

        model.clearAccessToken()
        XCTAssertTrue(model.accessTokenDraft.isEmpty)
        XCTAssertFalse(model.accessTokenMessage?.contains(accessToken) ?? false)
        try? await Task.sleep(for: .milliseconds(50))
        let authRequestCount = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            .filter { $0.objectValue?["method"] == .string("auth/updateAccessToken") }
            .count
        XCTAssertEqual(authRequestCount, 1, "Clearing the local field must not send an empty token")
        await model.shutdown()
    }

    @MainActor
    func testAppModelSendsProtocol117RunIdentityAndChatTranscript() async throws {
        let workspace = try temporaryDirectoryURL()
        let unavailableAttachmentRoot = workspace.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: unavailableAttachmentRoot)
        let requestLog = temporaryFileURL(named: "protocol-117-agent-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  run_id="$(printf '%s' "$line" | sed -E 's/.*"runId":"([^"]+)".*/\1/')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{"agent":{"id":"default","name":"Default Agent"},"runtimeMode":"memory","workspaceRoot":"%s","shellCwd":"%s","registeredToolNames":[]}}\n' "$id" \#(shellQuote(workspace.path)) \#(shellQuote(workspace.path)) ;;
    runtime/info) printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","initialized":true,"clientInfo":{"name":"adaptive-agent-desktop"},"runtimeMode":"memory","agentId":"default","workspaceRoot":"%s"}}\n' "$id" \#(shellQuote(workspace.path)) ;;
    agent/run) printf '{"jsonrpc":"2.0","id":"%s","result":{"status":"success","runId":"%s","output":"Done"}}\n' "$id" "$run_id" ;;
    agent/chat) printf '{"jsonrpc":"2.0","id":"%s","result":{"status":"success","runId":"%s","output":"Reply"}}\n' "$id" "$run_id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let model = AppModel(
            client: RuntimeClient(executableURL: executable, responseTimeout: .seconds(2)),
            workingDirectoryURL: workspace,
            attachmentStoreRootURL: unavailableAttachmentRoot
        )
        model.bootstrap()
        for _ in 0..<100 where !model.isConnected {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isConnected, model.status)
        XCTAssertFalse(model.attachmentsEnabled)
        XCTAssertTrue(model.attachmentUnavailableReason?.contains("unavailable") == true)

        let runTabID = try XCTUnwrap(model.selectedTabID)
        model.setDraftText("Run this task", forTab: runTabID)
        model.submitDraft(in: runTabID)
        for _ in 0..<100 where model.runs.first?.status != .succeeded {
            try? await Task.sleep(for: .milliseconds(20))
        }

        model.newChat()
        let chatTabID = try XCTUnwrap(model.selectedTabID)
        model.setDraftText("First question", forTab: chatTabID)
        model.submitDraft(in: chatTabID)
        for _ in 0..<100 where model.runs.first?.status != .succeeded {
            try? await Task.sleep(for: .milliseconds(20))
        }
        model.setChatMessage("Follow up", forTab: chatTabID)
        model.sendChatMessage(in: chatTabID)
        for _ in 0..<100 where model.runs.first?.isRequestInFlight == true {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let runRequest = try XCTUnwrap(requests.first { $0.objectValue?["method"] == .string("agent/run") })
        let runParams = try XCTUnwrap(runRequest.objectValue?["params"]?.objectValue)
        XCTAssertFalse(try XCTUnwrap(runParams["runId"]?.stringValue).isEmpty)
        XCTAssertEqual(runParams["goal"], .string("Run this task"))
        XCTAssertNil(runParams["attachments"])
        let runtimeInitialize = try XCTUnwrap(requests.first {
            $0.objectValue?["method"] == .string("runtime/initialize")
        })
        XCTAssertNil(runtimeInitialize.objectValue?["params"]?.objectValue?["managedAttachmentRoot"])

        let chatRequests = requests.filter { $0.objectValue?["method"] == .string("agent/chat") }
        XCTAssertEqual(chatRequests.count, 2)
        let firstChatParams = try XCTUnwrap(chatRequests.first?.objectValue?["params"]?.objectValue)
        XCTAssertFalse(try XCTUnwrap(firstChatParams["runId"]?.stringValue).isEmpty)
        XCTAssertNil(firstChatParams["message"])
        guard case .array(let firstTranscript) = firstChatParams["transcript"] else {
            return XCTFail("Initial chat must send a transcript")
        }
        XCTAssertEqual(firstTranscript, [.object(["role": .string("user"), "content": .string("First question")])])

        let followUpParams = try XCTUnwrap(chatRequests.last?.objectValue?["params"]?.objectValue)
        XCTAssertNotEqual(followUpParams["runId"], firstChatParams["runId"])
        guard case .array(let followUpTranscript) = followUpParams["transcript"] else {
            return XCTFail("Follow-up chat must send the complete transcript")
        }
        XCTAssertEqual(followUpTranscript, [
            .object(["role": .string("user"), "content": .string("First question")]),
            .object(["role": .string("assistant"), "content": .string("Reply")]),
            .object(["role": .string("user"), "content": .string("Follow up")])
        ])
        await model.shutdown()
    }

    @MainActor
    func testAppModelStagesSupportedRunAttachmentsWithoutAffectingTextOnlyOrChatPayloads() async throws {
        let workspace = try temporaryDirectoryURL()
        let managedRoot = try temporaryDirectoryURL().appendingPathComponent("managed", isDirectory: true)
        let source = workspace.appendingPathComponent("input.json")
        try Data(#"{"value":1}"#.utf8).write(to: source)
        let image = workspace.appendingPathComponent("pixel.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!.write(to: image)
        let audio = workspace.appendingPathComponent("silence.wav")
        try waveData().write(to: audio)
        let requestLog = temporaryFileURL(named: "attachment-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  run_id="$(printf '%s' "$line" | sed -E 's/.*"runId":"([^"]+)".*/\1/')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{"agent":{"id":"default","name":"Default Agent"},"runtimeMode":"memory","workspaceRoot":"%s","shellCwd":"%s","registeredToolNames":[],"attachments":{"enabled":true,"maxFileBytes":10485760,"maxAttachmentCount":8,"maxSubmissionBytes":41943040,"acceptedKinds":["file","image","audio"],"supportedImageMimeTypes":["image/png"],"supportedAudioMimeTypes":["audio/wav"],"supportedAudioFormats":["wav"],"supportedGenericMimeTypes":["application/json"],"routing":{"taskGeneric":"direct","chatGeneric":"direct","taskImage":"direct","taskAudio":"direct","chatImage":"direct","chatAudio":"direct"}}}}\n' "$id" \#(shellQuote(workspace.path)) \#(shellQuote(workspace.path)) ;;
    runtime/info) printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","initialized":true,"clientInfo":{"name":"adaptive-agent-desktop"},"runtimeMode":"memory","agentId":"default","workspaceRoot":"%s"}}\n' "$id" \#(shellQuote(workspace.path)) ;;
    agent/run|agent/chat) printf '{"jsonrpc":"2.0","id":"%s","result":{"status":"success","runId":"%s","output":"Done"}}\n' "$id" "$run_id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let model = AppModel(
            client: RuntimeClient(executableURL: executable, responseTimeout: .seconds(2)),
            workingDirectoryURL: workspace,
            attachmentStoreRootURL: managedRoot
        )
        model.bootstrap()
        for _ in 0..<100 where !model.attachmentsEnabled { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.attachmentsEnabled, model.attachmentUnavailableReason ?? model.status)
        XCTAssertTrue(model.attachmentEnabled(for: .image))
        XCTAssertTrue(model.attachmentEnabled(for: .audio))

        let runTabID = try XCTUnwrap(model.selectedTabID)
        await model.importAttachments([source], forTab: runTabID)
        await model.importAttachments([image], kind: .image, forTab: runTabID)
        await model.importAttachments([audio], kind: .audio, forTab: runTabID)
        XCTAssertEqual(model.selectedTab?.draftAttachments.map(\.kind), [.file, .image, .audio])
        model.setDraftText("Read the attachments", forTab: runTabID)
        model.submitDraft(in: runTabID)
        for _ in 0..<100 where model.runs.first?.status != .succeeded { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.runs.first?.attachments.first?.name, "input.json")

        model.newChat()
        let chatTabID = try XCTUnwrap(model.selectedTabID)
        model.setDraftText("Text only", forTab: chatTabID)
        model.submitDraft(in: chatTabID)
        for _ in 0..<100 where model.runs.count < 2 || model.runs.first?.status != .succeeded {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let runtimeInitialize = try XCTUnwrap(requests.first { $0.objectValue?["method"] == .string("runtime/initialize") })
        XCTAssertEqual(runtimeInitialize.objectValue?["params"]?.objectValue?["managedAttachmentRoot"], .string(managedRoot.path))
        let run = try XCTUnwrap(requests.first { $0.objectValue?["method"] == .string("agent/run") })
        guard case .array(let attachments) = run.objectValue?["params"]?.objectValue?["attachments"] else {
            return XCTFail("agent/run attachments missing")
        }
        XCTAssertEqual(attachments.count, 3)
        let sent = try attachments.map { try XCTUnwrap($0.objectValue) }
        XCTAssertEqual(sent.map { $0["kind"] }, [.string("file"), .string("image"), .string("audio")])
        XCTAssertEqual(sent.map { $0["name"] }, [.string("input.json"), .string("pixel.png"), .string("silence.wav")])
        XCTAssertEqual(sent.map { $0["mimeType"] }, [.string("application/json"), .string("image/png"), .string("audio/wav")])
        XCTAssertNil(sent[0]["audioFormat"])
        XCTAssertNil(sent[1]["audioFormat"])
        XCTAssertEqual(sent[2]["audioFormat"], .string("wav"))
        XCTAssertTrue(sent.allSatisfy { $0["stagedRelativePath"]?.stringValue?.hasPrefix("/") == false })
        let runParams = try XCTUnwrap(run.objectValue?["params"]?.objectValue)
        XCTAssertEqual(runParams["goal"], .string("Read the attachments"))
        XCTAssertNotNil(runParams["runId"]?.stringValue)
        XCTAssertEqual(Set(runParams.keys), ["runId", "goal", "attachments"])
        let chat = try XCTUnwrap(requests.first { $0.objectValue?["method"] == .string("agent/chat") })
        XCTAssertNil(chat.objectValue?["params"]?.objectValue?["attachments"])
        await model.shutdown()
    }

    @MainActor
    func testAppModelLoadsLegacyInteractionSettingsAndSafeFallbacks() throws {
        let workspace = try temporaryDirectoryURL()
        let settings = workspace.appendingPathComponent("agent.settings.json")
        try #"""
        {
          "interaction": {
            "autoApprove": true,
            "interactive": false
          }
        }
        """#.write(to: settings, atomically: true, encoding: .utf8)

        let model = AppModel(workingDirectoryURL: workspace)
        XCTAssertEqual(model.configuredApprovalMode, "auto")
        XCTAssertEqual(model.configuredClarificationMode, "fail")

        try "{}".write(to: settings, atomically: true, encoding: .utf8)
        model.reloadSettingsConfiguration()
        XCTAssertEqual(model.configuredApprovalMode, "manual")
        XCTAssertEqual(model.configuredClarificationMode, "interactive")
        XCTAssertEqual(model.configuredRuntimeMode, "")
        XCTAssertEqual(model.configuredProvider, "")
        XCTAssertEqual(model.configuredModel, "")
        XCTAssertEqual(model.configuredInferenceMode, "")
        XCTAssertEqual(model.configuredInferenceTier, "")
        XCTAssertEqual(model.configuredGatewayURL, "")
        XCTAssertFalse(model.configuredRequireRunPermit)
    }

    @MainActor
    func testApplyingTypedSettingsPathReloadsOverridesBeforeInitialization() async throws {
        let workspace = try temporaryDirectoryURL()
        let localSettings = workspace.appendingPathComponent("agent.settings.json")
        let replacementSettings = workspace.appendingPathComponent("replacement.settings.json")
        try #"{"runtime":{"mode":"postgres"},"interaction":{"approvalMode":"auto"}}"#
            .write(to: localSettings, atomically: true, encoding: .utf8)
        try #"{"runtime":{"mode":"memory"},"interaction":{"approvalMode":"manual","clarificationMode":"fail"}}"#
            .write(to: replacementSettings, atomically: true, encoding: .utf8)
        let requestLog = temporaryFileURL(named: "typed-settings-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{"agent":{"id":"default","name":"Default Agent"},"runtimeMode":"memory","workspaceRoot":"%s","shellCwd":"%s","registeredToolNames":[]}}\n' "$id" \#(shellQuote(workspace.path)) \#(shellQuote(workspace.path)) ;;
    runtime/info) printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","initialized":true,"clientInfo":{"name":"adaptive-agent-desktop"},"runtimeMode":"memory","agentId":"default","workspaceRoot":"%s"}}\n' "$id" \#(shellQuote(workspace.path)) ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let model = AppModel(
            client: RuntimeClient(executableURL: executable, responseTimeout: .seconds(2)),
            workingDirectoryURL: workspace
        )
        XCTAssertEqual(model.configuredApprovalMode, "auto")
        model.settingsConfigPath = replacementSettings.path
        model.showConfiguration = true
        model.applyConfiguration()
        for _ in 0..<100 where !model.isConnected {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isConnected, model.status)
        XCTAssertFalse(model.showConfiguration)

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let initialization = try XCTUnwrap(requests.first {
            $0.objectValue?["method"] == .string("runtime/initialize")
        })
        let params = try XCTUnwrap(initialization.objectValue?["params"]?.objectValue)
        XCTAssertEqual(params["settingsConfigPath"], .string(replacementSettings.path))
        XCTAssertEqual(params["runtimeMode"], .string("memory"))
        XCTAssertEqual(params["approvalMode"], .string("manual"))
        XCTAssertEqual(params["clarificationMode"], .string("fail"))
        await model.shutdown()
    }

    @MainActor
    func testRunTabsKeepIndependentUIStateAndReopenClosedRunsWithoutInterrupting() throws {
        let model = AppModel(workingDirectoryURL: try temporaryDirectoryURL())
        let firstTabID = try XCTUnwrap(model.selectedTabID)
        model.setDraftText("First draft", forTab: firstTabID)
        model.setChatMessage("First chat composer", forTab: firstTabID)
        model.setSteerMessage("First steering note", forTab: firstTabID)
        model.setScrollPosition("message-first", forTab: firstTabID)
        model.setDetailMode(.inspection, forTab: firstTabID)

        model.newChat()
        let secondTabID = try XCTUnwrap(model.selectedTabID)
        XCTAssertNotEqual(secondTabID, firstTabID)
        model.setDraftText("Second draft", forTab: secondTabID)
        model.setChatMessage("Second chat composer", forTab: secondTabID)
        model.setSteerMessage("Second steering note", forTab: secondTabID)
        model.setScrollPosition("message-second", forTab: secondTabID)

        model.selectTab(firstTabID)
        XCTAssertEqual(model.selectedTab?.draftKind, .run)
        XCTAssertEqual(model.selectedTab?.draftText, "First draft")
        XCTAssertEqual(model.selectedTab?.chatMessage, "First chat composer")
        XCTAssertEqual(model.selectedTab?.steerMessage, "First steering note")
        XCTAssertNil(model.selectedTab?.scrollPosition, "Changing the detail mode should reset its scroll target")
        XCTAssertEqual(model.selectedTab?.detailMode, .inspection)

        model.selectTab(secondTabID)
        XCTAssertEqual(model.selectedTab?.draftKind, .chat)
        XCTAssertEqual(model.selectedTab?.draftText, "Second draft")
        XCTAssertEqual(model.selectedTab?.chatMessage, "Second chat composer")
        XCTAssertEqual(model.selectedTab?.steerMessage, "Second steering note")
        XCTAssertEqual(model.selectedTab?.scrollPosition, "message-second")
        XCTAssertEqual(model.selectedTab?.detailMode, .results)

        let recordID = UUID()
        model.runs = [AppModel.RunRecord(
            id: recordID,
            kind: .run,
            title: "Background run",
            status: .running,
            isRequestInFlight: true
        )]
        model.openRunTab(recordID)
        let runTabID = try XCTUnwrap(model.selectedTabID)
        XCTAssertEqual(model.selectedRunItemID, recordID)
        XCTAssertEqual(model.tabs.count, 3)

        model.closeTab(runTabID)
        XCTAssertEqual(model.runs.first?.status, .running)
        XCTAssertEqual(model.runs.first?.isRequestInFlight, true)
        XCTAssertNil(model.tabs.first(where: { $0.selectedRunID == recordID }))

        model.openRunTab(recordID)
        XCTAssertEqual(model.selectedRunItemID, recordID)
        XCTAssertNotNil(model.tabs.first(where: { $0.selectedRunID == recordID }))
        let reopenedTabCount = model.tabs.count
        model.openRunTab(recordID)
        XCTAssertEqual(model.tabs.count, reopenedTabCount, "An already open run should activate its tab instead of duplicating it")
    }

    @MainActor
    func testRunActionCanInspectAnEnteredRunIDWithoutAnExistingRecord() async throws {
        let workspace = try temporaryDirectoryURL()
        let requestLog = temporaryFileURL(named: "entered-run-action-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{"agent":{"id":"default","name":"Default Agent"},"runtimeMode":"memory","workspaceRoot":"%s","shellCwd":"%s","registeredToolNames":[]}}\n' "$id" \#(shellQuote(workspace.path)) \#(shellQuote(workspace.path)) ;;
    runtime/info) printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","initialized":true,"clientInfo":{"name":"adaptive-agent-desktop"},"runtimeMode":"memory","agentId":"default","workspaceRoot":"%s"}}\n' "$id" \#(shellQuote(workspace.path)) ;;
    run/inspect) printf '{"jsonrpc":"2.0","id":"%s","result":{"run":{"id":"persisted-run","status":"running"},"events":[]}}\n' "$id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        let model = AppModel(client: client, workingDirectoryURL: workspace)
        model.bootstrap()
        for _ in 0..<100 where !model.isConnected {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isConnected, model.status)
        XCTAssertTrue(model.runs.isEmpty)

        model.runCommand(
            "run/inspect",
            runId: "  persisted-run  ",
            displayTitle: "Historical research goal"
        )
        let recordID = try XCTUnwrap(model.runs.first?.id)
        model.runs[0].output = .string("Original result")
        for _ in 0..<100 {
            if model.runs.first?.inspection != nil, model.runs.first?.isRequestInFlight == false { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let record = try XCTUnwrap(model.runs.first)
        XCTAssertEqual(model.selectedRunItemID, record.id)
        XCTAssertEqual(record.latestRunId, "persisted-run")
        XCTAssertEqual(record.title, "Historical research goal")
        XCTAssertEqual(record.status, .running)
        XCTAssertEqual(record.output, .string("Original result"), "Inspecting must not replace the run result")
        XCTAssertEqual(record.inspection?.objectValue?["run"]?.objectValue?["id"], .string("persisted-run"))
        let tabID = try XCTUnwrap(model.selectedTabID)
        XCTAssertEqual(model.selectedTab?.detailMode, .inspection)
        model.setDetailMode(.results, forTab: tabID)
        XCTAssertEqual(model.selectedTab?.detailMode, .results)
        XCTAssertEqual(model.selectedRunItemID, recordID)
        model.runCommand(
            "run/inspect",
            runId: "persisted-run",
            displayTitle: "Updated historical title"
        )
        XCTAssertEqual(model.runs.first?.title, "Updated historical title")
        model.runCommand("run/inspect", for: recordID)
        XCTAssertEqual(model.selectedTab?.detailMode, .inspection)
        try? await Task.sleep(for: .milliseconds(50))

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let runtimeInitialization = try XCTUnwrap(requests.first {
            $0.objectValue?["method"] == .string("runtime/initialize")
        })
        let initializationParams = try XCTUnwrap(runtimeInitialization.objectValue?["params"]?.objectValue)
        XCTAssertEqual(initializationParams["approvalMode"], .string("manual"))
        XCTAssertEqual(initializationParams["clarificationMode"], .string("interactive"))
        XCTAssertNil(initializationParams["runtimeMode"])
        XCTAssertNil(initializationParams["provider"])
        XCTAssertNil(initializationParams["model"])
        let inspectionRequests = requests.filter {
            $0.objectValue?["method"] == .string("run/inspect")
        }
        XCTAssertEqual(inspectionRequests.count, 1, "Reopening a recent unchanged inspection should use its cached snapshot")
        let inspection = try XCTUnwrap(inspectionRequests.first)
        XCTAssertEqual(inspection.objectValue?["params"]?.objectValue?["runId"], .string("persisted-run"))
        await model.shutdown()
    }

    @MainActor
    func testInspectionDiagnosticsSummarizeInsteadOfDuplicatingTheFullEventHistory() throws {
        let model = AppModel(workingDirectoryURL: try temporaryDirectoryURL())
        let recordID = UUID()
        model.runs = [AppModel.RunRecord(
            id: recordID,
            kind: .run,
            title: "Large inspection",
            runIds: ["root-run"]
        )]
        let largePayload = String(repeating: "x", count: 128 * 1024)
        let inspection: JSONValue = .object([
            "run": .object([
                "id": .string("root-run"),
                "status": .string("running"),
                "version": .number(42)
            ]),
            "events": .array([
                .object([
                    "seq": .number(1),
                    "type": .string("tool.completed"),
                    "runId": .string("root-run"),
                    "toolCallId": .string("search-call"),
                    "payload": .object([
                        "toolName": .string("web_search"),
                        "input": .object(["query": .string("compact progress UI")]),
                        "output": .string(largePayload)
                    ])
                ])
            ])
        ])

        try model.acceptRunCommandResult(inspection, method: "run/inspect", for: recordID)

        XCTAssertEqual(model.runs[0].inspection, inspection, "The complete snapshot should remain available to the inspection view")
        let diagnostic = try XCTUnwrap(model.events.last)
        XCTAssertLessThan(diagnostic.utf8.count, 1_024)
        XCTAssertTrue(diagnostic.contains("runId: root-run"))
        XCTAssertTrue(diagnostic.contains("version: 42"))
        XCTAssertTrue(diagnostic.contains("events: 1"))
        XCTAssertFalse(diagnostic.contains(largePayload))
        XCTAssertEqual(model.runs[0].activities.first?.toolName, "web_search")
        XCTAssertEqual(model.runs[0].activities.first?.detail, "compact progress UI")
        XCTAssertEqual(model.runs[0].activities.first?.toolState, .succeeded)
    }

    @MainActor
    func testInspectionReconstructsRelatedFilesForHistoricalRuns() throws {
        let workspace = try temporaryDirectoryURL()
        let generatedFile = workspace.appendingPathComponent("Reports/generated.md")
        let editedFile = workspace.appendingPathComponent("Sources/Existing.swift")
        let model = AppModel(workingDirectoryURL: workspace)
        model.effectiveWorkspaceRoot = workspace.path
        let recordID = UUID()
        model.runs = [AppModel.RunRecord(
            id: recordID,
            kind: .run,
            title: "Historical run",
            runIds: ["root-run"]
        )]

        let inspection: JSONValue = .object([
            "run": .object([
                "id": .string("root-run"),
                "status": .string("succeeded")
            ]),
            "events": .array([
                toolCompletedEvent(
                    runId: "root-run",
                    toolName: "write_file",
                    output: ["path": .string(generatedFile.path), "sizeBytes": .number(42)]
                ),
                toolCompletedEvent(
                    runId: "child-run",
                    toolName: "edit_file",
                    output: ["path": .string(editedFile.path), "changed": .bool(true)]
                )
            ])
        ])

        try model.acceptRunCommandResult(
            inspection,
            method: "run/inspect",
            for: recordID,
            requestedRunId: "root-run"
        )

        XCTAssertEqual(model.runs[0].files.map(\.path), [generatedFile.path, editedFile.path].sorted())
        XCTAssertEqual(model.runs[0].files.first { $0.path == generatedFile.path }?.operation, .written)
        XCTAssertEqual(model.runs[0].files.first { $0.path == editedFile.path }?.operation, .edited)
        XCTAssertEqual(model.runs[0].files.first { $0.path == editedFile.path }?.sourceRunId, "child-run")
    }

    @MainActor
    func testAgentEventsBuildCompactActivityFeedAndUpdateToolsInPlace() throws {
        let model = AppModel(workingDirectoryURL: try temporaryDirectoryURL())
        let recordID = UUID()
        model.runs = [AppModel.RunRecord(id: recordID, kind: .run, title: "Research")]
        model.acceptResult(.object(["runId": .string("root-run")]), for: recordID)
        model.receive(method: "agent/event", params: .object([
            "type": .string("run.started"),
            "runId": .string("root-run"),
            "payload": .object(["rootRunId": .string("root-run")])
        ]))

        let assistantContent = "I’ll check the documentation and then inspect the local file."
        model.receive(method: "agent/event", params: .object([
            "id": .string("event-1"),
            "type": .string("tool.started"),
            "runId": .string("root-run"),
            "stepId": .string("step-1"),
            "toolCallId": .string("search-call"),
            "payload": .object([
                "toolName": .string("web_search"),
                "assistantContent": .string(assistantContent),
                "input": .object(["query": .string("SwiftUI TimelineView macOS")])
            ])
        ]))

        XCTAssertEqual(model.runs[0].activities.count, 2)
        XCTAssertEqual(model.runs[0].activities[0].content, assistantContent)
        XCTAssertEqual(model.runs[0].activities[1].toolName, "web_search")
        XCTAssertEqual(model.runs[0].activities[1].detail, "SwiftUI TimelineView macOS")
        XCTAssertEqual(model.runs[0].activities[1].toolState, .running)

        model.receive(method: "agent/event", params: .object([
            "id": .string("event-2"),
            "type": .string("tool.completed"),
            "runId": .string("root-run"),
            "stepId": .string("step-1"),
            "toolCallId": .string("search-call"),
            "payload": .object([
                "toolName": .string("web_search"),
                "assistantContent": .string(assistantContent),
                "output": .object(["resultCount": .number(4)])
            ])
        ]))
        model.receive(method: "agent/event", params: .object([
            "id": .string("event-3"),
            "type": .string("tool.completed"),
            "runId": .string("root-run"),
            "stepId": .string("step-1"),
            "toolCallId": .string("page-call"),
            "payload": .object([
                "toolName": .string("read_web_page"),
                "assistantContent": .string(assistantContent),
                "input": .object([
                    "type": .string("object"),
                    "keyCount": .number(1),
                    "preview": .object(["url": .string("https://www.example.com/reference/page")])
                ]),
                "output": .object(["title": .string("Reference")])
            ])
        ]))
        model.receive(method: "agent/event", params: .object([
            "id": .string("event-4"),
            "type": .string("tool.failed"),
            "runId": .string("root-run"),
            "stepId": .string("step-2"),
            "toolCallId": .string("file-call"),
            "payload": .object([
                "toolName": .string("read_file"),
                "input": .object(["path": .string("/workspace/Sources/AppModel.swift")]),
                "error": .string("Not found")
            ])
        ]))
        model.receive(method: "agent/event", params: .object([
            "id": .string("event-5"),
            "type": .string("tool.completed"),
            "runId": .string("root-run"),
            "stepId": .string("step-3"),
            "toolCallId": .string("write-call"),
            "payload": .object([
                "toolName": .string("write_file"),
                "input": .object([
                    "type": .string("object"),
                    "keyCount": .number(2),
                    "preview": .object([
                        "path": .string("/workspace/docs/agent-runtime-jsonrpc.md"),
                        "content": .object([
                            "type": .string("string"),
                            "length": .number(1_024),
                            "preview": .string("# Runtime protocol")
                        ])
                    ])
                ]),
                "output": .string("Written")
            ])
        ]))

        XCTAssertEqual(model.runs[0].activities.filter { $0.kind == .assistant }.count, 1)
        XCTAssertEqual(model.runs[0].activities.first { $0.id == "tool:search-call" }?.toolState, .succeeded)
        XCTAssertEqual(model.runs[0].activities.first { $0.id == "tool:search-call" }?.detail, "SwiftUI TimelineView macOS")
        XCTAssertEqual(model.runs[0].activities.first { $0.id == "tool:page-call" }?.detail, "example.com")
        XCTAssertEqual(model.runs[0].activities.first { $0.id == "tool:file-call" }?.detail, "AppModel.swift")
        XCTAssertEqual(model.runs[0].activities.first { $0.id == "tool:file-call" }?.toolState, .failed)
        XCTAssertEqual(model.runs[0].activities.first { $0.id == "tool:write-call" }?.detail, "agent-runtime-jsonrpc.md")

        model.receive(method: "agent/event", params: .object([
            "type": .string("run.completed"),
            "runId": .string("root-run"),
            "payload": .object([
                "rootRunId": .string("root-run"),
                "output": .string("Finished the research.")
            ])
        ]))

        XCTAssertEqual(model.runs[0].status, .succeeded)
        XCTAssertNotNil(model.runs[0].activityStartedAt)
        XCTAssertNotNil(model.runs[0].activityFinishedAt)
        XCTAssertEqual(model.runs[0].activities.last?.content, "Finished the research.")
        XCTAssertEqual(model.runs[0].activities.last?.isFinalAssistantMessage, true)
    }

    @MainActor
    func testRunResultApprovalEventsAndStructuredWrittenFilesArePresented() throws {
        let workspace = try temporaryDirectoryURL()
        let sourceDirectory = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let writtenFile = sourceDirectory.appendingPathComponent("Generated.swift")
        let editedFile = sourceDirectory.appendingPathComponent("Existing.swift")
        try "generated".write(to: writtenFile, atomically: true, encoding: .utf8)
        try "edited".write(to: editedFile, atomically: true, encoding: .utf8)

        let model = AppModel(workingDirectoryURL: workspace)
        model.effectiveWorkspaceRoot = workspace.path
        let recordID = UUID()
        model.runs = [AppModel.RunRecord(id: recordID, kind: .run, title: "Generate files")]
        model.acceptResult(.object([
            "status": .string("success"),
            "runId": .string("root-run"),
            "output": .string("# Done\n\nGenerated the requested files.")
        ]), for: recordID)

        XCTAssertEqual(model.runs[0].status, .succeeded)
        XCTAssertEqual(model.runs[0].output, .string("# Done\n\nGenerated the requested files."))

        model.receive(method: "agent/event", params: .object([
            "schemaVersion": .number(1),
            "type": .string("delegate.spawned"),
            "runId": .string("root-run"),
            "payload": .object(["childRunId": .string("child-run"), "rootRunId": .string("root-run")])
        ]))
        model.receive(method: "agent/event", params: .object([
            "schemaVersion": .number(1),
            "type": .string("approval.requested"),
            "runId": .string("child-run"),
            "payload": .object([
                "approvalId": .string("approval-child-run"),
                "toolName": .string("shell_exec"),
                "input": .object(["command": .string("git status")])
            ])
        ]))
        XCTAssertEqual(model.runs[0].status, .waitingForApproval)
        guard case .approval(let toolName, let input, _) = model.runs[0].interaction?.kind else {
            return XCTFail("approval.requested should create an approval interaction")
        }
        XCTAssertEqual(toolName, "shell_exec")
        XCTAssertEqual(input?.objectValue?["command"], .string("git status"))
        XCTAssertEqual(model.runs[0].interaction?.runId, "child-run")
        XCTAssertEqual(model.runs[0].interaction?.approvalId, "approval-child-run")

        model.acceptResult(.object([
            "status": .string("approval_requested"),
            "runId": .string("root-run"),
            "message": .string("Approval required")
        ]), for: recordID)
        XCTAssertEqual(model.runs[0].interaction?.runId, "child-run", "the paused root response must not replace the requesting child run")
        model.runs[0].interaction?.isResolving = true
        model.acceptResult(.object(["runId": .string("child-run"), "approved": .bool(true)]), for: recordID)
        XCTAssertNil(model.runs[0].interaction)
        XCTAssertEqual(model.runs[0].status, .running)
        XCTAssertEqual(model.runs[0].latestRunId, "root-run")

        model.receive(method: "agent/event", params: toolCompletedEvent(
            runId: "root-run",
            toolName: "write_file",
            output: ["path": .string(writtenFile.path), "sizeBytes": .number(9)]
        ))
        model.receive(method: "agent/event", params: toolCompletedEvent(
            runId: "child-run",
            toolName: "edit_file",
            output: ["path": .string(editedFile.path), "changed": .bool(true)]
        ))
        model.receive(method: "agent/event", params: toolCompletedEvent(
            runId: "root-run",
            toolName: "edit_file",
            output: ["path": .string(writtenFile.path), "changed": .bool(false)]
        ))
        model.receive(method: "agent/event", params: toolCompletedEvent(
            runId: "root-run",
            toolName: "write_file",
            output: ["path": .string(workspace.deletingLastPathComponent().appendingPathComponent("outside.txt").path)]
        ))

        XCTAssertEqual(model.runs[0].files.count, 2)
        XCTAssertEqual(model.runs[0].files.map(\.path), [writtenFile.path, editedFile.path].sorted())
        let childFile = try XCTUnwrap(model.runs[0].files.first { $0.path == editedFile.path })
        XCTAssertEqual(childFile.operation, .edited)
        XCTAssertEqual(childFile.sourceRunId, "child-run")
        XCTAssertEqual(model.relativeDisplayPath(for: childFile), "Sources/Existing.swift")
        XCTAssertTrue(model.fileExists(childFile))
    }

    @MainActor
    func testChildTerminalEventsDoNotTerminateTheRootRecord() throws {
        let model = AppModel(workingDirectoryURL: try temporaryDirectoryURL())
        let recordID = UUID()
        model.runs = [AppModel.RunRecord(id: recordID, kind: .run, title: "Delegating")]
        model.acceptResult(.object(["runId": .string("root-run")]), for: recordID)
        model.runs[0].status = .running
        model.runs[0].isRequestInFlight = true
        model.runs[0].output = .string("Root output")
        model.runs[0].interaction = AppModel.Interaction(
            runId: "root-run",
            message: "Root question",
            kind: .clarification(suggestedQuestions: [])
        )

        model.receive(method: "agent/event", params: .object([
            "type": .string("delegate.spawned"),
            "runId": .string("root-run"),
            "payload": .object([
                "childRunId": .string("child-run"),
                "rootRunId": .string("root-run")
            ])
        ]))
        for (type, payload) in [
            ("run.completed", JSONValue.object(["rootRunId": .string("root-run"), "output": .string("Child output")])),
            ("run.failed", JSONValue.object(["rootRunId": .string("root-run"), "error": .string("Child failed")])),
            ("run.status_changed", JSONValue.object(["rootRunId": .string("root-run"), "toStatus": .string("failed")]))
        ] {
            model.receive(method: "agent/event", params: .object([
                "type": .string(type),
                "runId": .string("child-run"),
                "payload": payload
            ]))
        }

        XCTAssertEqual(model.runs[0].status, .running)
        XCTAssertTrue(model.runs[0].isRequestInFlight)
        XCTAssertEqual(model.runs[0].output, .string("Root output"))
        XCTAssertEqual(model.runs[0].interaction?.message, "Root question")
        XCTAssertFalse(
            model.runs[0].activities.contains(where: { $0.isFinalAssistantMessage }),
            "A child result must not be presented as the root assistant's final answer"
        )
    }

    @MainActor
    func testApprovalRejectionAppliesNestedFailedRun() throws {
        let model = AppModel(workingDirectoryURL: try temporaryDirectoryURL())
        let recordID = UUID()
        var interaction = AppModel.Interaction(
            runId: "root-run",
            message: "Approve tool?",
            kind: .approval(toolName: "shell_exec", input: nil, assistantContent: nil)
        )
        interaction.isResolving = true
        model.runs = [AppModel.RunRecord(
            id: recordID,
            kind: .run,
            title: "Rejected run",
            runIds: ["root-run"],
            status: .waitingForApproval,
            interaction: interaction,
            isRequestInFlight: true
        )]

        model.acceptApprovalResolution(.object([
            "run": .object([
                "id": .string("root-run"),
                "status": .string("failed"),
                "errorMessage": .string("Approval rejected for shell_exec")
            ]),
            "events": .array([])
        ]), approved: false, for: recordID)

        XCTAssertEqual(model.runs[0].status, .failed)
        XCTAssertFalse(model.runs[0].isRequestInFlight)
        XCTAssertNil(model.runs[0].interaction)
        XCTAssertEqual(model.runs[0].errorMessage, "Approval rejected for shell_exec")
    }

    @MainActor
    func testRecoveryAndAuxiliaryCommandsPreserveIndependentLifecycleState() throws {
        let model = AppModel(workingDirectoryURL: try temporaryDirectoryURL())
        let recordID = UUID()
        model.runs = [AppModel.RunRecord(
            id: recordID,
            kind: .run,
            title: "Recovering run",
            runIds: ["root-run"],
            status: .running,
            isRequestInFlight: true,
            auxiliaryOperations: [.inspect, .steer]
        )]

        try model.acceptRunCommandResult(.object([
            "run": .object(["id": .string("root-run"), "status": .string("running")]),
            "events": .array([])
        ]), method: "run/inspect", for: recordID)
        model.acceptSteeringResult(.object([
            "runId": .string("root-run"),
            "accepted": .bool(true)
        ]), for: recordID)
        XCTAssertTrue(model.runs[0].isRequestInFlight)
        XCTAssertEqual(model.runs[0].status, .running)
        XCTAssertTrue(model.runs[0].auxiliaryOperations.isEmpty)

        model.runs[0].auxiliaryOperations.insert(.steer)
        model.auxiliaryRequestFailed(
            RuntimeClientError.remote(code: -32602, protocolCode: "INVALID_PARAMS", message: "Cannot steer"),
            operation: .steer,
            for: recordID
        )
        XCTAssertEqual(model.runs[0].status, .running)
        XCTAssertTrue(model.runs[0].isRequestInFlight)
        XCTAssertEqual(model.runs[0].auxiliaryErrorMessage, "INVALID_PARAMS: Cannot steer")

        try model.acceptRunCommandResult(.object([
            "runId": .string("root-run"),
            "action": .string("retry_same_run"),
            "plan": .object([:]),
            "result": .object([
                "status": .string("success"),
                "runId": .string("recovered-run"),
                "output": .string("Recovered")
            ])
        ]), method: "run/recover", for: recordID)
        XCTAssertEqual(model.runs[0].status, .succeeded)
        XCTAssertEqual(model.runs[0].latestRunId, "recovered-run")
        XCTAssertEqual(model.runs[0].output, .string("Recovered"))
        XCTAssertFalse(model.runs[0].isRequestInFlight)

        model.runs[0].auxiliaryOperations.insert(.interrupt)
        try model.acceptRunCommandResult(.object([
            "runId": .string("recovered-run"),
            "interrupted": .bool(true)
        ]), method: "run/interrupt", for: recordID)
        XCTAssertEqual(model.runs[0].status, .succeeded, "A no-op interrupt must preserve terminal status")
    }

    func testRuntimeProcessUsesSuppliedWorkingDirectory() async throws {
        let workspace = try temporaryDirectoryURL()
        let pwdLog = temporaryFileURL(named: "pwd.txt")
        let executable = try makeRuntimeScript(#"""
pwd > \#(shellQuote(pwdLog.path))
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        try await client.start(workingDirectoryURL: workspace, notificationHandler: { _, _ in }, errorHandler: { _ in })
        _ = try await client.initializeRuntime()
        await client.shutdown()
        let reportedPath = try String(contentsOf: pwdLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: reportedPath).resolvingSymlinksInPath().path,
            workspace.resolvingSymlinksInPath().path
        )
    }

    func testLongRunningAgentRequestCanDisableTheStandardResponseTimeout() async throws {
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id" ;;
    agent/run) sleep 0.15; printf '{"jsonrpc":"2.0","id":"%s","result":{"status":"success","runId":"slow-run","output":"Done"}}\n' "$id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .milliseconds(30))
        try await client.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
        _ = try await client.initializeRuntime()
        let result = try await client.send(
            method: "agent/run",
            params: ["goal": .string("Wait")],
            timeoutPolicy: .none
        )
        XCTAssertEqual(result.objectValue?["runId"], .string("slow-run"))
        await client.shutdown()
    }

    func testProtocol117AuthUpdateAndRuntimeInfoUseTypedTransport() async throws {
        let requestLog = temporaryFileURL(named: "auth-info-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    auth/updateAccessToken) printf '{"jsonrpc":"2.0","id":"%s","result":{"updated":true}}\n' "$id" ;;
    runtime/info) printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","initialized":true,"clientInfo":{"name":"adaptive-agent-desktop","version":"1.0.2"},"runtimeMode":"memory","agentId":"default","workspaceRoot":"/workspace","inferenceMode":"gateway","inferenceTier":"medium","connections":{"sqlite":{"configured":false,"state":"not_configured"},"gateway":{"configured":true,"state":"connected"}}}}\n' "$id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        try await client.start(notificationHandler: { _, _ in }, errorHandler: { _ in })

        let tokenUpdate = try await client.updateAccessToken("secret-access-token")
        XCTAssertEqual(tokenUpdate, .init(updated: true))
        let info = try await client.runtimeInfo()
        XCTAssertEqual(info.protocolVersion, "1.17")
        XCTAssertTrue(info.initialized)
        XCTAssertEqual(info.inferenceMode, "gateway")
        XCTAssertEqual(info.inferenceTier, "medium")
        XCTAssertEqual(info.connections?.gateway?.state, "connected")

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let authRequest = try XCTUnwrap(requests.first {
            $0.objectValue?["method"] == .string("auth/updateAccessToken")
        })
        XCTAssertEqual(authRequest.objectValue?["jsonrpc"], .string("2.0"))
        XCTAssertNotNil(authRequest.objectValue?["id"])
        XCTAssertEqual(
            authRequest.objectValue?["params"]?.objectValue?["accessToken"],
            .string("secret-access-token")
        )
        await client.shutdown()
    }

    func testProtocol117RunDeletionUsesTypedTransportAndRequiresRuntimeInitialization() async throws {
        let requestLog = temporaryFileURL(named: "run-delete-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id" ;;
    run/delete) printf '{"jsonrpc":"2.0","id":"%s","result":{"deleted":true,"rootRunId":"root-run"}}\n' "$id" ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        try await client.start(notificationHandler: { _, _ in }, errorHandler: { _ in })

        do {
            _ = try await client.deleteRun("root-run")
            XCTFail("Deletion must require runtime initialization")
        } catch let error as RuntimeClientError {
            XCTAssertEqual(error, .notInitialized("Agent runtime"))
        }

        _ = try await client.initializeRuntime()
        let result = try await client.deleteRun("  root-run  ")
        XCTAssertEqual(result, .init(deleted: true, rootRunId: "root-run"))

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let deletion = try XCTUnwrap(requests.first {
            $0.objectValue?["method"] == .string("run/delete")
        })
        XCTAssertEqual(deletion.objectValue?["jsonrpc"], .string("2.0"))
        XCTAssertNotNil(deletion.objectValue?["id"])
        XCTAssertEqual(deletion.objectValue?["params"]?.objectValue?["runId"], .string("root-run"))
        await client.shutdown()
    }

    @MainActor
    func testDeletingMultipleRunsCleansSuccessfulRunStateAndReportsPartialFailure() async throws {
        let workspace = try temporaryDirectoryURL()
        let requestLog = temporaryFileURL(named: "app-run-delete-requests.log")
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(requestLog.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{"agent":{"id":"default","name":"Default Agent"},"runtimeMode":"memory","workspaceRoot":"%s","shellCwd":"%s","registeredToolNames":[]}}\n' "$id" \#(shellQuote(workspace.path)) \#(shellQuote(workspace.path)) ;;
    runtime/info) printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","initialized":true,"clientInfo":{"name":"adaptive-agent-desktop"},"runtimeMode":"memory","agentId":"default","workspaceRoot":"%s"}}\n' "$id" \#(shellQuote(workspace.path)) ;;
    run/delete)
      case "$line" in
        *root-a*) printf '{"jsonrpc":"2.0","id":"%s","result":{"deleted":true,"rootRunId":"root-a"}}\n' "$id" ;;
        *) printf '{"jsonrpc":"2.0","id":"%s","error":{"code":-32000,"message":"Run is not terminal","data":{"protocolCode":"RUN_NOT_TERMINAL"}}}\n' "$id" ;;
      esac
      ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let model = AppModel(
            client: RuntimeClient(executableURL: executable, responseTimeout: .seconds(2)),
            workingDirectoryURL: workspace
        )
        model.bootstrap()
        for _ in 0..<100 where !model.isConnected {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isConnected, model.status)

        let deletedRecordID = UUID()
        let retainedRecordID = UUID()
        model.runs = [
            .init(id: deletedRecordID, kind: .run, title: "Delete me", runIds: ["root-a"], status: .succeeded),
            .init(id: retainedRecordID, kind: .run, title: "Keep me", runIds: ["root-b"], status: .failed)
        ]
        model.openRunTab(deletedRecordID)
        model.openRunTab(retainedRecordID)

        model.deleteRuns(rootRunIDs: ["root-a", "root-b"])
        for _ in 0..<100 where !model.deletingRunIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(model.runs.first(where: { $0.id == deletedRecordID }))
        XCTAssertNotNil(model.runs.first(where: { $0.id == retainedRecordID }))
        XCTAssertNil(model.tabs.first(where: { $0.selectedRunID == deletedRecordID }))
        XCTAssertNotNil(model.tabs.first(where: { $0.selectedRunID == retainedRecordID }))
        XCTAssertTrue(model.runDeletionError?.contains("RUN_NOT_TERMINAL") == true)

        let requests = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let deletedRunIDs = Set(requests.compactMap { request -> String? in
            guard request.objectValue?["method"] == .string("run/delete") else { return nil }
            return request.objectValue?["params"]?.objectValue?["runId"]?.stringValue
        })
        XCTAssertEqual(deletedRunIDs, ["root-a", "root-b"])
        await model.shutdown()
    }

    func testProtocolDiagnosticsRedactTokensRecursively() {
        let value: JSONValue = .object([
            "accessToken": .string("top-secret"),
            "nested": .object([
                "authorization": .string("Bearer nested-secret"),
                "api_key": .string("provider-secret"),
                "safe": .string("visible")
            ])
        ])
        let redacted = ProtocolRedactor.redact(value)
        XCTAssertEqual(redacted.objectValue?["accessToken"], .string("<redacted>"))
        XCTAssertEqual(redacted.objectValue?["nested"]?.objectValue?["authorization"], .string("<redacted>"))
        XCTAssertEqual(redacted.objectValue?["nested"]?.objectValue?["api_key"], .string("<redacted>"))
        XCTAssertEqual(redacted.objectValue?["nested"]?.objectValue?["safe"], .string("visible"))

        let text = ProtocolRedactor.redact("Authorization: Bearer text-secret access_token=another-secret")
        XCTAssertFalse(text.contains("text-secret"))
        XCTAssertFalse(text.contains("another-secret"))
    }

    func testHandshakeRuntimeGateNotificationsErrorsAndGracefulShutdown() async throws {
        let logURL = temporaryFileURL(named: "requests.log")
        let shutdownURL = temporaryFileURL(named: "shutdown.txt")
        let executable = try makeRuntimeScript(#"""
printf '%s' '{"jsonrpc":"2.0","method":"runtime/'
sleep 0.05
printf '%s\n' 'ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  printf '%s\n' "$line" >> \#(shellQuote(logURL.path))
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize)
      printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","capabilities":{}}}'
      ;;
    runtime/initialize)
      printf '{"jsonrpc":"2.0","id":"%s","result":{"runtimeMode":"postgres"}}\n' "$id"
      printf '%s\n' '{"jsonrpc":"2.0","method":"agent/event","params":{"schemaVersion":1,"type":"run.started","runId":"run-1"}}'
      sleep 0.02
      printf '%s\n' '{"jsonrpc":"2.0","method":"cli/output","params":{"requestId":"cli-1","stream":"stdout","line":"ok"}}'
      ;;
    agent/run)
      printf '{"jsonrpc":"2.0","id":"%s","result":{"runId":"run-1"}}\n' "$id"
      ;;
    interaction/resolveApproval)
      printf '{"jsonrpc":"2.0","id":"%s","result":{"runId":"run-1","approved":true}}\n' "$id"
      ;;
    runtime/info)
      printf '{"jsonrpc":"2.0","id":"%s","error":{"code":-32602,"message":"No info","data":{"protocolCode":"INVALID_PARAMS"}}}\n' "$id"
      ;;
    runtime/shutdown)
      printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"
      if IFS= read -r extra; then
        printf '%s' 'stdin-still-open-with-data' > \#(shellQuote(shutdownURL.path))
      else
        printf '%s' 'response-before-eof' > \#(shellQuote(shutdownURL.path))
      fi
      exit 0
      ;;
    *) exit 91 ;;
  esac
done
"""#)
        let recorder = NotificationRecorder()
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        do {
            try await client.start(notificationHandler: { method, params in
                if method == "agent/event" { try? await Task.sleep(for: .milliseconds(50)) }
                await recorder.append(method: method, params: params)
            }, errorHandler: { _ in })
        } catch {
            return XCTFail("protocol startup failed: \(error)")
        }

        let firstRequest = try XCTUnwrap(try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").first)
        let initialize = try JSONDecoder().decode(JSONValue.self, from: Data(firstRequest.utf8))
        XCTAssertEqual(initialize.objectValue?["jsonrpc"], .string("2.0"))
        XCTAssertEqual(initialize.objectValue?["id"], .string("initialize"))
        XCTAssertEqual(initialize.objectValue?["method"], .string("initialize"))
        XCTAssertEqual(initialize.objectValue?["params"]?.objectValue?["protocolVersion"], .string("1.17"))

        do {
            _ = try await client.send(method: "agent/run", params: ["runId": .string("early-run"), "goal": .string("too early")])
            XCTFail("agent/run must be gated until runtime/initialize succeeds")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .notInitialized("Agent runtime"))
        }
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").count, 1)

        let initialized: JSONValue
        do {
            initialized = try await client.initializeRuntime(params: ["runtimeMode": .string("postgres")])
        } catch {
            await client.shutdown()
            return XCTFail("runtime/initialize failed: \(error)")
        }
        XCTAssertEqual(initialized.objectValue?["runtimeMode"], .string("postgres"))
        let notifications = await waitForNotifications(recorder, count: 2)
        XCTAssertEqual(notifications.map(\.method), ["agent/event", "cli/output"])

        let run: JSONValue
        do {
            run = try await client.send(method: "agent/run", params: ["runId": .string("run-1"), "goal": .string("Ship it")])
        } catch {
            await client.shutdown()
            return XCTFail("agent/run failed: \(error)")
        }
        XCTAssertEqual(run.objectValue?["runId"], .string("run-1"))
        do {
            _ = try await client.send(method: "runtime/info")
            XCTFail("runtime/info should return its JSON-RPC error")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .remote(code: -32602, protocolCode: "INVALID_PARAMS", message: "No info"))
        }

        let approval = try await client.send(
            method: "interaction/resolveApproval",
            params: [
                "runId": .string("run-1"),
                "approvalId": .string("approval-1"),
                "approved": .bool(true)
            ]
        )
        XCTAssertEqual(approval.objectValue?["approved"], .bool(true))
        let approvalRequest = try XCTUnwrap(
            try String(contentsOf: logURL, encoding: .utf8)
                .split(separator: "\n")
                .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                .first { $0.objectValue?["method"] == .string("interaction/resolveApproval") }
        )
        XCTAssertEqual(approvalRequest.objectValue?["jsonrpc"], .string("2.0"))
        XCTAssertNotNil(approvalRequest.objectValue?["id"])
        XCTAssertEqual(approvalRequest.objectValue?["params"]?.objectValue?["runId"], .string("run-1"))
        XCTAssertEqual(approvalRequest.objectValue?["params"]?.objectValue?["approvalId"], .string("approval-1"))
        XCTAssertEqual(approvalRequest.objectValue?["params"]?.objectValue?["approved"], .bool(true))

        await client.shutdown()
        XCTAssertEqual(try String(contentsOf: shutdownURL, encoding: .utf8), "response-before-eof")
    }

    func testOutOfOrderResponsesAreCorrelatedByID() async throws {
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}'
IFS= read -r line
id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"
IFS= read -r first
IFS= read -r second
first_id="$(printf '%s' "$first" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
second_id="$(printf '%s' "$second" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
case "$first" in *'"runId":"first"'*) first_label=first ;; *) first_label=second ;; esac
case "$second" in *'"runId":"first"'*) second_label=first ;; *) second_label=second ;; esac
printf '{"jsonrpc":"2.0","id":"%s","result":{"label":"%s"}}\n' "$second_id" "$second_label"
printf '{"jsonrpc":"2.0","id":"%s","result":{"label":"%s"}}\n' "$first_id" "$first_label"
IFS= read -r line
id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        try await client.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
        _ = try await client.initializeRuntime()

        async let first = client.send(method: "run/inspect", params: ["runId": .string("first")])
        async let second = client.send(method: "run/inspect", params: ["runId": .string("second")])
        let (firstResult, secondResult) = try await (first, second)
        XCTAssertEqual(firstResult.objectValue?["label"], .string("first"))
        XCTAssertEqual(secondResult.objectValue?["label"], .string("second"))
        await client.shutdown()
    }

    func testSlowNotificationHandlerDoesNotDelayFollowingResponse() async throws {
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do
  id="$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
  method="$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\1/' | tr -d '\\')"
  case "$method" in
    initialize) printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}' ;;
    runtime/initialize) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id" ;;
    runtime/info)
      printf '%s\n' '{"jsonrpc":"2.0","method":"agent/event","params":{"schemaVersion":1,"type":"run.started","runId":"run-1"}}'
      printf '{"jsonrpc":"2.0","id":"%s","result":{"ready":true}}\n' "$id"
      ;;
    runtime/shutdown) printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"; exit 0 ;;
    *) exit 91 ;;
  esac
done
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .milliseconds(50))
        try await client.start(notificationHandler: { _, _ in
            try? await Task.sleep(for: .milliseconds(200))
        }, errorHandler: { _ in })
        _ = try await client.initializeRuntime()
        let result = try await client.send(method: "runtime/info")
        XCTAssertEqual(result.objectValue?["ready"], .bool(true))
        await client.shutdown()
    }

    func testUnsupportedAndLegacyStartupNeverFallBack() async throws {
        let requestLog = temporaryFileURL(named: "unsupported-requests.log")
        let unsupported = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.11","bridgeVersion":"0.1.0","pid":123}}'
while IFS= read -r line; do printf '%s\n' "$line" >> \#(shellQuote(requestLog.path)); done
"""#)
        let unsupportedClient = RuntimeClient(executableURL: unsupported, readyTimeout: .seconds(1))
        do {
            try await unsupportedClient.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
            XCTFail("unsupported protocol should fail startup")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .incompatibleRuntime("1.11"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestLog.path))

        let legacy = try makeRuntimeScript(#"""
printf '%s\n' '{"version":1,"type":"runtime.ready","protocolVersion":1,"bridgeVersion":"0.1.0","pid":123}'
sleep 5
"""#)
        let legacyClient = RuntimeClient(executableURL: legacy, readyTimeout: .seconds(1))
        do {
            try await legacyClient.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
            XCTFail("legacy startup should fail")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .incompatibleRuntime(nil))
        }
    }

    func testLegacyOperationalMessageIsRejected() async throws {
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}'
IFS= read -r line
printf '%s\n' '{"version":1,"id":"old","type":"response","ok":true,"result":{}}'
sleep 5
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        let terminations = TerminationRecorder()
        try await client.start(
            notificationHandler: { _, _ in },
            errorHandler: { _ in },
            terminationHandler: { status in await terminations.append(status) }
        )
        do {
            _ = try await client.send(method: "runtime/info")
            XCTFail("legacy operational response should fail")
        } catch {
            guard case .protocolViolation = error as? RuntimeClientError else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        for _ in 0..<50 {
            if !(await terminations.values).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let terminationValues = await terminations.values
        XCTAssertFalse(terminationValues.isEmpty, "post-initialization protocol failure must notify the app that the runtime stopped")
        await client.shutdown()
    }

    func testUnexpectedRuntimeTerminationFailsPendingRequest() async throws {
        let executable = try makeRuntimeScript(#"""
printf '%s\n' '{"jsonrpc":"2.0","method":"runtime/ready","params":{"protocolVersion":"1.17","bridgeVersion":"0.1.0","pid":123}}'
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.17"}}'
IFS= read -r line
exit 7
"""#)
        let client = RuntimeClient(executableURL: executable, responseTimeout: .seconds(2))
        try await client.start(notificationHandler: { _, _ in }, errorHandler: { _ in })
        do {
            _ = try await client.send(method: "runtime/info")
            XCTFail("request should fail when the runtime exits")
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .terminated(7))
        }
        await client.shutdown()
    }

    func testTraceSessionClientNegotiatesListsLoadsAndShutsDown() async throws {
        let executable = try makeTraceScript(#"""
IFS= read -r line
printf '%s\n' "$line" | grep -q '"protocolVersion":"1.0"'
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.0","backend":{"kind":"sqlite","readOnly":true}}}'
IFS= read -r line
id="$(printf '%s\n' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
printf '{"jsonrpc":"2.0","id":"%s","result":[{"sessionId":"session-1","startedAt":"2026-08-28T10:00:00.000Z","status":"succeeded","goals":[{"rootRunId":"run-1","runId":"run-1","status":"succeeded","startedAt":"2026-08-28T10:00:00.000Z","completedAt":"2026-08-28T10:01:00.000Z","goal":"Research AI news","linkedAt":"2026-08-28T10:00:00.000Z","type":"run"}]}]}\n' "$id"
IFS= read -r line
id="$(printf '%s\n' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
printf '{"jsonrpc":"2.0","id":"%s","result":{"target":{"kind":"root-run","requestedId":"run-1","resolvedRootRunId":"run-1"},"session":null,"rootRuns":[{"rootRunId":"run-1","runId":"run-1","invocationKind":"run","linkedAt":"2026-08-28T10:00:00.000Z","startedAt":"2026-08-28T10:00:00.000Z","updatedAt":"2026-08-28T10:01:00.000Z","completedAt":"2026-08-28T10:01:00.000Z","status":"succeeded","goal":"Research AI news","modelProvider":"openrouter","modelName":"model"}],"usage":{"total":{"promptTokens":10,"completionTokens":20,"totalTokens":30,"estimatedCostUSD":0.01}},"timeline":[{"rootRunId":"run-1","runId":"run-1","depth":0,"stepId":"step-1","toolCallId":"tool-1","eventType":"tool.completed","toolName":"web_search","startedAt":"2026-08-28T10:00:01.000Z","completedAt":"2026-08-28T10:00:02.000Z","durationMs":1000,"outcome":"completed","childRunId":null,"eventSeq":2}],"runTree":[],"summary":{"status":"succeeded","reason":"Trace status is succeeded."},"warnings":[]}}\n' "$id"
IFS= read -r line
id="$(printf '%s\n' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
printf '{"jsonrpc":"2.0","id":"%s","result":{"shutdown":true}}\n' "$id"
"""#)
        let client = TraceSessionClient(executableURL: executable, responseTimeout: .seconds(2))
        let initialized = try await client.start(backend: .sqlite(path: "/tmp/runtime.sqlite"))
        XCTAssertEqual(initialized.protocolVersion, "1.0")
        XCTAssertTrue(initialized.backend.readOnly)

        let sessions = try await client.listSessions(.init(limit: 100))
        XCTAssertEqual(sessions.first?.goals.first?.rootRunId, "run-1")
        XCTAssertEqual(sessions.first?.goals.first?.goal, "Research AI news")

        let report = try await client.getTrace(rootRunId: "run-1")
        XCTAssertEqual(report.usage.total.totalTokens, 30)
        XCTAssertEqual(report.timeline.first?.toolName, "web_search")
        await client.shutdown()
    }

    func testTraceSessionClientRejectsWritableOrWrongBackend() async throws {
        let executable = try makeTraceScript(#"""
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.0","backend":{"kind":"postgres","readOnly":false}}}'
sleep 1
"""#)
        let client = TraceSessionClient(executableURL: executable, responseTimeout: .seconds(1))
        do {
            _ = try await client.start(backend: .sqlite(path: "/tmp/runtime.sqlite"))
            XCTFail("writable trace backend must be rejected")
        } catch {
            guard case .protocolViolation = error as? TraceSessionClientError else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        await client.shutdown()
    }

    func testTraceSessionClientDecodesRemoteProtocolCode() async throws {
        let executable = try makeTraceScript(#"""
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.0","backend":{"kind":"sqlite","readOnly":true}}}'
IFS= read -r line
id="$(printf '%s\n' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
printf '{"jsonrpc":"2.0","id":"%s","error":{"code":-32020,"message":"Denied","data":{"protocolCode":"SENSITIVE_DATA_NOT_ALLOWED"}}}\n' "$id"
sleep 1
"""#)
        let client = TraceSessionClient(executableURL: executable, responseTimeout: .seconds(1))
        _ = try await client.start(backend: .sqlite(path: "/tmp/runtime.sqlite"))
        do {
            _ = try await client.listSessions()
            XCTFail("remote error should be thrown")
        } catch {
            XCTAssertEqual(
                error as? TraceSessionClientError,
                .remote(code: -32020, protocolCode: "SENSITIVE_DATA_NOT_ALLOWED", message: "Denied")
            )
        }
        await client.shutdown()
    }

    func testTraceSessionClientRedactsDiagnostics() async throws {
        let executable = try makeTraceScript(#"""
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.0","backend":{"kind":"sqlite","readOnly":true}}}'
printf '%s\n' '{"accessToken":"trace-secret"}' >&2
IFS= read -r line
id="$(printf '%s\n' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
printf '{"jsonrpc":"2.0","id":"%s","result":{"shutdown":true}}\n' "$id"
"""#)
        let diagnostics = StringRecorder()
        let client = TraceSessionClient(executableURL: executable, responseTimeout: .seconds(1))
        _ = try await client.start(
            backend: .sqlite(path: "/tmp/runtime.sqlite"),
            diagnosticsHandler: { await diagnostics.append($0) }
        )
        for _ in 0..<50 where (await diagnostics.values).isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let messages = await diagnostics.values
        XCTAssertTrue(messages.contains { $0.contains("<redacted>") })
        XCTAssertFalse(messages.contains { $0.contains("trace-secret") })
        await client.shutdown()
    }

    func testUnexpectedTraceSessionTerminationFailsPendingRequest() async throws {
        let executable = try makeTraceScript(#"""
IFS= read -r line
printf '%s\n' '{"jsonrpc":"2.0","id":"initialize","result":{"protocolVersion":"1.0","backend":{"kind":"sqlite","readOnly":true}}}'
IFS= read -r line
exit 9
"""#)
        let terminations = TerminationRecorder()
        let client = TraceSessionClient(executableURL: executable, responseTimeout: .seconds(2))
        _ = try await client.start(
            backend: .sqlite(path: "/tmp/runtime.sqlite"),
            terminationHandler: { await terminations.append($0) }
        )
        do {
            _ = try await client.listSessions()
            XCTFail("request should fail when trace-session exits")
        } catch {
            XCTAssertEqual(error as? TraceSessionClientError, .terminated(9))
        }
        for _ in 0..<50 where (await terminations.values).isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let terminationValues = await terminations.values
        XCTAssertEqual(terminationValues, [9])
        await client.shutdown()
    }

    private func makeRuntimeScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaptiveAgentDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agent-runtime")
        try "#!/bin/sh\nset -eu\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func makeTraceScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaptiveAgentDesktopTraceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("trace-session-sidecar")
        try "#!/bin/sh\nset -eu\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func temporaryFileURL(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaptiveAgentDesktopTests-\(UUID().uuidString)-\(name)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func temporaryDirectoryURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdaptiveAgentDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func mediaAttachmentCapabilities() throws -> AttachmentCapabilities {
        try JSONDecoder().decode(
            AttachmentCapabilities.self,
            from: Data(#"{"enabled":true,"maxFileBytes":10485760,"maxAttachmentCount":8,"maxSubmissionBytes":41943040,"acceptedKinds":["file","image","audio"],"supportedImageMimeTypes":["image/png","image/jpeg","image/webp","image/gif"],"supportedAudioMimeTypes":["audio/wav","audio/x-wav","audio/mpeg","audio/flac","audio/mp4","audio/ogg","audio/aac","audio/aiff"],"supportedAudioFormats":["wav","mp3","flac","m4a","ogg","aac","aiff","pcm16","pcm24"],"supportedGenericMimeTypes":["application/octet-stream","application/pdf","text/plain","application/json"],"routing":{"taskGeneric":"direct","chatGeneric":"direct","taskImage":"direct","taskAudio":"direct","chatImage":"direct","chatAudio":"direct"}}"#.utf8)
        )
    }

    private func waveData() -> Data {
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendUInt32(38)
        appendASCII("WAVEfmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(8_000)
        appendUInt32(16_000)
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(2)
        appendUInt16(0)
        return data
    }

    private func toolCompletedEvent(
        runId: String,
        toolName: String,
        output: [String: JSONValue]
    ) -> JSONValue {
        .object([
            "schemaVersion": .number(1),
            "type": .string("tool.completed"),
            "runId": .string(runId),
            "payload": .object(["toolName": .string(toolName), "output": .object(output)])
        ])
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func assertThrows<T>(
        _ operation: () async throws -> T,
        verify: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected operation to throw")
        } catch {
            verify(error)
        }
    }

    private func waitForNotifications(_ recorder: NotificationRecorder, count: Int) async -> [(method: String, params: JSONValue)] {
        for _ in 0..<50 {
            let values = await recorder.values
            if values.count >= count { return values }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await recorder.values
    }
}

private actor NotificationRecorder {
    private(set) var values: [(method: String, params: JSONValue)] = []

    func append(method: String, params: JSONValue) {
        values.append((method, params))
    }
}

private actor TerminationRecorder {
    private(set) var values: [Int32] = []

    func append(_ status: Int32) {
        values.append(status)
    }
}

private actor StringRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
