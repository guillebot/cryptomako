import AppKit
import CryptoMakoShared
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: VaultAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.isUnlocked {
                sessionBanner
            } else {
                credentialsForm
            }
            controls
            Text(model.detail)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            listingView
        }
        .padding(20)
        .onAppear { model.load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandIcon.swiftUIImage
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CryptoMako").font(.title)
                    Spacer()
                    Text(model.status.rawValue)
                        .font(.headline)
                        .foregroundStyle(model.status.color)
                }
                if model.isUnlocked {
                    Text("Signed in as \(model.sessionUser)")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("A Cryptomator format-8 vault, decrypted in-process.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sessionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.sessionUser)
                    .font(.headline)
                Text(model.sessionLocation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Lock") { model.lock() }
                .disabled(model.busy)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var credentialsForm: some View {
        Form {
            Picker("Storage", selection: $model.settings.storageMode) {
                Text("Local").tag(VaultSettings.StorageMode.local)
                Text("S3").tag(VaultSettings.StorageMode.s3)
            }
            .pickerStyle(.segmented)

            if model.settings.storageMode == .local {
                TextField("Local vault directory", text: $model.settings.localVaultPath)
                HStack {
                    Button("Choose…") { model.chooseLocalVault() }
                    Text("Directory that contains vault.cryptomator")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } else {
                TextField("Endpoint", text: $model.settings.endpoint)
                TextField("Region", text: $model.settings.region)
                TextField("Bucket", text: $model.settings.bucket)
                TextField("Vault prefix (folder with vault.cryptomator)", text: $model.settings.prefix)
                Text("Object key the app will fetch: \(model.settings.vaultObjectKeyPreview)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Leave prefix empty only if vault.cryptomator is at the bucket root. Non-empty values get a trailing slash on save.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Access key", text: $model.settings.accessKey)
                SecureField("Secret key", text: $model.secretKey)
            }

            SecureField("Vault password", text: $model.password)
        }
    }

    private var controls: some View {
        HStack {
            if !model.isUnlocked {
                Button("Save config") { model.save() }
                Button("Unlock") { Task { await model.unlock(listMode: .root) } }
                    .disabled(model.busy)
                Button("Unlock and list") { Task { await model.unlock(listMode: .recursive) } }
                    .disabled(model.busy)
            } else {
                Button("List root") { Task { await model.unlock(listMode: .root) } }
                    .disabled(model.busy)
                Button("List recursive") { Task { await model.unlock(listMode: .recursive) } }
                    .disabled(model.busy)
            }
            Spacer()
            if model.bundledApp {
                Button("Mount in Finder") { Task { await model.mount() } }
                    .disabled(model.busy || model.jti == nil || !model.isUnlocked)
                Button("Unmount") { Task { await model.unmount() } }
                    .disabled(model.busy || model.jti == nil)
            }
        }
    }

    private var listingView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.listingLines.isEmpty {
                    Text("No listing yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.listingLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
