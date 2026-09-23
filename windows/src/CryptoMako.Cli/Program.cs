using CryptoMako.S3;
using CryptoMako.Vault;

return await MainAsync(args);

static async Task<int> MainAsync(string[] args)
{
    if (args.Length == 0 || args[0] is "-h" or "--help")
    {
        PrintHelp();
        return args.Length == 0 ? 2 : 0;
    }

    try
    {
        return args[0] switch
        {
            "unlock" => await CmdUnlockAsync(ParseOpts(args.AsSpan(1))),
            "ls" => await CmdLsAsync(ParseOpts(args.AsSpan(1))),
            "cat" => await CmdCatAsync(ParseOpts(args.AsSpan(1))),
            "get" => await CmdGetAsync(ParseOpts(args.AsSpan(1))),
            "stat" => await CmdStatAsync(ParseOpts(args.AsSpan(1))),
            "sync" => await CmdSyncAsync(ParseOpts(args.AsSpan(1))),
            "delete" => await CmdDeleteAsync(ParseOpts(args.AsSpan(1))),
            "rename" => await CmdRenameAsync(ParseOpts(args.AsSpan(1))),
            "cred" => CmdCred(args.AsSpan(1)),
            _ => Fail(2, $"unknown command: {args[0]}"),
        };
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
        return Fail(1, Sanitize(ex.Message));
    }
}

static async Task<int> CmdUnlockAsync(Opts o)
{
    await using var session = await OpenSessionAsync(o);
    Console.WriteLine($"format={session.Metadata.Format}");
    Console.WriteLine($"cipherCombo={session.Metadata.CipherCombo}");
    Console.WriteLine($"shorteningThreshold={session.Metadata.ShorteningThreshold}");
    Console.WriteLine($"root={session.RootPath}");
    if (!string.IsNullOrEmpty(session.Prefix))
        Console.WriteLine($"prefix={session.Prefix}");
    return 0;
}

static async Task<int> CmdLsAsync(Opts o)
{
    await using var session = await OpenSessionAsync(o);
    foreach (var e in await session.ListAsync(o.Path, o.Recursive))
        Console.WriteLine(e);
    return 0;
}

static async Task<int> CmdCatAsync(Opts o)
{
    if (o.PositionalPath is null) return Fail(2, "cat requires a cleartext path");
    await using var session = await OpenSessionAsync(o);
    var bytes = await session.CatAsync(o.PositionalPath);
    await Console.OpenStandardOutput().WriteAsync(bytes);
    return 0;
}

static async Task<int> CmdGetAsync(Opts o)
{
    if (o.PositionalPath is null) return Fail(2, "get requires a cleartext path");
    if (o.Output is null) return Fail(2, "get requires --output FILE");
    await using var session = await OpenSessionAsync(o);
    await session.GetAsync(o.PositionalPath, o.Output);
    Console.Error.WriteLine($"wrote {Path.GetFullPath(o.Output)}");
    return 0;
}

static async Task<int> CmdStatAsync(Opts o)
{
    if (o.PositionalPath is null) return Fail(2, "stat requires a cleartext path");
    await using var session = await OpenSessionAsync(o);
    var node = await session.StatAsync(o.PositionalPath);
    Console.WriteLine($"name={node.CleartextName}");
    Console.WriteLine($"kind={node.Kind.ToString().ToLowerInvariant()}");
    if (node.Size is long size)
        Console.WriteLine($"ciphertext-bytes={size}");
    if (!string.IsNullOrEmpty(node.ETag))
        Console.WriteLine($"etag={node.ETag}");
    Console.WriteLine($"ciphertext-key={node.CiphertextKey}");
    if (node.DirId is not null)
        Console.WriteLine($"dirId={node.DirId}");
    return 0;
}

static async Task<int> CmdSyncAsync(Opts o)
{
    if (o.Source is null) return Fail(2, "sync requires --source DIR");
    if (o.VaultFolder is null) return Fail(2, "sync requires --vault-folder NAME");
    await using var session = await OpenSessionAsync(o);
    var prefs = LoadAppPreferences(o);
    var excludes = new BackupSyncExcludes();
    var statePath = o.SyncStatePath
        ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CryptoMako",
            "backup-sync-state.json");
    var engine = new BackupSyncEngine();
    var progress = new Progress<string>(p => Console.Error.WriteLine(p));
    var result = await engine.SyncAsync(
        session,
        o.Source,
        o.VaultFolder,
        prefs,
        excludes,
        syncStatePath: statePath,
        progress: progress);
    Console.WriteLine($"uploaded={result.FilesUploaded}");
    Console.WriteLine($"skipped={result.FilesSkipped}");
    Console.WriteLine($"bytes={result.BytesUploaded}");
    return 0;
}

static async Task<int> CmdDeleteAsync(Opts o)
{
    if (o.PositionalPath is null) return Fail(2, "delete requires a cleartext path");
    await using var session = await OpenSessionAsync(o);
    await session.DeleteAsync(o.PositionalPath, recursive: o.Recursive);
    Console.Error.WriteLine($"deleted {o.PositionalPath}");
    return 0;
}

static async Task<int> CmdRenameAsync(Opts o)
{
    if (o.PositionalPath is null || o.RenameTo is null)
        return Fail(2, "rename requires <from> <to> cleartext paths");
    await using var session = await OpenSessionAsync(o);
    var node = await session.RenameAsync(o.PositionalPath, o.RenameTo);
    Console.Error.WriteLine($"renamed -> {o.RenameTo} ({node.Kind.ToString().ToLowerInvariant()})");
    return 0;
}

static async Task<VaultSession> OpenSessionAsync(Opts o)
{
    var secrets = CompositeSecretStore.Default;
    var password = RequireSecret(secrets, o.PasswordEnv, "vault password");

    if (!string.IsNullOrEmpty(o.Local))
        return VaultSession.UnlockLocal(o.Local, password);

    var settings = LoadSettings(o);
    if (settings.IsLocal)
    {
        var path = o.Local ?? settings.LocalVaultPath;
        if (string.IsNullOrEmpty(path))
            throw new InvalidOperationException("local mode requires --local DIR or localVaultPath in settings.");
        return VaultSession.UnlockLocal(path, password);
    }

    var endpoint = o.Endpoint ?? NullIfEmpty(settings.Endpoint)
        ?? throw new InvalidOperationException("missing --endpoint (or settings.json endpoint)");
    var region = o.Region ?? NullIfEmpty(settings.Region) ?? "us-east-1";
    var bucket = o.Bucket ?? NullIfEmpty(settings.Bucket)
        ?? throw new InvalidOperationException("missing --bucket (or settings.json bucket)");
    var accessKey = o.AccessKey ?? NullIfEmpty(settings.AccessKey)
        ?? throw new InvalidOperationException("missing --access-key (or settings.json accessKey)");
    var prefix = o.Prefix ?? settings.NormalizedPrefix;
    var pathStyle = o.VirtualHosted ? false : settings.PathStyle;
    var secretKey = RequireSecret(secrets, o.SecretKeyEnv, "S3 secret key");

    var prefs = LoadAppPreferences(o);
    var proxyPassword = secrets.GetSecret(SecretAccounts.ProxyPassword);
    var http = S3ObjectStore.CreateHttpClient(prefs, proxyPassword);
    var s3 = S3Settings.From(endpoint, region, bucket, accessKey, secretKey, pathStyle);
    var store = new S3ObjectStore(s3, http);
    var label = $"{bucket}/{VaultSession.NormalizePrefix(prefix)}";
    return await VaultSession.UnlockAsync(store, prefix, password, rootLabel: label);
}

static VaultSettings LoadSettings(Opts o)
{
    if (!string.IsNullOrEmpty(o.ConfigPath) && File.Exists(o.ConfigPath))
        return VaultSettings.LoadFromFile(o.ConfigPath);

    foreach (var path in new[]
             {
                 o.ConfigPath,
                 Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CryptoMako", "settings.json"),
                 Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "cryptomako", "poc.json"),
             })
    {
        if (!string.IsNullOrEmpty(path) && File.Exists(path))
            return VaultSettings.LoadFromFile(path);
    }
    return new VaultSettings { StorageMode = "s3" };
}

static AppPreferences LoadAppPreferences(Opts o)
{
    var candidates = new List<string>();
    if (!string.IsNullOrEmpty(o.PreferencesPath))
        candidates.Add(o.PreferencesPath);
    candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CryptoMako", "app-preferences.json"));
    foreach (var path in candidates)
    {
        if (File.Exists(path))
        {
            try { return AppPreferences.Deserialize(File.ReadAllText(path)); }
            catch { /* fall through */ }
        }
    }
    return new AppPreferences();
}


static int CmdCred(ReadOnlySpan<string> args)
{
    if (args.Length == 0 || args[0] is "-h" or "--help")
    {
        Console.WriteLine("""
            cryptomako cred — manage secrets (env / Windows Credential Manager)

            Usage:
              cryptomako cred list
              cryptomako cred get <account>
              cryptomako cred set <account>     # secret on stdin (one line); never argv
              cryptomako cred delete <account>

            Accounts:
              CRYPTOMAKO_PASSWORD | password
              CRYPTOMAKO_SECRET_KEY | secret-key | secret
              CRYPTOMAKO_PROXY_PASSWORD | proxy-password | proxy
            """);
        return args.Length == 0 ? 2 : 0;
    }

    var store = CompositeSecretStore.Default;
    var op = args[0];
    switch (op)
    {
        case "list":
            foreach (var (label, account) in KnownAccounts())
            {
                var present = !string.IsNullOrEmpty(store.GetSecret(account));
                var backend = WindowsCredentialStore.IsSupported ? "credman|env" : "file|env";
                Console.WriteLine($"{account}\t{(present ? "set" : "missing")}\t{backend}");
            }
            return 0;
        case "get":
        {
            if (args.Length < 2) return Fail(2, "cred get requires <account>");
            var account = NormalizeAccount(args[1]);
            var value = store.GetSecret(account);
            if (string.IsNullOrEmpty(value))
                return Fail(1, $"missing: {account}");
            Console.Write(value);
            if (!value.EndsWith('\n')) Console.WriteLine();
            return 0;
        }
        case "set":
        {
            if (args.Length < 2) return Fail(2, "cred set requires <account>");
            var account = NormalizeAccount(args[1]);
            string? secret;
            if (!Console.IsInputRedirected && args.Length >= 3)
                return Fail(2, "refusing secret on argv; pipe the secret on stdin");
            using (var reader = new StreamReader(Console.OpenStandardInput()))
                secret = reader.ReadLine();
            if (string.IsNullOrEmpty(secret))
                return Fail(2, "empty secret on stdin");
            try
            {
                store.SetSecret(account, secret);
            }
            catch (PlatformNotSupportedException ex)
            {
                // On non-Windows Composite falls back to env for Set when CM unsupported.
                return Fail(1, Sanitize(ex.Message));
            }
            Console.Error.WriteLine($"set {account} ({(WindowsCredentialStore.IsSupported ? "Credential Manager" : "~/.config/cryptomako/secrets.json")})");
            return 0;
        }
        case "delete":
        {
            if (args.Length < 2) return Fail(2, "cred delete requires <account>");
            var account = NormalizeAccount(args[1]);
            store.DeleteSecret(account);
            Console.Error.WriteLine($"deleted {account}");
            return 0;
        }
        default:
            return Fail(2, $"unknown cred subcommand: {op}");
    }
}

static IEnumerable<(string Label, string Account)> KnownAccounts() =>
[
    ("vault password", SecretAccounts.Password),
    ("S3 secret key", SecretAccounts.SecretKey),
    ("proxy password", SecretAccounts.ProxyPassword),
];

static string NormalizeAccount(string raw)
{
    var s = raw.Trim();
    return s.ToLowerInvariant() switch
    {
        "password" or "vault-password" or "pass" => SecretAccounts.Password,
        "secret-key" or "secret" or "secretkey" or "s3-secret" => SecretAccounts.SecretKey,
        "proxy-password" or "proxy" or "proxy-pass" => SecretAccounts.ProxyPassword,
        _ => s, // allow full CRYPTOMAKO_* or custom
    };
}

static Opts ParseOpts(ReadOnlySpan<string> args)
{
    string? local = null, endpoint = null, region = null, bucket = null, prefix = null, accessKey = null;
    string? configPath = null, preferencesPath = null, output = null, source = null, vaultFolder = null, syncStatePath = null;
    string passwordEnv = SecretAccounts.Password;
    string secretKeyEnv = SecretAccounts.SecretKey;
    string path = "/";
    bool recursive = false, virtualHosted = false;
    string? positional = null;
    string? renameTo = null;

    for (var i = 0; i < args.Length; i++)
    {
        var a = args[i];
        switch (a)
        {
            case "--local": local = NeedValue(args, ref i, a); break;
            case "--endpoint": endpoint = NeedValue(args, ref i, a); break;
            case "--region": region = NeedValue(args, ref i, a); break;
            case "--bucket": bucket = NeedValue(args, ref i, a); break;
            case "--prefix": prefix = NeedValue(args, ref i, a); break;
            case "--access-key": accessKey = NeedValue(args, ref i, a); break;
            case "--config": configPath = NeedValue(args, ref i, a); break;
            case "--preferences": preferencesPath = NeedValue(args, ref i, a); break;
            case "--password-env": passwordEnv = NeedValue(args, ref i, a); break;
            case "--secret-key-env": secretKeyEnv = NeedValue(args, ref i, a); break;
            case "--path": path = NeedValue(args, ref i, a); break;
            case "--source": source = NeedValue(args, ref i, a); break;
            case "--vault-folder": vaultFolder = NeedValue(args, ref i, a); break;
            case "--sync-state": syncStatePath = NeedValue(args, ref i, a); break;
            case "--output":
            case "-o":
                output = NeedValue(args, ref i, a);
                break;
            case "--virtual-hosted": virtualHosted = true; break;
            case "-R":
            case "--recursive":
                recursive = true;
                break;
            case "-h":
            case "--help":
                break;
            default:
                if (a.StartsWith('-'))
                    throw new ArgumentException($"unknown flag: {a}");
                if (positional is null) positional = a;
                else if (renameTo is null) renameTo = a;
                else throw new ArgumentException($"unexpected argument: {a}");
                break;
        }
    }

    return new Opts(local, endpoint, region, bucket, prefix, accessKey, configPath, preferencesPath,
        passwordEnv, secretKeyEnv, path, recursive, virtualHosted, positional, output,
        source, vaultFolder, syncStatePath, renameTo);
}

static string NeedValue(ReadOnlySpan<string> args, ref int i, string flag)
{
    if (i + 1 >= args.Length) throw new ArgumentException($"missing value for {flag}");
    return args[++i];
}

static string RequireSecret(ISecretStore store, string account, string label)
{
    var value = store.GetSecret(account);
    if (string.IsNullOrEmpty(value))
        throw new InvalidOperationException(
            $"Set {account} via env or Credential Manager ({label}; never pass secrets on argv).");
    return value;
}

static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s;

static string Sanitize(string message) => message.Replace('\n', ' ').Replace('\r', ' ');

static int Fail(int code, string message)
{
    Console.Error.WriteLine($"error: {message}");
    return code;
}

static void PrintHelp()
{
    Console.WriteLine("""
        cryptomako — CryptoMako Windows CLI (Cryptomator format 8)

        Usage:
          cryptomako unlock (--local DIR | S3 flags)
          cryptomako ls     (...) [--path /] [-R]
          cryptomako cat    (...) <cleartext-path>
          cryptomako get    (...) <cleartext-path> --output FILE
          cryptomako stat   (...) <cleartext-path>
          cryptomako sync   (...) --source DIR --vault-folder NAME
          cryptomako delete (...) <cleartext-path> [-R]
          cryptomako rename (...) <from> <to>
          cryptomako cred   list|get|set|delete <account>

        Connection:
          --local DIR              Unlock a vault directory on disk
          --endpoint URL           S3 API URL (https only)
          --region NAME            AWS region (default us-east-1)
          --bucket NAME            Bucket name
          --prefix PATH            Vault folder prefix (trailing / added)
          --access-key KEY         Access key id
          --virtual-hosted         Virtual-hosted-style URLs (default: path-style)
          --config FILE            Non-secret settings.json
          --preferences FILE       Non-secret app-preferences.json (proxy / sync workers)

        Secrets (env or Windows Credential Manager; never argv / JSON):
          CRYPTOMAKO_PASSWORD
          CRYPTOMAKO_SECRET_KEY
          CRYPTOMAKO_PROXY_PASSWORD

        Sync workers (app-preferences.json): syncSmallPutConcurrency (1–256, default 96),
          syncMediumPutConcurrency (1–128, default 32), syncLargePutConcurrency (1–16, default 4),
          limitSyncUploadBandwidth + syncUploadCapMbps (min 1).

        Credentials:
          cryptomako cred list|get|set|delete <account>
          set reads secret from stdin (never argv)
        """);
}

sealed record Opts(
    string? Local,
    string? Endpoint,
    string? Region,
    string? Bucket,
    string? Prefix,
    string? AccessKey,
    string? ConfigPath,
    string? PreferencesPath,
    string PasswordEnv,
    string SecretKeyEnv,
    string Path,
    bool Recursive,
    bool VirtualHosted,
    string? PositionalPath,
    string? Output,
    string? Source,
    string? VaultFolder,
    string? SyncStatePath,
    string? RenameTo);
