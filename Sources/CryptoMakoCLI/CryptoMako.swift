import ArgumentParser
import Foundation
import CryptoMakoS3
import CryptoMakoShared
import CryptoMakoVault

@main
struct CryptoMako: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cryptomako",
        abstract: "Unlock and browse Cryptomator format-8 vaults stored on S3.",
        subcommands: [Unlock.self, Ls.self, Cat.self, Get.self, Stat.self, Fixture.self]
    )
}

struct ConnectionOptions: ParsableArguments {
    @Option(help: "S3 API URL (no bucket in the path).")
    var endpoint: String?

    @Option(help: "AWS region (MinIO: us-east-1).")
    var region: String?

    @Option(help: "Bucket name.")
    var bucket: String?

    @Option(help: "Vault prefix inside the bucket.")
    var prefix: String?

    @Option(name: .customLong("access-key"), help: "Access key id.")
    var accessKey: String?

    @Option(name: .customLong("secret-key-env"), help: "Env var holding the secret key.")
    var secretKeyEnv: String = "CRYPTOMAKO_SECRET_KEY"

    @Option(name: .customLong("password-env"), help: "Env var holding the vault password.")
    var passwordEnv: String = "CRYPTOMAKO_PASSWORD"

    @Option(help: "JSON config path without secrets.")
    var config: String?

    @Flag(name: .customLong("virtual-hosted"), help: "Use virtual-hosted-style S3 URLs (default is path-style).")
    var virtualHosted = false

    @Option(name: .customLong("local"), help: "Unlock a vault directory on disk instead of S3.")
    var local: String?
}

struct ResolvedConnection {
    var sessionConfig: ConnectionConfig
    var location: VaultLocation
}

enum CLIError: Error, LocalizedError {
    case missing(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "missing \(name)"
        case .message(let text):
            return text
        }
    }

    init(_ error: ConnectionConfigError) {
        switch error {
        case .missing(let name):
            self = .missing(name)
        case .invalid(let message):
            self = .message(message)
        }
    }
}

func resolveConnection(_ opts: ConnectionOptions) throws -> ResolvedConnection {
    let config = try ConnectionConfigLoader.resolve(
        ConnectionRequest(
            localPath: opts.local,
            configURL: opts.config.map { URL(fileURLWithPath: $0) },
            endpoint: opts.endpoint,
            region: opts.region,
            bucket: opts.bucket,
            prefix: opts.prefix,
            accessKey: opts.accessKey,
            passwordEnv: opts.passwordEnv,
            secretKeyEnv: opts.secretKeyEnv,
            virtualHosted: opts.virtualHosted
        )
    )
    let location = VaultLocation(
        endpoint: config.endpoint,
        region: config.region,
        bucket: config.bucket,
        prefix: config.prefix,
        accessKey: config.accessKey
    )
    return ResolvedConnection(sessionConfig: config, location: location)
}

struct OpenedVault {
    var session: VaultSession
    var shutdown: () async -> Void
}

func openSession(_ opts: ConnectionOptions) async throws -> OpenedVault {
    let conn: ResolvedConnection
    do {
        conn = try resolveConnection(opts)
    } catch let error as ConnectionConfigError {
        throw CLIError(error)
    }
    let config = conn.sessionConfig
    let store: any ObjectStore
    if let root = config.localRoot {
        store = DirectoryObjectStore(root: root)
    } else {
        let netPrefs = AppPreferences.load()
        let proxyPassword = try? CredentialStore.readSharedOrLocal(
            account: AppIdentifiers.proxyPasswordAccount
        )
        store = S3ObjectStore(
            settings: S3Settings(
                endpoint: config.endpoint,
                region: config.region,
                bucket: config.bucket,
                accessKey: config.accessKey,
                secretKey: config.secretKey,
                pathStyle: config.pathStyle
            ),
            configureSession: { netPrefs.applyProxy(to: $0, password: proxyPassword) }
        )
    }
    let session = try await VaultSession.unlock(
        location: conn.location,
        passphrase: config.passphrase,
        store: store
    )
    return OpenedVault(
        session: session,
        shutdown: {
            if let s3 = store as? S3ObjectStore {
                try? await s3.shutdown()
            }
        }
    )
}

struct Unlock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unlock a vault and print format metadata.")

    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let opened = try await openSession(connection)
        defer { Task { await opened.shutdown() } }
        let root = opened.session.rootCipherPrefix
        print("format=\(opened.session.config.format) combo=\(opened.session.config.cipherCombo) root=\(root)")
        if let jti = opened.session.config.jti {
            print("jti=\(jti)")
        }
    }
}

struct Ls: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List cleartext names in the vault.")

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .customLong("path"), help: "Cleartext path (default /).")
    var path: String = "/"

    @Flag(name: [.customShort("R"), .long], help: "Recurse into directories.")
    var recursive = false

    func run() async throws {
        let opened = try await openSession(connection)
        defer { Task { await opened.shutdown() } }
        if recursive {
            let rows = try await opened.session.listRecursive(at: path)
            for (p, node) in rows {
                let suffix = node.kind == .directory ? "/" : ""
                print("\(p)\(suffix)")
            }
        } else {
            let dirId = try await dirId(for: path, session: opened.session)
            let nodes = try await opened.session.list(dirId: dirId)
            for node in nodes {
                let suffix = node.kind == .directory ? "/" : (node.kind == .symlink ? " ->" : "")
                print("\(node.cleartextName)\(suffix)")
            }
        }
    }

    private func dirId(for path: String, session: VaultSession) async throws -> String {
        let parts = path.split(separator: "/").map(String.init)
        var dirId = ""
        for part in parts {
            let nodes = try await session.list(dirId: dirId)
            guard let match = nodes.first(where: { $0.cleartextName == part && $0.kind == .directory }),
                  let child = match.dirId
            else {
                throw CLIError.message("path not found: \(path)")
            }
            dirId = child
        }
        return dirId
    }
}

struct Cat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Decrypt a file and write plaintext to stdout.")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Cleartext path inside the vault.")
    var path: String

    func run() async throws {
        let opened = try await openSession(connection)
        defer { Task { await opened.shutdown() } }
        let data = try await opened.session.cat(cleartextPath: path)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Decrypt a file to a destination path (File Provider analog).")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Cleartext path inside the vault.")
    var path: String

    @Option(name: .shortAndLong, help: "Destination file.")
    var output: String

    func run() async throws {
        let opened = try await openSession(connection)
        defer { Task { await opened.shutdown() } }
        let node = try await opened.session.resolveFile(cleartextPath: path)
        let dest = URL(fileURLWithPath: output)
        try await opened.session.fetch(node: node, to: dest)
        FileHandle.standardError.write(Data("wrote \(dest.path)\n".utf8))
    }
}

struct Stat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print kind, size, item id, and ciphertext key for a path.")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Cleartext path inside the vault.")
    var path: String

    func run() async throws {
        let opened = try await openSession(connection)
        defer { Task { await opened.shutdown() } }
        let node = try await opened.session.resolve(cleartextPath: path)
        print("name=\(node.cleartextName)")
        print("kind=\(node.kind.rawValue)")
        print("item=\(ItemIdentifier.of(node).rawValue)")
        if let size = node.size {
            print("ciphertext-bytes=\(size)")
        }
        if let eTag = node.eTag {
            print("etag=\(eTag)")
        }
        print("ciphertext-key=\(node.ciphertextKey)")
    }
}

struct Fixture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write a local format-8 PoC vault under fixtures/ (password file is gitignored)."
    )

    @Option(help: "Directory for ciphertext (default: fixtures/vault next to the package).")
    var output: String?

    @Option(name: .customLong("password-file"), help: "Where to store the generated passphrase.")
    var passwordFile: String?

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let vaultURL = URL(fileURLWithPath: output ?? "fixtures/vault", relativeTo: cwd).absoluteURL
        let passwordURL = URL(fileURLWithPath: passwordFile ?? "fixtures/PASSWORD", relativeTo: cwd).absoluteURL
        let passphrase = VaultFixture.randomPassphrase()
        try FileManager.default.createDirectory(
            at: passwordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try passphrase.write(to: passwordURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: passwordURL.path
        )
        try VaultFixture.create(at: vaultURL, passphrase: passphrase)
        FileHandle.standardError.write(Data("wrote vault to \(vaultURL.path)\n".utf8))
        FileHandle.standardError.write(Data("passphrase in \(passwordURL.path) (mode 600, gitignored)\n".utf8))
        FileHandle.standardError.write(
            Data("test with: cryptomako ls --local \(vaultURL.path) --path / --recursive\n".utf8)
        )
    }
}
