import XCTest
import Foundation
import Darwin

final class AppServerClientTests: XCTestCase {
    // Allow cold subprocess launch under testmanagerd; timeout behavior has a
    // separate short-deadline regression in CoreTests.
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fakeCodex(home: URL, onRequest: String) throws -> CodexLocation {
        let executable = home.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        while IFS= read -r request; do
          rpc_id=${request##*'"id":'}
          rpc_id=${rpc_id%%,*}
          rpc_id=${rpc_id%%\}*}
          \#(onRequest)
          case "$request" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":'"$rpc_id"',"result":{}}' ;;
            *'"method":"account/read"'*) printf '%s\n' '{"id":'"$rpc_id"',"result":{"account":{"type":"chatgpt","email":"fixture@example.invalid"}}}' ;;
            *'"method":"account/rateLimits/read"'*) printf '%s\n' '{"id":'"$rpc_id"',"result":{"accountId":"fixture-account","rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}' ;;
          esac
        done
        """#
        try script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return CodexLocation(home: home, executable: executable)
    }

    func testClosedInputDuringHandshakeOrLaterReadRecoversOnSameClient() async throws {
        for phase in ["initialize", "account/read"] {
            let home = try home()
            let result = phase == "initialize" ? "{}" : #"{"account":{"type":"chatgpt","email":"fixture@example.invalid"}}"#
            let location = try fakeCodex(home: home, onRequest: #"""
            if [ -f "$CODEX_HOME/break-once" ]; then
              case "$request" in
                *'"method":"\#(phase)"'*)
                  rm "$CODEX_HOME/break-once"
                  exec 0<&-
                  printf '%s\n' '{"id":'"$rpc_id"',"result":\#(result)}'
                  /bin/sleep 1
                  exit ;;
              esac
            fi
            """#)
            let client = AppServerClient(requestTimeout: .seconds(5))
            var display = QuotaDisplayState()
            if phase == "account/read" {
                let first = await client.fetch(location: location)
                XCTAssertNil(first.error)
                display.apply(first)
            }
            try Data().write(to: home.appendingPathComponent("break-once"))
            let broken = await client.fetch(location: location)
            XCTAssertEqual(broken.error, .disconnected, phase)
            display.apply(broken)
            XCTAssertEqual(display.error, QuotaFailure.disconnected.message)
            if phase == "account/read" {
                XCTAssertEqual(display.snapshot?.menuWindow?.remainingPercent, 75)
                XCTAssertEqual(display.account?.identity, "fixture-account")
            }
            let recovered = await client.fetch(location: location)
            XCTAssertNil(recovered.error, phase)
            XCTAssertEqual(recovered.snapshot?.menuWindow?.remainingPercent, 75)
            display.apply(recovered)
            XCTAssertNil(display.error)
            await client.shutdown()
        }
    }

    func testRPCErrorMessageAndDataNeverReachDisplayState() async throws {
        let location = try fakeCodex(home: home(), onRequest: #"""
        case "$request" in
          *'"method":"account/rateLimits/read"'*)
            printf '%s\n' '{"id":'"$rpc_id"',"error":{"code":-32000,"message":"private@example.invalid TEST_SECRET /private/account/path","data":{"credential":"DATA_SECRET"}}}'
            continue ;;
        esac
        """#)
        let client = AppServerClient(requestTimeout: .seconds(5))
        let result = await client.fetch(location: location)
        await client.shutdown()
        XCTAssertEqual(result.error, .rpcFailed)
        var display = QuotaDisplayState()
        display.apply(result)
        XCTAssertEqual(display.error, QuotaFailure.rpcFailed.message)
        for secret in ["private@example.invalid", "TEST_SECRET", "/private/account/path", "DATA_SECRET"] {
            XCTAssertFalse(display.error?.contains(secret) == true)
            XCTAssertFalse(result.error?.localizedDescription.contains(secret) == true)
        }
    }

    func testLaunchFailureAndMissingPathsHaveFixedErrors() async throws {
        let home = try home(), executable = home.appendingPathComponent("private-executable")
        try "#!/nonexistent/PRIVATE_INTERPRETER\n".write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = AppServerClient(requestTimeout: .seconds(5))
        let failed = await client.fetch(location: CodexLocation(home: home, executable: executable))
        XCTAssertEqual(failed.error, .launchFailed)
        XCTAssertFalse(failed.error?.message.contains(home.path) == true)
        let missingHome = await client.fetch(location: CodexLocation(home: home.appendingPathComponent("missing"), executable: executable))
        XCTAssertEqual(missingHome.error, .missingHome)
        let missingExecutable = await client.fetch(location: CodexLocation(home: home, executable: nil))
        XCTAssertEqual(missingExecutable.error, .missingExecutable)
        await client.shutdown()
    }

    func testStructuredRateLimitMetadataAndSidecarCleanupAfterSuccessOrFailure() async throws {
        for failure in [false, true] {
            let home = try home()
            let response = failure ? #"""
            case "$request" in
              *'"method":"account/rateLimits/read"'*)
                printf '%s\n' '{"id":'"$rpc_id"',"error":{"code":-32000,"message":"PRIVATE","data":{"http_status":429,"retry_after_seconds":3600}}}'
                continue ;;
            esac
            """# : ""
            let location = try fakeCodex(home: home, onRequest: "printf '%s' \"$$\" > \"$CODEX_HOME/pid\"\n" + response)
            let client = AppServerClient(requestTimeout: .seconds(5))
            let result = await client.fetch(location: location)
            await client.shutdown()
            XCTAssertTrue(result.didRequestQuota)
            XCTAssertEqual(result.error, failure ? .rateLimited : nil)
            XCTAssertEqual(result.failureDetails?.httpStatus, failure ? 429 : nil)
            XCTAssertEqual(result.failureDetails?.retryAfter, failure ? 3600 : nil)
            let pid = try XCTUnwrap(Int32(String(contentsOf: home.appendingPathComponent("pid"), encoding: .utf8)))
            for _ in 0..<100 {
                if kill(pid, 0) == -1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(kill(pid, 0), -1, "The manual calibration sidecar must exit")
        }
    }

    func testMalformedResponsesFailWithSafeProtocolError() async throws {
        for response in ["not-json PRIVATE_RESPONSE", #"{"id":1}"#] {
            let location = try fakeCodex(home: home(), onRequest: "printf '%s\\n' '\(response)'\ncontinue")
            let client = AppServerClient(requestTimeout: .seconds(5))
            let result = await client.fetch(location: location)
            XCTAssertEqual(result.error, .protocolError)
            await client.shutdown()
        }
    }

    func testUnknownSystemErrorIsReducedToSafeCategory() {
        let error = NSError(domain: "private@example.invalid", code: 123,
                            userInfo: [NSLocalizedDescriptionKey: "TEST_SECRET /private/account/path"])
        let failure = QuotaFailure.classify(error)
        XCTAssertEqual(failure, .unknown)
        var display = QuotaDisplayState()
        display.apply(QuotaRefresh(error: failure))
        XCTAssertEqual(display.error, L10n.text("An unknown error occurred while reading quotas. Try syncing again later."))
        XCTAssertEqual(QuotaFailure.classify(QuotaFailure.timeout), .timeout)
    }
}
